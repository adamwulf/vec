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

    private enum IndexResult: Sendable {
        case indexed(wasUpdate: Bool)
        case skippedUnreadable
        case skippedEmbedFailure
    }

    /// Extract text and generate embeddings for a file, flushing to the database in
    /// batches of `batchSize` to bound memory usage for large files.
    private func indexFile(
        _ file: FileInfo,
        using extractor: TextExtractor,
        embedder: EmbeddingService,
        database: VectorDatabase,
        label: String,
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

        // Remove any stale completion record before writing chunks.
        // If we're interrupted, the missing record ensures re-indexing on restart.
        try await database.unmarkFileIndexed(path: file.relativePath)

        // Delete any existing chunks (partial or full) for this file
        try await database.removeEntries(forPath: file.relativePath)

        var totalInserted = 0
        var warnedNonEnglish = false
        var chunksEmbedded = 0
        let totalChunks = chunks.count

        if verbose {
            print("  \(label): \(file.relativePath) (\(totalChunks) chunks)")
        }

        // Process chunks in batches to bound memory
        for batchStart in stride(from: 0, to: chunks.count, by: Self.batchSize) {
            let batchEnd = min(batchStart + Self.batchSize, chunks.count)
            let batch = chunks[batchStart..<batchEnd]

            // Embed sequentially within each batch
            var records: [ChunkRecord] = []
            for chunk in batch {
                embedder.warnIfNonEnglish(text: chunk.text, filePath: file.relativePath, warned: &warnedNonEnglish)
                guard let vector = embedder.embed(chunk.text) else { continue }
                chunksEmbedded += 1
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

            try await database.insertBatch(records)
            totalInserted += records.count

            if verbose && totalChunks > Self.batchSize {
                let pct = Int(Double(chunksEmbedded) / Double(totalChunks) * 100)
                print("    \(file.relativePath) [\(chunksEmbedded)/\(totalChunks) chunks, \(pct)%]")
            }
        }

        if totalInserted == 0 {
            if verbose {
                print("    Skipped: \(file.relativePath) (failed to embed \(totalChunks) chunks)")
            }
            return .skippedEmbedFailure
        }

        // All chunks written successfully — mark the file as fully indexed.
        try await database.markFileIndexed(path: file.relativePath, modifiedAt: file.modificationDate)

        if verbose && totalChunks > Self.batchSize {
            print("  Done: \(file.relativePath) (\(totalInserted) chunks)")
        }
        return .indexed(wasUpdate: label == "Updated")
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

        let extractor = TextExtractor()
        let embedder = EmbeddingService()

        var added = 0
        var updated = 0
        var unchanged = 0
        var skippedUnreadable = 0
        var skippedEmbedFailures = 0

        // Process files sequentially. Each file's chunks are embedded and
        // flushed in batches. A completion record is written only after all
        // chunks succeed, so interrupted files are re-indexed on restart.
        for file in files {
            let label: String
            if let existingModDate = indexedFiles[file.relativePath] {
                if file.modificationDate > existingModDate {
                    label = "Updated"
                } else {
                    unchanged += 1
                    if verbose {
                        print("  Unchanged: \(file.relativePath)")
                    }
                    continue
                }
            } else {
                label = "Added"
            }

            let result = try await indexFile(
                file,
                using: extractor,
                embedder: embedder,
                database: database,
                label: label,
                verbose: verbose
            )

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
