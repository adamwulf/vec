import Foundation
import ArgumentParser
import VecKit

struct DeinitCommand: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "deinit",
        abstract: "Remove a vector database"
    )

    @Argument(help: "Name of the database to remove (stored in ~/.vec/<db-name>/)")
    var dbName: String

    @Flag(name: .long, help: "Skip confirmation prompt")
    var force: Bool = false

    func run() async throws {
        try DatabaseLocator.validateName(dbName)

        let dbDir = DatabaseLocator.databaseDirectory(for: dbName)

        guard FileManager.default.fileExists(atPath: dbDir.path) else {
            print("Error: Database '\(dbName)' not found.")
            throw ExitCode.failure
        }

        if !force {
            print("This will permanently delete database '\(dbName)' at \(dbDir.path).")
            print("Type the database name to confirm: ", terminator: "")
            guard let confirmation = readLine(), confirmation == dbName else {
                print("Aborted.")
                throw ExitCode.failure
            }
        }

        try FileManager.default.removeItem(at: dbDir)
        print("Removed database '\(dbName)'.")
    }
}
