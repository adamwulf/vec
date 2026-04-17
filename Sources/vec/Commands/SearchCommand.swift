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

    enum ChunkDisplay: String, ExpressibleByArgument, CaseIterable {
        case lines
        case chunks
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

    @Option(name: .long, help: "How to render text chunks in results: lines (L10-20) or chunks (C1,2,3)")
    var show: ChunkDisplay = .lines

    func run() async throws {
        guard limit > 0 else {
            print("Error: --limit must be a positive integer.")
            throw ExitCode.failure
        }

        let (dbDir, _, sourceDir) = try db != nil
            ? DatabaseLocator.resolve(db!)
            : DatabaseLocator.resolveFromCurrentDirectory()

        let database = VectorDatabase(databaseDirectory: dbDir, sourceDirectory: sourceDir)
        try await database.open()

        let embedder = EmbeddingService()
        guard let queryEmbedding = embedder.embed(query) else {
            print("Error: Failed to generate embedding for query.")
            throw ExitCode.failure
        }

        // Fetch extra chunks so we can group by file and still return enough files
        let fetchLimit = limit * 3
        let results = try await database.search(embedding: queryEmbedding, limit: fetchLimit)
        let grouped = SearchResultCoalescer.coalesce(results, limit: limit)

        // Resolve chunk ordinals only when needed for --show chunks
        var ordinalsByFile: [String: [Int64: Int]] = [:]
        if show == .chunks {
            for group in grouped {
                ordinalsByFile[group.filePath] = try await database.chunkOrdinals(filePath: group.filePath)
            }
        }

        switch format {
        case .text:
            printTextResults(grouped, ordinalsByFile: ordinalsByFile)
        case .json:
            printJSONResults(grouped, ordinalsByFile: ordinalsByFile)
        }
    }

    // MARK: - Text Output

    private func printTextResults(_ groups: [FileGroup], ordinalsByFile: [String: [Int64: Int]]) {
        if groups.isEmpty {
            print("No results found.")
            return
        }

        for group in groups {
            let score = String(format: "%.4f", group.bestScore)
            let ordinals = ordinalsByFile[group.filePath] ?? [:]
            let list = renderMatchList(group.matches, ordinals: ordinals)
            print("\(group.filePath) \(list) (\(score))")

            if includePreview {
                for match in group.matches {
                    if let preview = match.contentPreview {
                        let truncated = preview.prefix(120).replacingOccurrences(of: "\n", with: " ")
                        print("  \(truncated)")
                    }
                }
            }
        }
    }

    /// Renders the comma-separated match list. Text line-range chunks collapse
    /// so only the first one in a run carries the `L` prefix (in lines mode).
    /// Non-text chunks (whole, PDF page, OCR) always render with their type
    /// marker.
    private func renderMatchList(_ matches: [SearchResult], ordinals: [Int64: Int]) -> String {
        var parts: [String] = []
        var firstLineRange = true

        for match in matches {
            let token: String
            switch match.chunkType {
            case .image:
                token = "OCR"
                firstLineRange = true
            case .whole:
                token = "whole"
                firstLineRange = true
            case .pdfPage:
                if let page = match.pageNumber {
                    token = "P\(page)"
                } else {
                    token = "P?"
                }
                firstLineRange = true
            case .chunk:
                switch show {
                case .lines:
                    if let start = match.lineStart, let end = match.lineEnd {
                        token = firstLineRange ? "L\(start)-\(end)" : "\(start)-\(end)"
                        firstLineRange = false
                    } else {
                        token = "chunk"
                        firstLineRange = true
                    }
                case .chunks:
                    if let ordinal = ordinals[match.chunkId] {
                        token = firstLineRange ? "C\(ordinal)" : "\(ordinal)"
                        firstLineRange = false
                    } else {
                        token = firstLineRange ? "C?" : "?"
                        firstLineRange = false
                    }
                }
            }
            parts.append(token)
        }

        return parts.joined(separator: ",")
    }

    // MARK: - JSON Output

    private func printJSONResults(_ groups: [FileGroup], ordinalsByFile: [String: [Int64: Int]]) {
        var jsonArray: [[String: Any]] = []

        for group in groups {
            let ordinals = ordinalsByFile[group.filePath] ?? [:]
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
                if let ordinal = ordinals[match.chunkId] {
                    matchObj["chunk_index"] = ordinal
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
