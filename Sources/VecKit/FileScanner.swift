import Foundation

/// Scans a directory for files to index, respecting .gitignore patterns.
public class FileScanner {

    private let directory: URL
    private let respectsGitignore: Bool
    private let includeHiddenFiles: Bool

    /// Known text file extensions that should be indexed.
    private static let textExtensions: Set<String> = [
        "md", "txt", "swift", "py", "js", "ts", "tsx", "jsx",
        "json", "yaml", "yml", "toml", "xml", "html", "css", "scss",
        "sh", "bash", "zsh", "fish",
        "rb", "go", "rs", "c", "h", "cpp", "hpp", "m", "mm",
        "java", "kt", "scala", "r",
        "sql", "graphql",
        "dockerfile", "makefile", "cmake",
        "env", "ini", "cfg", "conf", "config",
        "log", "csv", "tsv",
        "tex", "rst", "adoc", "org"
    ]

    /// File extensions that get special handling.
    private static let pdfExtension = "pdf"

    /// Directories to always skip.
    private static let skipDirectories: Set<String> = [
        ".git", ".build", ".swiftpm",
        "node_modules", "__pycache__", ".venv", "venv",
        ".DS_Store", "Pods", "DerivedData"
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

            let resourceValues = try url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])

            guard resourceValues.isRegularFile == true else { continue }
            guard let modDate = resourceValues.contentModificationDate else { continue }

            let ext = url.pathExtension.lowercased()

            // Check if it's a supported file type
            guard Self.textExtensions.contains(ext) || ext == Self.pdfExtension else {
                // Try to detect text files without known extensions
                if ext.isEmpty || isLikelyTextFile(url) {
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
        let inputData = Data(files.map(\.relativePath).joined(separator: "\n").utf8)
        let stdinHandle = stdinPipe.fileHandleForWriting
        let writeQueue = DispatchQueue(label: "vec.gitignore.stdin")
        writeQueue.async {
            stdinHandle.write(inputData)
            stdinHandle.closeFile()
        }

        // Read stdout before waitUntilExit() to prevent deadlock: if git's output
        // exceeds the pipe buffer (~64KB), the process blocks on write and
        // waitUntilExit() would never return.
        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

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
    case databaseAlreadyExists
    case pathOutsideProject(String)
    case sqliteError(String)
    case databaseCorrupted(String)
    case invalidDatabaseName(String)
    case databaseNotFound(String)
    case sourceDirectoryMissing(String)

    public var errorDescription: String? {
        switch self {
        case .cannotScanDirectory(let path):
            return "Cannot scan directory: \(path)"
        case .cannotReadFile(let path):
            return "Cannot read file: \(path)"
        case .databaseNotInitialized:
            return "Vector database not initialized. Run 'vec init <db-name>' first."
        case .databaseAlreadyExists:
            return "Vector database already exists. Use --force to reinitialize."
        case .pathOutsideProject(let path):
            return "Path is outside the project directory: \(path)"
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
        }
    }
}
