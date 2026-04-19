import Foundation
import ArgumentParser
import VecKit

struct RemoveCommand: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove a file from the vector index"
    )

    @Option(name: .shortAndLong, help: "Name of the database (stored in ~/.vec/<name>/). Omit to resolve from current directory.")
    var db: String?

    @Argument(help: "Path to the file to remove from the index")
    var path: String

    func run() async throws {
        let (dbDir, config, sourceDir) = try db != nil
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

        let database = VectorDatabase(
            databaseDirectory: dbDir,
            sourceDirectory: sourceDir,
            dimension: config.profile?.dimension ?? 1
        )
        try await database.open()

        let relativePath = PathUtilities.relativePath(of: filePath.path, in: sourceDir.path)
        let removed = try await database.removeEntries(forPath: relativePath)

        if removed > 0 {
            print("Removed \(removed) entries for \(relativePath)")
        } else {
            print("No entries found for \(relativePath)")
        }
    }
}
