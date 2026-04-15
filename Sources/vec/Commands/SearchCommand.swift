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

    @Argument(help: "Name of the database to search (stored in ~/.vec/<db-name>/)")
    var dbName: String

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

        let (dbDir, _, sourceDir) = try DatabaseLocator.resolve(dbName)

        let database = VectorDatabase(databaseDirectory: dbDir, sourceDirectory: sourceDir)
        try database.open()

        let embedder = EmbeddingService()
        guard let queryEmbedding = embedder.embed(query) else {
            print("Error: Failed to generate embedding for query.")
            throw ExitCode.failure
        }

        let results = try database.search(embedding: queryEmbedding, limit: limit)

        switch format {
        case .text:
            printTextResults(results)
        case .json:
            printJSONResults(results)
        }
    }

    private func printTextResults(_ results: [SearchResult]) {
        if results.isEmpty {
            print("No results found.")
            return
        }

        for result in results {
            let score = String(format: "%.2f", max(0, 1.0 - result.distance))
            var location = result.filePath
            if let start = result.lineStart, let end = result.lineEnd {
                location += ":\(start)-\(end)"
            } else if let page = result.pageNumber {
                location += " (page \(page))"
            }
            print("\(location)  (\(score))")

            if includePreview, let preview = result.contentPreview {
                let truncated = preview.prefix(120).replacingOccurrences(of: "\n", with: " ")
                print("  \(truncated)")
            }
        }
    }

    private func printJSONResults(_ results: [SearchResult]) {
        var jsonArray: [[String: Any]] = []

        for result in results {
            var obj: [String: Any] = [
                "file": result.filePath,
                "score": max(0, 1.0 - result.distance)
            ]
            if let start = result.lineStart {
                obj["line_start"] = start
            }
            if let end = result.lineEnd {
                obj["line_end"] = end
            }
            if let page = result.pageNumber {
                obj["page_number"] = page
            }
            if includePreview, let preview = result.contentPreview {
                obj["preview"] = preview
            }
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
