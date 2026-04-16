import Foundation
import ArgumentParser
import VecKit

struct SearchCommand: AsyncParsableCommand {

    static var configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search the vector database for semantically similar content"
    )

    enum OutputFormat: String, ExpressibleByArgument, CaseIterable {
        case text
        case json
    }

    @Option(name: .shortAndLong, help: "Name of the database (stored in ~/.vec/<name>/). Omit to resolve from current directory.")
    var db: String?

    @Argument(help: "The search query text")
    var query: String

    @Option(name: .shortAndLong, help: "Maximum number of results to return")
    var limit: Int = 10

    @Flag(name: .long, help: "Include a content preview in results")
    var includePreview: Bool = false

    @Option(name: .long, help: "Output format: text or json")
    var format: OutputFormat = .text

    func run() async throws {
        guard limit > 0 else {
            print("Error: --limit must be a positive integer.")
            throw ExitCode.failure
        }

        let (dbDir, _, sourceDir) = try db != nil
            ? DatabaseLocator.resolve(db!)
            : DatabaseLocator.resolveFromCurrentDirectory()

        let database = VectorDatabase(databaseDirectory: dbDir, sourceDirectory: sourceDir)
        try database.open()

        let embedder = EmbeddingService()
        guard let queryEmbedding = embedder.embed(query) else {
            print("Error: Failed to generate embedding for query.")
            throw ExitCode.failure
        }

        // Fetch extra chunks so we can group by file and still return enough files
        let fetchLimit = limit * 3
        let results = try database.search(embedding: queryEmbedding, limit: fetchLimit)
        let grouped = SearchResultCoalescer.coalesce(results, limit: limit)

        switch format {
        case .text:
            printTextResults(grouped)
        case .json:
            printJSONResults(grouped)
        }
    }

    // MARK: - Text Output

    private func printTextResults(_ groups: [FileGroup]) {
        if groups.isEmpty {
            print("No results found.")
            return
        }

        for group in groups {
            let score = String(format: "%.2f", group.bestScore)
            print("\(group.filePath)  (\(score))")

            for match in group.matches {
                let matchScore = String(format: "%.2f", max(0, 1.0 - match.distance))
                if let start = match.lineStart, let end = match.lineEnd {
                    print("  Lines \(start)-\(end)  (\(matchScore))")
                } else if let page = match.pageNumber {
                    print("  Page \(page)  (\(matchScore))")
                } else {
                    print("  (whole file)  (\(matchScore))")
                }

                if includePreview, let preview = match.contentPreview {
                    let truncated = preview.prefix(120).replacingOccurrences(of: "\n", with: " ")
                    print("    \(truncated)")
                }
            }
        }
    }

    // MARK: - JSON Output

    private func printJSONResults(_ groups: [FileGroup]) {
        var jsonArray: [[String: Any]] = []

        for group in groups {
            var matchesArray: [[String: Any]] = []
            for match in group.matches {
                var matchObj: [String: Any] = [
                    "score": max(0, 1.0 - match.distance),
                    "chunk_type": match.chunkType.rawValue
                ]
                if let start = match.lineStart {
                    matchObj["line_start"] = start
                }
                if let end = match.lineEnd {
                    matchObj["line_end"] = end
                }
                if let page = match.pageNumber {
                    matchObj["page_number"] = page
                }
                if includePreview, let preview = match.contentPreview {
                    matchObj["preview"] = preview
                }
                matchesArray.append(matchObj)
            }

            let obj: [String: Any] = [
                "file": group.filePath,
                "score": group.bestScore,
                "matches": matchesArray
            ]
            jsonArray.append(obj)
        }

        if let data = try? JSONSerialization.data(withJSONObject: jsonArray, options: [.prettyPrinted, .sortedKeys]),
           let jsonString = String(data: data, encoding: .utf8) {
            print(jsonString)
        } else {
            print("[]")
        }
    }
}
