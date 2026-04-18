import Foundation
import ArgumentParser
import UniformTypeIdentifiers
import VecKit

struct SearchCommand: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
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

    @Flag(name: .shortAndLong, help: "Include a content preview in results")
    var preview: Bool = false

    @Option(name: .long, help: "Output format: text or json")
    var format: OutputFormat = .text

    @Option(name: .long, help: "How to render text chunks in results: lines (L10-20) or chunks (C1,2,3)")
    var show: ChunkDisplay = .lines

    @Option(name: .long, help: "Only include files whose basename matches this glob (e.g. '*.txt', 'fumble-?.???')")
    var glob: String?

    @Option(name: .long, help: "Only include files with at least this many lines (or pages for PDFs)")
    var minLines: Int?

    func run() async throws {
        guard limit > 0 else {
            print("Error: --limit must be a positive integer.")
            throw ExitCode.failure
        }

        let (dbDir, rawConfig, sourceDir) = try db != nil
            ? DatabaseLocator.resolve(db!)
            : DatabaseLocator.resolveFromCurrentDirectory()

        // Pre-refactor DBs have no embedder record but already contain
        // nomic-produced vectors — stamp nomic on the config so search
        // works without a user-visible reindex. Opens the DB at the
        // pre-refactor dim (768) solely to count chunks.
        let config: DatabaseConfig
        do {
            let probe = VectorDatabase(databaseDirectory: dbDir, sourceDirectory: sourceDir)
            try await probe.open()
            let chunkCount = try await probe.totalChunkCount()
            config = try DatabaseLocator.migratePreRefactorEmbedderRecord(
                config: rawConfig, chunkCount: chunkCount, dbDir: dbDir
            )
        }

        // Resolve the embedder from the DB's recorded config. Search
        // refuses to guess — a silent fallback to the default would
        // mean building a query vector at the wrong dim for any
        // DB indexed with a different embedder.
        guard let recorded = config.embedder else {
            print("Error: " + VecError.embedderNotRecorded.errorDescription!)
            throw ExitCode.failure
        }
        // Refuse if the DB names an embedder this build doesn't know
        // about. Falling back to the default would build a query vector
        // at the wrong dim for this DB.
        guard let embedderAlias = EmbedderFactory.alias(forCanonicalName: recorded.name) else {
            print("Error: " + VecError.unknownEmbedder(recorded.name).errorDescription!)
            throw ExitCode.failure
        }
        let embedder: any Embedder
        do {
            embedder = try EmbedderFactory.make(alias: embedderAlias)
        } catch {
            print("Error: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            throw ExitCode.failure
        }

        let database = VectorDatabase(
            databaseDirectory: dbDir,
            sourceDirectory: sourceDir,
            dimension: recorded.dimension
        )
        try await database.open()

        let queryEmbedding: [Float]
        do {
            queryEmbedding = try await embedder.embedQuery(query)
        } catch {
            print("Error: Failed to generate embedding for query: \(error)")
            throw ExitCode.failure
        }
        guard !queryEmbedding.isEmpty else {
            print("Error: Empty embedding for query.")
            throw ExitCode.failure
        }

        let hasFilters = glob != nil || minLines != nil
        // `database.search` scores every chunk regardless of limit, so when
        // filters are active we ask for everything and truncate after filtering.
        // Otherwise fetch a small pool to allow for file-level grouping.
        let fetchLimit = hasFilters ? Int.max : limit * 3
        let coalesceLimit = hasFilters ? Int.max : limit
        let results = try await database.search(embedding: queryEmbedding, limit: fetchLimit)
        var grouped = SearchResultCoalescer.coalesce(results, limit: coalesceLimit)

        if let glob {
            grouped = grouped.filter { group in
                let basename = (group.filePath as NSString).lastPathComponent
                return fnmatch(glob, basename, 0) == 0
            }
        }

        let metadata = try await database.indexedFileMetadata(paths: grouped.map(\.filePath))

        if let minLines {
            grouped = grouped.filter { group in
                guard let count = metadata[group.filePath]?.linePageCount else { return false }
                return count >= minLines
            }
        }

        if hasFilters {
            grouped = Array(grouped.prefix(limit))
        }

        // Resolve chunk ordinals only when needed for --show chunks
        var ordinalsByFile: [String: [Int64: Int]] = [:]
        if show == .chunks {
            for group in grouped {
                ordinalsByFile[group.filePath] = try await database.chunkOrdinals(filePath: group.filePath)
            }
        }

        switch format {
        case .text:
            printTextResults(grouped, ordinalsByFile: ordinalsByFile, metadata: metadata)
        case .json:
            printJSONResults(grouped, ordinalsByFile: ordinalsByFile, metadata: metadata)
        }
    }

    // MARK: - Text Output

    private func printTextResults(
        _ groups: [FileGroup],
        ordinalsByFile: [String: [Int64: Int]],
        metadata: [String: VectorDatabase.IndexedFileMetadata]
    ) {
        if groups.isEmpty {
            print("No results found.")
            return
        }

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]

        for group in groups {
            let score = String(format: "%.4f", group.bestScore)
            let ordinals = ordinalsByFile[group.filePath] ?? [:]
            let list = renderMatchList(group.matches, ordinals: ordinals)
            let meta = metadata[group.filePath]
            let modified = meta.map { dateFormatter.string(from: $0.modifiedAt) } ?? "?"
            let sizeUnit = SearchCommand.sizeUnit(forFileExtension: (group.filePath as NSString).pathExtension)
            let size = meta?.linePageCount.map { "\($0)\(sizeUnit)" } ?? "-"
            print("\(group.filePath) \(modified) \(size) \(list) (\(score))")

            if preview {
                for match in group.matches {
                    if let text = match.contentPreview {
                        let truncated = text.prefix(120).replacingOccurrences(of: "\n", with: " ")
                        print("  \(truncated)")
                    }
                }
            }
        }
    }

    /// Returns the unit suffix for the line/page count of a file with the
    /// given extension: "P" for PDFs, "L" for everything else.
    static func sizeUnit(forFileExtension ext: String) -> String {
        isPDFExtension(ext) ? "P" : "L"
    }

    static func isPDFExtension(_ ext: String) -> Bool {
        guard !ext.isEmpty else { return false }
        return UTType(filenameExtension: ext)?.conforms(to: .pdf) == true
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

    private func printJSONResults(
        _ groups: [FileGroup],
        ordinalsByFile: [String: [Int64: Int]],
        metadata: [String: VectorDatabase.IndexedFileMetadata]
    ) {
        var jsonArray: [[String: Any]] = []
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]

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
                if preview, let text = match.contentPreview {
                    matchObj["preview"] = text
                }
                matchesArray.append(matchObj)
            }

            var obj: [String: Any] = [
                "file": group.filePath,
                "score": group.bestScore,
                "matches": matchesArray
            ]
            if let meta = metadata[group.filePath] {
                obj["modified"] = fmt.string(from: meta.modifiedAt)
                if let count = meta.linePageCount {
                    let ext = (group.filePath as NSString).pathExtension
                    let key = SearchCommand.isPDFExtension(ext) ? "page_count" : "line_count"
                    obj[key] = count
                }
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
