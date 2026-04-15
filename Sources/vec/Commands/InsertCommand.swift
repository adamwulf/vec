import Foundation
import ArgumentParser
import VecKit

struct InsertCommand: AsyncParsableCommand {

    static var configuration = CommandConfiguration(
        commandName: "insert",
        abstract: "Add or update a specific file in the vector index"
    )

    @Argument(help: "Name of the database (stored in ~/.vec/<db-name>/)")
    var dbName: String

    @Argument(help: "Path to the file to index")
    var path: String

    func run() async throws {
        try DatabaseLocator.validateName(dbName)

        let dbDir = DatabaseLocator.databaseDirectory(for: dbName)

        guard FileManager.default.fileExists(atPath: dbDir.path) else {
            throw VecError.databaseNotFound(dbName)
        }

        let config = try DatabaseLocator.readConfig(from: dbDir)
        let sourceDir = URL(fileURLWithPath: config.sourceDirectory)

        let filePath = URL(fileURLWithPath: path, relativeTo: sourceDir).standardized

        // Validate path is within the source directory (append "/" to prevent prefix collisions)
        guard filePath.path.hasPrefix(sourceDir.path + "/") || filePath.path == sourceDir.path else {
            print("Error: Path must be within the source directory.")
            throw ExitCode.failure
        }

        guard FileManager.default.fileExists(atPath: filePath.path) else {
            print("Error: File not found: \(path)")
            throw ExitCode.failure
        }

        let database = VectorDatabase(databaseDirectory: dbDir, sourceDirectory: sourceDir)
        try database.open()

        // Remove existing entries for this file
        let relativePath = PathUtilities.relativePath(of: filePath.path, in: sourceDir.path)
        try database.removeEntries(forPath: relativePath)

        let extractor = TextExtractor()
        let embedder = EmbeddingService()

        let fileInfo = try FileScanner.fileInfo(for: filePath, relativeTo: sourceDir)
        let chunks = try extractor.extract(from: fileInfo)

        var count = 0
        for chunk in chunks {
            guard let embedding = embedder.embed(chunk.text) else { continue }
            try database.insert(
                filePath: relativePath,
                lineStart: chunk.lineStart,
                lineEnd: chunk.lineEnd,
                chunkType: chunk.type,
                pageNumber: chunk.pageNumber,
                fileModifiedAt: fileInfo.modificationDate,
                contentPreview: String(chunk.text.prefix(200)),
                embedding: embedding
            )
            count += 1
        }

        if count == 0 && !chunks.isEmpty {
            print("Warning: \(chunks.count) chunks extracted but none could be embedded from \(relativePath)")
        }
        print("Indexed \(count) chunks from \(relativePath)")
    }
}
