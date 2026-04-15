import Foundation
import ArgumentParser
import VecKit

struct UpdateIndexCommand: AsyncParsableCommand {

    static var configuration = CommandConfiguration(
        commandName: "update-index",
        abstract: "Update the vector index with new or modified files"
    )

    func run() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        let database = VectorDatabase(directory: directory)
        try database.open()

        let scanner = FileScanner(directory: directory)
        let files = try scanner.scan()
        let indexedFiles = try database.allIndexedFiles()

        let embedder = EmbeddingService()
        let extractor = TextExtractor()

        var added = 0
        var updated = 0
        var removed = 0

        // Find files to add or update
        for file in files {
            if let existingModDate = indexedFiles[file.relativePath] {
                if file.modificationDate > existingModDate {
                    // File changed — re-index
                    try database.removeEntries(forPath: file.relativePath)
                    let chunks = try extractor.extract(from: file)
                    for chunk in chunks {
                        guard let embedding = embedder.embed(chunk.text) else { continue }
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
                    updated += 1
                    print("  Updated: \(file.relativePath)")
                }
                // Otherwise unchanged — skip
            } else {
                // New file
                let chunks = try extractor.extract(from: file)
                for chunk in chunks {
                    guard let embedding = embedder.embed(chunk.text) else { continue }
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
                added += 1
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

        print("Update complete: \(added) added, \(updated) updated, \(removed) removed.")
    }
}
