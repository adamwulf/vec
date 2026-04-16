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
        removeExisting: Bool = false,
        verbose: Bool = false
    ) throws -> IndexResult {
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

        // Generate all embeddings before modifying the database, so a failure
        // here preserves the existing index entries for this file.
        var warnedNonEnglish = false
        var embedded: [(TextChunk, [Float])] = []
        let totalChunks = chunks.count
        for (index, chunk) in chunks.enumerated() {
            embedder.warnIfNonEnglish(text: chunk.text, filePath: file.relativePath, warned: &warnedNonEnglish)
            if let embedding = embedder.embed(chunk.text) {
                embedded.append((chunk, embedding))
            }
            if verbose {
                let pct = Int(Double(index + 1) / Double(totalChunks) * 100)
                print("  \(label): \(file.relativePath) [\(index + 1)/\(totalChunks) chunks, \(pct)%]", terminator: "\r")
                fflush(stdout)
            }
        }

        if embedded.isEmpty {
            if verbose {
                // Clear the progress line before printing skip message
                print("  Skipped: \(file.relativePath) (failed to embed \(chunks.count) chunks)")
            }
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
        if verbose {
            // Print final line replacing the progress indicator
            print("  \(label): \(file.relativePath) (\(embedded.count) chunks)")
        }
        return .indexed
    }

    func run() async throws {
        let (dbDir, _, sourceDir) = try db != nil
            ? DatabaseLocator.resolve(db!)
            : DatabaseLocator.resolveFromCurrentDirectory()

        let database = VectorDatabase(databaseDirectory: dbDir, sourceDirectory: sourceDir)
        try database.open()

        let scanner = FileScanner(directory: sourceDir, includeHiddenFiles: allowHidden)
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
        var unchanged = 0
        for file in files {
            if let existingModDate = indexedFiles[file.relativePath] {
                if file.modificationDate > existingModDate {
                    // File changed — re-index. removeExisting defers deletion until
                    // new embeddings succeed, preventing data loss on failure.
                    switch try indexFile(file, using: extractor, embedder: embedder, database: database, label: "Updated", removeExisting: true, verbose: verbose) {
                    case .indexed: updated += 1
                    case .skippedUnreadable: skippedUnreadable += 1
                    case .skippedEmbedFailure: skippedEmbedFailures += 1
                    }
                } else {
                    unchanged += 1
                    if verbose {
                        print("  Unchanged: \(file.relativePath)")
                    }
                }
            } else {
                // New file
                switch try indexFile(file, using: extractor, embedder: embedder, database: database, label: "Added", verbose: verbose) {
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
