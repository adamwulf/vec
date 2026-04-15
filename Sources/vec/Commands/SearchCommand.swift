import Foundation
import ArgumentParser
import VecKit

struct SearchCommand: AsyncParsableCommand {

    static var configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search the vector database for semantically similar content"
    )

    @Argument(help: "The search query text")
    var query: String

    @Option(name: .shortAndLong, help: "Maximum number of results to return")
    var limit: Int = 10

    @Flag(name: .long, help: "Include a content preview in results")
    var includePreview: Bool = false

    func run() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        let database = VectorDatabase(directory: directory)
        try database.open()

        let embedder = EmbeddingService()
        guard let queryEmbedding = embedder.embed(query) else {
            print("Error: Failed to generate embedding for query.")
            throw ExitCode.failure
        }

        let results = try database.search(embedding: queryEmbedding, limit: limit)

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
}
