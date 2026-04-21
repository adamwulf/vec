import Foundation
import UniformTypeIdentifiers

/// Scans a directory for files to index, respecting .gitignore patterns.
public class FileScanner {

    private let directory: URL
    private let respectsGitignore: Bool
    private let includeHiddenFiles: Bool

    /// Text file extensions that UTType misclassifies or doesn't recognize.
    /// .ts/.mts are classified as MPEG-2 transport streams instead of TypeScript.
    /// .fish, .graphql, .env, .rst, .org, .jsonl, .jsonc, .cjs have no UTType registration.
    private static let textExtensionOverrides: Set<String> = [
        "ts", "mts", "fish", "graphql", "env", "rst", "org",
        "jsonl", "jsonc", "cjs"
    ]

    /// Well-known text filenames that have no file extension.
    private static let knownTextFilenames: Set<String> = [
        "Makefile", "Dockerfile", "LICENSE", "Gemfile",
        "Procfile", "Vagrantfile", "Rakefile", "Brewfile", "Podfile",
        "Fastfile", "Dangerfile", "Berksfile", "Guardfile",
        "CHANGELOG", "CONTRIBUTING", "AUTHORS", "CODEOWNERS"
    ]

    /// Directories to always skip.
    private static let skipDirectories: Set<String> = [
        ".git", ".build", ".swiftpm",
        "node_modules", "__pycache__", ".venv", "venv",
        "Pods", "DerivedData"
    ]

    public init(directory: URL, respectsGitignore: Bool = true, includeHiddenFiles: Bool = false) {
        self.directory = directory
        self.respectsGitignore = respectsGitignore
        self.includeHiddenFiles = includeHiddenFiles
    }

