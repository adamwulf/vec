import Foundation

/// A group of search results from the same file, ranked by best score.
public struct FileGroup {
    /// Path relative to the project root
    public let filePath: String
    /// Best score across all matches in this file (1.0 - distance, clamped to >= 0)
    public let bestScore: Double
    /// Individual matches, sorted by score descending
    public let matches: [SearchResult]
}

/// Groups search results by file path and returns the top groups by best score.
public struct SearchResultCoalescer {

    /// Groups the given search results by file path, sorts each group by score
    /// (descending), sorts groups by best score (descending), and returns up to
    /// `limit` groups.
    ///
    /// - Parameters:
    ///   - results: Raw search results to coalesce.
    ///   - limit: Maximum number of file groups to return.
    /// - Returns: Coalesced file groups, sorted by best score descending.
    public static func coalesce(_ results: [SearchResult], limit: Int) -> [FileGroup] {
        // Group results by file path, preserving insertion order via array of keys
        var groupsByPath: [String: [SearchResult]] = [:]
        var orderedPaths: [String] = []
        for result in results {
            if groupsByPath[result.filePath] == nil {
                orderedPaths.append(result.filePath)
            }
            groupsByPath[result.filePath, default: []].append(result)
        }

        // Build file groups, each sorted by score descending
        var groups: [FileGroup] = orderedPaths.compactMap { path in
            guard let matches = groupsByPath[path] else { return nil }
            let sorted = matches.sorted { (1.0 - $0.distance) > (1.0 - $1.distance) }
            let bestScore = max(0, 1.0 - sorted[0].distance)
            return FileGroup(filePath: path, bestScore: bestScore, matches: sorted)
        }

        // Sort groups by best score descending
        groups.sort { $0.bestScore > $1.bestScore }

        // Apply file-level limit
        return Array(groups.prefix(limit))
    }
}
