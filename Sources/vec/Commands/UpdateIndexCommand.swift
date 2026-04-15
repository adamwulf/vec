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

    private func indexFile(
        _ file: FileInfo,
        using extractor: TextExtractor,
        embedder: EmbeddingService,
        database: VectorDatabase,
        label: String
    ) throws -> IndexResult {
        let chunks = try extractor.extract(from: file)
        if chunks.isEmpty {
            return .skippedUnreadable
        }
        var embedFailures = 0
        for chunk in chunks {
            guard let embedding = embedder.embed(chunk.text) else {
                embedFailures += 1
                continue
            }
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
        if embedFailures == chunks.count {
            print("  Skipped: \(file.relativePath) (failed to embed)")
            return .skippedEmbedFailure
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
                    // File changed — re-index
                    try database.removeEntries(forPath: file.relativePath)
                    switch try indexFile(file, using: extractor, embedder: embedder, database: database, label: "Updated") {
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