    /// Scan the directory and return all indexable files.
    public func scan() throws -> [FileInfo] {
        var results: [FileInfo] = []
        let fm = FileManager.default

        var options: FileManager.DirectoryEnumerationOptions = []
        if !includeHiddenFiles {
            options.insert(.skipsHiddenFiles)
        }

        let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isDirectoryKey],
            options: options
        )

        guard let enumerator = enumerator else {
            throw VecError.cannotScanDirectory(directory.path)
        }

        while let url = enumerator.nextObject() as? URL {
            let fileName = url.lastPathComponent

            // Skip known directories
            if Self.skipDirectories.contains(fileName) {
                enumerator.skipDescendants()
                continue
            }

            // Skip hidden files/directories by name (dot-prefixed) unless allowed.
            // This complements .skipsHiddenFiles above: the enumerator option uses
            // the Finder hidden attribute (NSURLIsHiddenKey), while this check catches
            // dot-prefixed items that may not have that attribute set.
            if !includeHiddenFiles && fileName.hasPrefix(".") {
                enumerator.skipDescendants()
                continue
            }

            guard let resourceValues = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]) else { continue }

            guard resourceValues.isRegularFile == true else { continue }
            guard let modDate = resourceValues.contentModificationDate else { continue }

            let ext = url.pathExtension.lowercased()

            // Check if it's a supported file type using UTType
            let utType = UTType(filenameExtension: ext)
            let isText = utType?.conforms(to: .text) ?? false
            let isPDF = utType?.conforms(to: .pdf) ?? false
            let isImage = utType?.conforms(to: .image) ?? false

            guard isText || isPDF || isImage
                    || Self.textExtensionOverrides.contains(ext)
                    || Self.knownTextFilenames.contains(fileName) else {
                // Try to detect text files without known extensions
                if isLikelyTextFile(url) {
                    let info = fileInfo(url: url, modDate: modDate, ext: ext)
                    results.append(info)
                }
                continue
            }

            let info = fileInfo(url: url, modDate: modDate, ext: ext)
            results.append(info)
        }

        // Filter out gitignored files
        if respectsGitignore {
            results = filterGitignored(results)
        }

        // Filter out .vecignore patterns
        results = filterVecignored(results)

        return results.sorted { $0.relativePath < $1.relativePath }
    }

    /// Create a FileInfo for a single file.
    public static func fileInfo(for url: URL, relativeTo directory: URL) throws -> FileInfo {
        let resourceValues = try url.resourceValues(forKeys: [.contentModificationDateKey])
        guard let modDate = resourceValues.contentModificationDate else {
            throw VecError.cannotReadFile(url.path)
        }
        let relativePath = PathUtilities.relativePath(of: url.path, in: directory.path)
        return FileInfo(
            relativePath: relativePath,
            url: url,
            modificationDate: modDate,
            fileExtension: url.pathExtension.lowercased()
        )
    }

    // MARK: - Private

    /// Filter out files that are ignored by git using `git check-ignore`.
    /// If the directory is not a git repo or git is unavailable, returns the input unchanged.
    private func filterGitignored(_ files: [FileInfo]) -> [FileInfo] {
        guard !files.isEmpty else { return files }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["check-ignore", "--stdin"]
        process.currentDirectoryURL = directory

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            // git not available — skip filtering
            return files
        }

        // Write stdin on a background thread to avoid blocking if the pipe buffer
        // fills (>64KB of paths). The process may need to flush stdout before it can
        // consume more stdin, so writing and reading must happen concurrently.
        //
        // Ignore SIGPIPE before writing: if the directory is not a git repo,
        // `git check-ignore` exits immediately (code 128) and the write end of
        // the pipe becomes broken. Without SIG_IGN the default SIGPIPE handler
        // kills the entire process with exit code 141.
        let inputData = Data(files.map(\.relativePath).joined(separator: "\n").utf8)
        let stdinHandle = stdinPipe.fileHandleForWriting
        let writeQueue = DispatchQueue(label: "vec.gitignore.stdin")
        let previousHandler = signal(SIGPIPE, SIG_IGN)
        writeQueue.async {
            try? stdinHandle.write(contentsOf: inputData)
            try? stdinHandle.close()
        }

        // Read stdout before waitUntilExit() to prevent deadlock: if git's output
        // exceeds the pipe buffer (~64KB), the process blocks on write and
        // waitUntilExit() would never return.
        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        signal(SIGPIPE, previousHandler)

        // Exit code 1 means no paths were ignored, which is fine.
        // Exit code 128 means not a git repo — return unfiltered.
        if process.terminationStatus == 128 {
            return files
        }

        let output = String(data: outputData, encoding: .utf8) ?? ""

        let ignoredPaths = Set(
            output.split(separator: "\n").map { String($0) }
        )

        return files.filter { !ignoredPaths.contains($0.relativePath) }
    }

    /// Filter out files matching patterns in a `.vecignore` file at the project root.
    /// Pattern syntax: one pattern per line, `#` for comments, blank lines ignored.
    /// Supports exact filename (`file.txt`), directory (`build/`), wildcard (`*.log`),
    /// and root-relative (`/specific-file.txt`) patterns.
    private func filterVecignored(_ files: [FileInfo]) -> [FileInfo] {
        guard !files.isEmpty else { return files }

        let vecignoreURL = directory.appendingPathComponent(".vecignore")
        guard let content = try? String(contentsOf: vecignoreURL, encoding: .utf8) else {
            return files
        }

        let patterns = content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        guard !patterns.isEmpty else { return files }

        return files.filter { file in
            !patterns.contains { pattern in
                matchesVecignorePattern(pattern, path: file.relativePath)
            }
        }
    }

    /// Check if a relative path matches a single .vecignore pattern.
    private func matchesVecignorePattern(_ pattern: String, path: String) -> Bool {
        var pat = pattern

        // Root-relative pattern: leading `/` means match from root only
        let isRootRelative = pat.hasPrefix("/")
        if isRootRelative {
            pat = String(pat.dropFirst())
        }

        // Directory pattern: trailing `/` means match directory prefix
        let isDirectoryPattern = pat.hasSuffix("/")
        if isDirectoryPattern {
            if isRootRelative {
                // Root-relative directory: only match at the start of the path
                // e.g., `/build/` matches `build/output.txt` but NOT `src/build/output.txt`
                return path.hasPrefix(pat)
            }
            // Non-root directory: match anywhere in the path
            return path.hasPrefix(pat) || path.contains("/\(pat)")
        }

        if isRootRelative {
            // Root-relative: only match the full path
            return fnmatch(pat, path, 0) == 0
        }

        // Non-root pattern: match against the full relative path,
        // and also against just the filename (basename)
        if fnmatch(pat, path, 0) == 0 {
            return true
        }

        // Also try matching against each path component's suffix
        // e.g., pattern "*.log" should match "subdir/debug.log"
        let components = path.split(separator: "/")
        if let basename = components.last {
            return fnmatch(pat, String(basename), 0) == 0
        }

        return false
    }

    private func fileInfo(url: URL, modDate: Date, ext: String) -> FileInfo {
        let relativePath = PathUtilities.relativePath(of: url.path, in: directory.path)
        return FileInfo(
            relativePath: relativePath,
            url: url,
            modificationDate: modDate,
            fileExtension: ext
        )
    }

    private func isLikelyTextFile(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        // Check first 8KB for null bytes (binary indicator)
        let checkSize = min(data.count, 8192)
        let slice = data.prefix(checkSize)
        return !slice.contains(0)
    }
}

