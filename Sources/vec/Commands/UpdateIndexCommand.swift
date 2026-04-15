import Foundation
import ArgumentParser
import VecKit

struct UpdateIndexCommand: AsyncParsableCommand {

    static var configuration = CommandConfiguration(
        commandName: "update-index",
        abstract: "Update the vector index with new or modified files"
    )

    @Flag(name: .long, help: "Include hidden files and folders")
    var allowHidden: Bool = false

    private enum IndexResult {
        case indexed
        case skippedUnreadable
        case skippedEmbedFailure
    }

    /// Extract text and generate embeddings for a file, then insert into the database.
    /// When `removeExisting` is true (re-indexing a modified file), old entries are only
    /// removed after new embeddings are successfully generated, preventing data loss if
    /// extraction or embedding fails.
    private func indexFile(
        _ file: FileInfo,
        using extractor: TextExtractor,
        embedder: EmbeddingService,
        database: VectorDatabase,
        label: String,
        removeExisting: Bool = false
    ) throws -> IndexResult {
        let chunks = try extractor.extract(from: file)
        if chunks.isEmpty {
            return .skippedUnreadable
        }

        // Generate all embeddings before modifying the database, so a failure
        // here preserves the existing index entries for this file.
        var embedded: [(TextChunk, [Float])] = []
        for chunk in chunks {
            if let embedding = embedder.embed(chunk.text) {
                embedded.append((chunk, embedding))
            }
        }

        if embedded.isEmpty {
            print("  Skipped: \(file.relativePath) (failed to embed)")
            return .skippedEmbedFailure
        }

        // Only now that we have new embeddings, remove the old entries
        if removeExisting {
            try database.removeEntries(forPath: file.relativePath)
        }

        for (chunk, embedding) in embedded {
            try database.insert(
                filePath: file.relativePath,
                lineStart: chunk.lineStart,
                lineEnd: chunk.lineEnd,
                chunkType: chunk.type,
                pageNumber: chunk.pageNumber,
                fileModifiedAt: file.modificationDate,
                contentPreview: String(chunk.text.prefix(200)),
                embedding: embedding
            )
        }
        print("  \(label): \(file.relativePath)")
        return .indexed
    }

    func run() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        let database = VectorDatabase(directory: directory)
        try database.open()

        let scanner = FileScanner(directory: directory, includeHiddenFiles: allowHidden)
        let files = try scanner.scan()
        let indexedFiles = try database.allIndexedFiles()

        let embedder = EmbeddingService()
        let extractor = TextExtractor()

        var added = 0
        var updated = 0
        var removed = 0
        var skippedUnreadable = 0
        var skippedEmbedFailures = 0

        // Find files to add or update
        for file in files {
            if let existingModDate = indexedFiles[file.relativePath] {
                if file.modificationDate > existingModDate {
                    // File changed — re-index. removeExisting defers deletion until
                    // new embeddings succeed, preventing data loss on failure.
                    switch try indexFile(file, using: extractor, embedder: embedder, database: database, label: "Updated", removeExisting: true) {
                    case .indexed: updated += 1
                    case .skippedUnreadable: skippedUnreadable += 1
                    case .skippedEmbedFailure: skippedEmbedFailures += 1
                    }
                }
                // Otherwise unchanged — skip
            } else {
                // New file
                switch try indexFile(file, using: extractor, embedder: embedder, database: database, label: "Added") {
                case .indexed: added += 1
                case .skippedUnreadable: skippedUnreadable += 1
                case .skippedEmbedFailure: skippedEmbedFailures += 1
                }
            }
        }

        // Find files to remove
        let currentPaths = Set(files.map(\.relativePath))
        for indexedPath in indexedFiles.keys {
            if !currentPaths.contains(indexedPath) {
                try database.removeEntries(forPath: indexedPath)
                removed += 1
                print("  Removed: \(indexedPath)")
            }
        }

        let skipped = skippedUnreadable + skippedEmbedFailures
        if skipped > 0 {
            var details: [String] = []
            if skippedUnreadable > 0 {
                details.append("\(skippedUnreadable) unreadable")
            }
            if skippedEmbedFailures > 0 {
                details.append("\(skippedEmbedFailures) failed to embed")
            }
            print("Update complete: \(added) added, \(updated) updated, \(removed) removed (\(skipped) skipped: \(details.joined(separator: ", "))).")
        } else {
            print("Update complete: \(added) added, \(updated) updated, \(removed) removed.")
        }
    }
}
