import Foundation
import ArgumentParser
import VecKit

struct ResetCommand: AsyncParsableCommand {

    static var configuration = CommandConfiguration(
        commandName: "reset",
        abstract: "Delete and recreate an empty database, preserving its source directory"
    )

    @Option(name: .shortAndLong, help: "Name of the database to reset. Omit to resolve from current directory.")
    var db: String?

    @Flag(name: .long, help: "Skip confirmation prompt")
    var force: Bool = false

    func run() async throws {
        // Resolve the target database and capture its configured source directory
        // before we delete anything. Using the stored source (not cwd) keeps the
        // reset idempotent regardless of where the command is invoked from.
        let (dbDir, _, sourceDir) = try db != nil
            ? DatabaseLocator.resolve(db!)
            : DatabaseLocator.resolveFromCurrentDirectory()

        let dbName = dbDir.lastPathComponent

        if !force {
            print("This will permanently delete all indexed data in '\(dbName)' at \(dbDir.path).")
            print("Type the database name to confirm: ", terminator: "")
            guard let confirmation = readLine(), confirmation == dbName else {
                print("Aborted.")
                throw ExitCode.failure
            }
        }

        // Delete the existing directory, then re-create an empty database
        // pointed at the same source directory.
        try FileManager.default.removeItem(at: dbDir)

        let database = VectorDatabase(databaseDirectory: dbDir, sourceDirectory: sourceDir)
        try await database.initialize()
        let config = DatabaseConfig(sourceDirectory: sourceDir.path, createdAt: Date())
        try DatabaseLocator.writeConfig(config, to: dbDir)

        print("Reset database '\(dbName)' at \(dbDir.path)")
        print("Source: \(sourceDir.path)")
        print("Run 'vec update-index' to re-index files.")
    }
}
