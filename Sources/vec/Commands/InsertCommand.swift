import Foundation
import ArgumentParser
import VecKit

struct InsertCommand: AsyncParsableCommand {

    static var configuration = CommandConfiguration(
        commandName: "insert",
        abstract: "Add or update a specific file in the vector index"
    )

    @Option(name: .shortAndLong, help: "Name of the database (stored in ~/.vec/<name>/). Omit to resolve from current directory.")
    var db: String?

    @Argument(help: "Path to the file to index")
    var path: String

    func run() async throws {
        let (dbDir, _, sourceDir) = try db != nil
            ? DatabaseLocator.resolve(db!)
            : DatabaseLocator.resolveFromCurrentDirectory()

        // Resolve path relative to cwd, then validate it falls within sourceDir
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let filePath = URL(fileURLWithPath: path, relativeTo: cwd).standardized

        // Validate path is within the source directory (append "/" to prevent prefix collisions)
        guard filePath.path.hasPrefix(sourceDir.path + "/") else {
            print("Error: Path must be within the source directory (\(sourceDir.path)).")
            throw ExitCode.failure
        }

        guard FileManager.default.fileExists(atPath: filePath.path) else {
            print("Error: File not found: \(path)")
            throw ExitCode.failure
        }

        let database = VectorDatabase(databaseDirectory: dbDir, sourceDirectory: sourceDir)
        try await database.open()

        // Remove existing entries for this file
        let relativePath = PathUtilities.relativePath(of: filePath.path, in: sourceDir.path)
        try await database.removeEntries(forPath: relativePath)

        let extractor = TextExtractor()
        let embedder = EmbeddingService()

        let fileInfo = try FileScanner.fileInfo(for: filePath, relativeTo: sourceDir)
        let chunks = try extractor.extract(from: fileInfo)

        // Embed all chunks in parallel
        let embedded: [(TextChunk, [Float])] = await withTaskGroup(of: (Int, TextChunk, [Float]?).self) { group in
            for (index, chunk) in chunks.enumerated() {
                group.addTask {
                    let vector = embedder.embed(chunk.text)
                    return (index, chunk, vector)
                }
            }

            var results: [(index: Int, chunk: TextChunk, embedding: [Float])] = []
            for await (index, chunk, vector) in group {
                if let vector = vector {
                    results.append((index, chunk, vector))
                }
            }
            results.sort { $0.index < $1.index }
            return results.map { ($0.chunk, $0.embedding) }
        }

        // Insert all embeddings into the database
        for (chunk, embedding) in embedded {
            try await database.insert(
                filePath: relativePath,
                lineStart: chunk.lineStart,
                lineEnd: chunk.lineEnd,
                chunkType: chunk.type,
                pageNumber: chunk.pageNumber,
                fileModifiedAt: fileInfo.modificationDate,
                contentPreview: String(chunk.text.prefix(200)),
                embedding: embedding
            )
        }

        if embedded.isEmpty && !chunks.isEmpty {
            print("Warning: \(chunks.count) chunks extracted but none could be embedded from \(relativePath)")
        }
        print("Indexed \(embedded.count) chunks from \(relativePath)")
    }
}
