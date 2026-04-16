import Foundation
import ArgumentParser
import VecKit

struct UpdateIndexCommand: AsyncParsableCommand {

    static var configuration = CommandConfiguration(
        commandName: "update-index",
        abstract: "Update the vector index with new or modified files"
    )

    @Option(name: .shortAndLong, help: "Name of the database (stored in ~/.vec/<name>/). Omit to resolve from current directory.")
    var db: String?

    @Flag(name: .long, help: "Include hidden files and folders")
    var allowHidden: Bool = false

    @Flag(name: .shortAndLong, help: "Show detailed progress for each file")
    var verbose: Bool = false

    /// Maximum number of chunks to embed and flush to the database at once.
    private static let batchSize = 20

    private enum IndexResult {
        case indexed(wasUpdate: Bool)
        case skippedUnreadable
        case skippedEmbedFailure
    }

    /// Extract text and generate embeddings for a file, flushing to the database in
    /// batches of `batchSize` to bound memory usage for large files.
    ///
    /// Embedding is done sequentially because `NLEmbedding.vector(for:)` is not
    /// safe to call concurrently on the same instance — concurrent calls cause
    /// segfaults in the NaturalLanguage framework's C++ internals.
    private func indexFile(
        _ file: FileInfo,
        using extractor: TextExtractor,
        embedder: EmbeddingService,
        database: VectorDatabase,
        label: String,
        removeExisting: Bool = false,
        verbose: Bool = false
    ) async throws -> IndexResult {
        let chunks: [TextChunk]
        do {
            chunks = try extractor.extract(from: file)
        } catch {
            if verbose {
                print("  Skipped: \(file.relativePath) (unreadable)")
            }
            return .skippedUnreadable
        }
        if chunks.isEmpty {
            if verbose {
                print("  Skipped: \(file.relativePath) (no extractable text)")
            }
            return .skippedUnreadable
        }

        var totalInserted = 0
        var needsDelete = removeExisting
        var warnedNonEnglish = false
        var chunksProcessed = 0
        let totalChunks = chunks.count

        // Process chunks in batches to bound memory
        for batchStart in stride(from: 0, to: chunks.count, by: Self.batchSize) {
            let batchEnd = min(batchStart + Self.batchSize, chunks.count)
            let batch = chunks[batchStart..<batchEnd]

            // Embed sequentially within each batch
            var records: [ChunkRecord] = []
            for chunk in batch {
                embedder.warnIfNonEnglish(text: chunk.text, filePath: file.relativePath, warned: &warnedNonEnglish)
                guard let vector = embedder.embed(chunk.text) else { continue }
                chunksProcessed += 1
                if verbose {
                    let pct = Int(Double(chunksProcessed) / Double(totalChunks) * 100)
                    print("  \(label): \(file.relativePath) [\(chunksProcessed)/\(totalChunks) chunks, \(pct)%]", terminator: "\r")
                    fflush(stdout)
                }
                records.append(ChunkRecord(
                    filePath: file.relativePath,
                    lineStart: chunk.lineStart,
                    lineEnd: chunk.lineEnd,
                    chunkType: chunk.type,
                    pageNumber: chunk.pageNumber,
                    fileModifiedAt: file.modificationDate,
                    contentPreview: String(chunk.text.prefix(200)),
                    embedding: vector
                ))
            }

            guard !records.isEmpty else { continue }

            // First batch with removeExisting atomically replaces old entries;
            // subsequent batches just insert.
            if needsDelete {
                try await database.replaceEntries(forPath: file.relativePath, with: records)
                needsDelete = false
            } else {
                try await database.insertBatch(records)
            }

            totalInserted += records.count
        }

        // If we needed to delete but never had any successful embeddings,
        // don't delete the old data — preserve it.
        if totalInserted == 0 {
            if verbose {
                print("  Skipped: \(file.relativePath) (failed to embed \(chunks.count) chunks)")
            }
            return .skippedEmbedFailure
        }

        if verbose {
            print("  \(label): \(file.relativePath) (\(totalInserted) chunks)")
        }
        return .indexed(wasUpdate: removeExisting)
    }

    func run() async throws {
        let (dbDir, _, sourceDir) = try db != nil
            ? DatabaseLocator.resolve(db!)
            : DatabaseLocator.resolveFromCurrentDirectory()

        let database = VectorDatabase(databaseDirectory: dbDir, sourceDirectory: sourceDir)
        try await database.open()

        let scanner = FileScanner(directory: sourceDir, includeHiddenFiles: allowHidden)
        let files = try scanner.scan()
        let indexedFiles = try await database.allIndexedFiles()

        let embedder = EmbeddingService()
        let extractor = TextExtractor()

        // Categorize files into work items
        struct FileWork {
            let file: FileInfo
            let label: String
            let removeExisting: Bool
        }

        var workItems: [FileWork] = []
        var unchanged = 0

        for file in files {
            if let existingModDate = indexedFiles[file.relativePath] {
                if file.modificationDate > existingModDate {
                    workItems.append(FileWork(file: file, label: "Updated", removeExisting: true))
                } else {
                    unchanged += 1
                    if verbose {
                        print("  Unchanged: \(file.relativePath)")
                    }
                }
            } else {
                workItems.append(FileWork(file: file, label: "Added", removeExisting: false))
            }
        }

        // Process files sequentially — NLEmbedding is not safe for concurrent use
        var added = 0
        var updated = 0
        var skippedUnreadable = 0
        var skippedEmbedFailures = 0

        for work in workItems {
            let result: IndexResult
            do {
                result = try await indexFile(
                    work.file,
                    using: extractor,
                    embedder: embedder,
                    database: database,
                    label: work.label,
                    removeExisting: work.removeExisting,
                    verbose: verbose
                )
            } catch {
                result = .skippedEmbedFailure
            }

            switch result {
            case .indexed(let wasUpdate):
                if wasUpdate {
                    updated += 1
                } else {
                    added += 1
                }
            case .skippedUnreadable:
                skippedUnreadable += 1
            case .skippedEmbedFailure:
                skippedEmbedFailures += 1
            }
        }

        // Find files to remove
        var removed = 0
        let currentPaths = Set(files.map(\.relativePath))
        for indexedPath in indexedFiles.keys {
            if !currentPaths.contains(indexedPath) {
                try await database.removeEntries(forPath: indexedPath)
                removed += 1
                if verbose {
                    print("  Removed: \(indexedPath)")
                }
            }
        }

        let skipped = skippedUnreadable + skippedEmbedFailures
        var summary = "Update complete: \(added) added, \(updated) updated, \(removed) removed"
        if verbose {
            summary += ", \(unchanged) unchanged"
        }
        if skipped > 0 {
            var details: [String] = []
            if skippedUnreadable > 0 {
                details.append("\(skippedUnreadable) unreadable")
            }
            if skippedEmbedFailures > 0 {
                details.append("\(skippedEmbedFailures) failed to embed")
            }
            summary += " (\(skipped) skipped: \(details.joined(separator: ", ")))"
        }
        if verbose {
            summary += " (\(files.count) files scanned)"
        }
        print(summary + ".")
    }
}
