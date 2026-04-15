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
                    let chunks = try extractor.extract(from: file)
                    if chunks.isEmpty {
                        skippedUnreadable += 1
                        continue
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
                        skippedEmbedFailures += 1
                    } else {
                        updated += 1
                    }
                    print("  Updated: \(file.relativePath)")
                }
                // Otherwise unchanged — skip
            } else {
                // New file
                let chunks = try extractor.extract(from: file)
                if chunks.isEmpty {
                    skippedUnreadable += 1
                    continue
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
                    skippedEmbedFailures += 1
                } else {
                    added += 1
                }
                print("  Added: \(file.relativePath)")
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
