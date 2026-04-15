import Foundation
import ArgumentParser
import VecKit

struct RemoveCommand: AsyncParsableCommand {

    static var configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove a file from the vector index"
    )

    @Argument(help: "Path to the file to remove from the index")
    var path: String

    func run() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let filePath = URL(fileURLWithPath: path, relativeTo: directory).standardized

        // Validate path is within the project directory (append "/" to prevent prefix collisions)
        guard filePath.path.hasPrefix(directory.path + "/") || filePath.path == directory.path else {
            print("Error: Path must be within the project directory.")
            throw ExitCode.failure
        }

        let database = VectorDatabase(directory: directory)
        try database.open()

        let relativePath = PathUtilities.relativePath(of: filePath.path, in: directory.path)
        let removed = try database.removeEntries(forPath: relativePath)

        if removed > 0 {
            print("Removed \(removed) entries for \(relativePath)")
        } else {
            print("No entries found for \(relativePath)")
        }
    }
}
