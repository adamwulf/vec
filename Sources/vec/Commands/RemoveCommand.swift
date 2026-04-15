import Foundation
import ArgumentParser
import VecKit

struct RemoveCommand: AsyncParsableCommand {

    static var configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove a file from the vector index"
    )

    @Argument(help: "Name of the database (stored in ~/.vec/<db-name>/)")
    var dbName: String

    @Argument(help: "Path to the file to remove from the index")
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

        let database = VectorDatabase(databaseDirectory: dbDir, sourceDirectory: sourceDir)
        try database.open()

        let relativePath = PathUtilities.relativePath(of: filePath.path, in: sourceDir.path)
        let removed = try database.removeEntries(forPath: relativePath)

        if removed > 0 {
            print("Removed \(removed) entries for \(relativePath)")
        } else {
            print("No entries found for \(relativePath)")
        }
    }
}
