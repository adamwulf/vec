import Foundation

/// Scans a directory for files to index, respecting .gitignore patterns.
public class FileScanner {

    private let directory: URL

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
        ".git", ".vec", ".build", ".swiftpm",
        "node_modules", "__pycache__", ".venv", "venv",
        ".DS_Store", "Pods", "DerivedData"
    ]

    public init(directory: URL) {
        self.directory = directory
    }

    /// Scan the directory and return all indexable files.
    public func scan() throws -> [FileInfo] {
        var results: [FileInfo] = []
        let fm = FileManager.default

        let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
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

        return results.sorted { $0.relativePath < $1.relativePath }
    }

    /// Create a FileInfo for a single file.
    public static func fileInfo(for url: URL, relativeTo directory: URL) throws -> FileInfo {
        let resourceValues = try url.resourceValues(forKeys: [.contentModificationDateKey])
        guard let modDate = resourceValues.contentModificationDate else {
            throw VecError.cannotReadFile(url.path)
        }
        let relativePath = url.path.hasPrefix(directory.path)
            ? String(url.path.dropFirst(directory.path.count + 1))
            : url.lastPathComponent
        return FileInfo(
            relativePath: relativePath,
            url: url,
            modificationDate: modDate,
            fileExtension: url.pathExtension.lowercased()
        )
    }

    // MARK: - Private

    private func fileInfo(url: URL, modDate: Date, ext: String) -> FileInfo {
        let relativePath = String(url.path.dropFirst(directory.path.count + 1))
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

    public var errorDescription: String? {
        switch self {
        case .cannotScanDirectory(let path):
            return "Cannot scan directory: \(path)"
        case .cannotReadFile(let path):
            return "Cannot read file: \(path)"
        case .databaseNotInitialized:
            return "Vector database not initialized. Run 'vec init' first."
        case .databaseAlreadyExists:
            return "Vector database already exists. Use --force to reinitialize."
        case .pathOutsideProject(let path):
            return "Path is outside the project directory: \(path)"
        case .sqliteError(let message):
            return "SQLite error: \(message)"
        }
    }
}
