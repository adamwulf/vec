import Foundation

/// Utilities for safe path computation.
public enum PathUtilities {

    /// Compute a relative path from a directory to a file.
    ///
    /// Both paths are standardized (trailing slashes removed, `.`/`..` resolved)
    /// before comparison. If `filePath` is not inside `directory`, returns the
    /// last path component of `filePath` as a fallback.
    ///
    /// - Parameters:
    ///   - filePath: Absolute path (or URL.path) of the file.
    ///   - directory: Absolute path (or URL.path) of the containing directory.
    /// - Returns: The portion of `filePath` relative to `directory`.
    public static func relativePath(of filePath: String, in directory: String) -> String {
        // Standardize: resolve "." / ".." and strip trailing slashes.
        let stdFile = (filePath as NSString).standardizingPath
        let stdDir = (directory as NSString).standardizingPath

        let prefix = stdDir.hasSuffix("/") ? stdDir : stdDir + "/"

        if stdFile.hasPrefix(prefix) {
            return String(stdFile.dropFirst(prefix.count))
        }

        // Exact match means file *is* the directory — unlikely but handle gracefully.
        if stdFile == stdDir {
            return ""
        }

        // File is not inside directory — fall back to the filename.
        return (stdFile as NSString).lastPathComponent
    }
}
