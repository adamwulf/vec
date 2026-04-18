import Foundation
import ArgumentParser
import VecKit

struct InfoCommand: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Show metadata about a specific database"
    )

    @Option(name: .shortAndLong, help: "Name of the database (stored in ~/.vec/<name>/). Omit to resolve from current directory.")
    var db: String?

    func run() async throws {
        let (dbDir, rawConfig, sourceDir) = try db != nil
            ? DatabaseLocator.resolve(db!)
            : DatabaseLocator.resolveFromCurrentDirectory()

        let database = VectorDatabase(
            databaseDirectory: dbDir,
            sourceDirectory: sourceDir,
            dimension: rawConfig.embedder?.dimension ?? 0
        )
        try await database.open()

        let fileCount = try await database.allIndexedFiles().count
        let chunkCount = try await database.totalChunkCount()

        // Pre-refactor DBs: stamp nomic if vectors exist without a
        // recorded embedder, so `vec info` reports reality.
        let config = try DatabaseLocator.migratePreRefactorEmbedderRecord(
            config: rawConfig, chunkCount: chunkCount, dbDir: dbDir
        )

        // Format created-at date
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        dateFormatter.timeZone = .current
        let createdString = dateFormatter.string(from: config.createdAt)

        // Format database file size
        let dbFilePath = dbDir.appendingPathComponent("index.db").path
        let sizeString: String
        if let attrs = try? FileManager.default.attributesOfItem(atPath: dbFilePath),
           let fileSize = attrs[.size] as? Int64 {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            sizeString = formatter.string(fromByteCount: fileSize)
        } else {
            sizeString = "unknown"
        }

        let embedderString = config.embedder.map { "\($0.name) (\($0.dimension)d)" } ?? "(not yet recorded)"

        print("Database:     \(dbDir.lastPathComponent)")
        print("Source:       \(sourceDir.path)")
        print("Created:      \(createdString)")
        print("Embedder:     \(embedderString)")
        print("Files:        \(fileCount)")
        print("Chunks:       \(chunkCount)")
        print("DB size:      \(sizeString)")
    }
}
