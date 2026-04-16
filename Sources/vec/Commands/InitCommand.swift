import Foundation
import ArgumentParser
import VecKit

struct InitCommand: AsyncParsableCommand {

    static var configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Initialize a vector database for the current directory"
    )

    @Argument(help: "Name for the database (stored in ~/.vec/<db-name>/)")
    var dbName: String

    @Flag(name: .long, help: "Overwrite existing database if present")
    var force: Bool = false

    func run() async throws {
        try DatabaseLocator.validateName(dbName)

        let dbDir = DatabaseLocator.databaseDirectory(for: dbName)
        let sourceDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)

        if FileManager.default.fileExists(atPath: dbDir.path) {
            if !force {
                print("Error: Database '\(dbName)' already exists at \(dbDir.path). Use --force to reinitialize.")
                throw ExitCode.failure
            }
            try FileManager.default.removeItem(at: dbDir)
        }

        let database = VectorDatabase(databaseDirectory: dbDir, sourceDirectory: sourceDir)
        try database.initialize()
        let config = DatabaseConfig(sourceDirectory: sourceDir.path, createdAt: Date())
        try DatabaseLocator.writeConfig(config, to: dbDir)

        print("Initialized empty database '\(dbName)' at \(dbDir.path)")
        print("Run 'vec update-index' from this directory to index files.")
    }
}
