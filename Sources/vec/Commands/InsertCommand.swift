import Foundation
import ArgumentParser
import VecKit

struct InsertCommand: AsyncParsableCommand {

    static var configuration = CommandConfiguration(
        commandName: "insert",
        abstract: "Add or update a specific file in the vector index"
    )

    @Argument(help: "Path to the file to index")
    var path: String

    func run() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let filePath = URL(fileURLWithPath: path, relativeTo: directory).standardized

        // Validate path is within the project directory
        guard filePath.path.hasPrefix(directory.path) else {
            print("Error: Path must be within the project directory.")
            throw ExitCode.failure
        }

        guard FileManager.default.fileExists(atPath: filePath.path) else {
            print("Error: File not found: \(path)")
            throw ExitCode.failure
        }

        let database = VectorDatabase(directory: directory)
        try database.open()

        // Remove existing entries for this file
        let relativePath = PathUtilities.relativePath(of: filePath.path, in: directory.path)
        try database.removeEntries(forPath: relativePath)

        let extractor = TextExtractor()
        let embedder = EmbeddingService()

        let fileInfo = try FileScanner.fileInfo(for: filePath, relativeTo: directory)
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

        print("Indexed \(count) chunks from \(relativePath)")
    }
}
