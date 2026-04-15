import Foundation
import ArgumentParser
import VecKit

struct InfoCommand: AsyncParsableCommand {

    static var configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Show metadata about a specific database"
    )

    @Argument(help: "Name of the database to inspect (stored in ~/.vec/<db-name>/)")
    var dbName: String

    func run() async throws {
        let (dbDir, config, sourceDir) = try DatabaseLocator.resolve(dbName)

        let database = VectorDatabase(databaseDirectory: dbDir, sourceDirectory: sourceDir)
        try database.open()

        let fileCount = try database.allIndexedFiles().count
        let chunkCount = try database.totalChunkCount()

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

        print("Database:     \(dbName)")
        print("Source:       \(sourceDir.path)")
        print("Created:      \(createdString)")
        print("Files:        \(fileCount)")
        print("Chunks:       \(chunkCount)")
        print("DB size:      \(sizeString)")
    }
}
