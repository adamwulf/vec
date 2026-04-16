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

    /// Maximum number of chunks to embed and flush to the database at once.
    private static let batchSize = 20

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

        let relativePath = PathUtilities.relativePath(of: filePath.path, in: sourceDir.path)

        let extractor = TextExtractor()
        let embedder = EmbeddingService()

        let fileInfo = try FileScanner.fileInfo(for: filePath, relativeTo: sourceDir)
        let chunks = try extractor.extract(from: fileInfo)

        // Remove completion record first so interruption triggers re-index
        try await database.unmarkFileIndexed(path: relativePath)
        // Remove any existing chunks (partial or full)
        try await database.removeEntries(forPath: relativePath)

        var totalInserted = 0
        var warnedNonEnglish = false

        // Process chunks in batches to bound memory
        for batchStart in stride(from: 0, to: chunks.count, by: Self.batchSize) {
            let batchEnd = min(batchStart + Self.batchSize, chunks.count)
            let batch = chunks[batchStart..<batchEnd]

            // Embed sequentially — NLEmbedding is not safe for concurrent use
            var records: [ChunkRecord] = []
            for chunk in batch {
                embedder.warnIfNonEnglish(text: chunk.text, filePath: relativePath, warned: &warnedNonEnglish)
                guard let vector = embedder.embed(chunk.text) else { continue }
                records.append(ChunkRecord(
                    filePath: relativePath,
                    lineStart: chunk.lineStart,
                    lineEnd: chunk.lineEnd,
                    chunkType: chunk.type,
                    pageNumber: chunk.pageNumber,
                    fileModifiedAt: fileInfo.modificationDate,
                    contentPreview: String(chunk.text.prefix(200)),
                    embedding: vector
                ))
            }

            guard !records.isEmpty else { continue }

            try await database.insertBatch(records)
            totalInserted += records.count
        }

        if totalInserted == 0 && !chunks.isEmpty {
            print("Warning: \(chunks.count) chunks extracted but none could be embedded from \(relativePath)")
        }

        // Mark file as fully indexed only after all chunks succeed
        if totalInserted > 0 {
            try await database.markFileIndexed(path: relativePath, modifiedAt: fileInfo.modificationDate)
        }
        print("Indexed \(totalInserted) chunks from \(relativePath)")
    }
}