/// Errors that can occur during vec operations.
public enum VecError: Error, LocalizedError {
    case cannotScanDirectory(String)
    case cannotReadFile(String)
    case databaseNotInitialized
    case sqliteError(String)
    case databaseCorrupted(String)
    case invalidDatabaseName(String)
    case databaseNotFound(String)
    case sourceDirectoryMissing(String)
    case noDatabaseForDirectory(String)
    case multipleDatabasesForDirectory(String, [String])
    /// The requested indexing profile disagrees with what the DB
    /// recorded. Associated values carry the persisted and requested
    /// profile identity strings (e.g. `nomic@1200/240` vs
    /// `nomic@500/100`).
    case profileMismatch(recorded: String, requested: String)
    /// A vector handed to `insert` or `search` doesn't match the
    /// database's declared dimension. Belt-and-braces guard: the
    /// CLI already refuses an embedder mismatch at the config layer,
    /// so this should only ever fire on a direct library misuse.
    case dimensionMismatch(expected: Int, actual: Int)
    /// A persisted indexing profile identity failed the strict
    /// grammar check or the round-trip equality check — indicates a
    /// corrupt `config.json`.
    case malformedProfileIdentity(String)
    /// The user passed exactly one of `--chunk-chars` / `--chunk-overlap`.
    /// Both must be provided together, or neither. Thrown at the CLI
    /// layer before `IndexingProfileFactory.make` is called — the
    /// factory itself traps this case with a precondition since it's
    /// a programmer error to reach the factory with a partial override.
    case partialChunkOverride
    /// Chunk parameters failed validation (non-positive size,
    /// negative overlap, or overlap >= size). The associated string
    /// carries the human-readable reason from the factory.
    case invalidChunkParams(String)
    /// The user passed `--embedder <alias>` with a name that isn't in
    /// `IndexingProfileFactory.knownAliases`, or a persisted identity
    /// string referenced an alias that isn't registered.
    case unknownProfile(String)
    /// The DB has no recorded indexing profile AND has zero chunks
    /// (freshly-`init`ed or freshly-`reset`). Hit by `search` / `insert`
    /// which cannot bootstrap a profile.
    case profileNotRecorded
    /// The DB has no recorded indexing profile but DOES have chunks,
    /// i.e. a pre-profile DB left over from before this refactor.
    case preProfileDatabase
    /// Indexing produced zero vectors: every attempted file extracted
    /// chunks but every embed call returned an empty vector. The DB
    /// contains no new embeddings. `filesAttempted` is the number of
    /// files passed to the pipeline; `filesFailed` is the subset that
    /// hit this specific failure mode.
    case indexingProducedNoVectors(filesAttempted: Int, filesFailed: Int)

    public var errorDescription: String? {
        switch self {
        case .cannotScanDirectory(let path):
            return "Cannot scan directory: \(path)"
        case .cannotReadFile(let path):
            return "Cannot read file: \(path)"
        case .databaseNotInitialized:
            return "Vector database not initialized. Run 'vec init <db-name>' first."
        case .sqliteError(let message):
            return "SQLite error: \(message)"
        case .databaseCorrupted(let detail):
            return "Database schema is corrupted: \(detail)"
        case .invalidDatabaseName(let name):
            return "Invalid database name '\(name)'. Names may only contain letters, numbers, hyphens, and underscores, and must not conflict with command names."
        case .databaseNotFound(let name):
            return "Database '\(name)' not found. Run 'vec init \(name)' to create it."
        case .sourceDirectoryMissing(let path):
            return "Source directory '\(path)' no longer exists. The indexed directory may have been moved or deleted."
        case .noDatabaseForDirectory(let path):
            return "No database found for directory '\(path)'. Use -d <name> or run 'vec init <name>' here first."
        case .multipleDatabasesForDirectory(let path, let names):
            return "Multiple databases found for directory '\(path)': \(names.joined(separator: ", ")). Use -d <name> to specify which one."
        case .profileMismatch(let recorded, let requested):
            return """
                Database was indexed with profile '\(recorded)' but '\(requested)'
                was requested. Vec will not index or search across profiles because
                vectors from different profiles are not directly comparable.

                Your options:
                  1. Re-run the command with flags that resolve to '\(recorded)'
                     (e.g. `--embedder nomic` with the default chunk settings).
                  2. Run `vec reset <db>` and re-index with the new profile.
                """
        case .dimensionMismatch(let expected, let actual):
            return "Vector dimension mismatch: database expects \(expected)-dim vectors but got \(actual)-dim. The embedder wired to this call disagrees with the DB's recorded embedder."
        case .malformedProfileIdentity(let identity):
            return "Indexing profile '\(identity)' in config.json is malformed (expected shape `<alias>@<size>/<overlap>`). Run `vec reset <db>` to rebuild."
        case .partialChunkOverride:
            return "Pass both --chunk-chars and --chunk-overlap together, or neither."
        case .invalidChunkParams(let reason):
            return "Invalid chunk parameters: \(reason)."
        case .unknownProfile(let alias):
            return "Unknown profile '\(alias)'. Known profiles: \(IndexingProfileFactory.knownAliases.joined(separator: ", "))."
        case .profileNotRecorded:
            return "Database has no recorded indexing profile. Run `vec update-index` first to establish a profile."
        case .preProfileDatabase:
            return "Database was indexed by an older version of vec with no recorded profile. Run `vec reset <db>` first, then `vec update-index` to rebuild it under a recorded profile."
        case .indexingProducedNoVectors(let filesAttempted, let filesFailed):
            return """
                Indexing produced no vectors: attempted \(filesAttempted) file(s), \
                \(filesFailed) failed to embed after extracting chunks. The \
                database received no new embeddings.

                Likely causes:
                  - The embedder's model failed to load (check stderr above for a
                    CoreML/ANE or swift-embeddings error).
                  - Every embed call errored or returned an empty vector.

                Your options:
                  1. Re-run with `--verbose` to see which files skipped and why.
                  2. Fix the underlying embedder failure, then re-run `vec update-index`.
                """
        }
    }
}
