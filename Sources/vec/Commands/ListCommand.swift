import Foundation
import ArgumentParser
import VecKit

struct ListCommand: AsyncParsableCommand {

    static var configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all vector databases"
    )

    func run() async throws {
        let databases: [(name: String, config: DatabaseConfig)]
        do {
            databases = try DatabaseLocator.allDatabases()
        } catch {
            print("Error: Failed to list databases: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        guard !databases.isEmpty else {
            print("No databases found. Run `vec init <db-name>` to create one.")
            return
        }

        // Gather info for each database
        var rows: [(name: String, source: String, status: String)] = []

        for entry in databases {
            let dbDir = DatabaseLocator.databaseDirectory(for: entry.name)
            let sourceExists = FileManager.default.fileExists(atPath: entry.config.sourceDirectory)
            let sourceDisplay = sourceExists
                ? entry.config.sourceDirectory
                : "\(entry.config.sourceDirectory) (missing)"

            let fileCount: String
            do {
                let sourceURL = URL(fileURLWithPath: entry.config.sourceDirectory)
                let db = VectorDatabase(databaseDirectory: dbDir, sourceDirectory: sourceURL)
                try db.open()
                let files = try db.allIndexedFiles()
                fileCount = "\(files.count)"
            } catch {
                fileCount = "(error: \(error.localizedDescription))"
            }

            rows.append((name: entry.name, source: sourceDisplay, status: fileCount))
        }

        // Calculate column widths
        let nameHeader = "Name"
        let sourceHeader = "Source Directory"
        let filesHeader = "Files"

        let nameWidth = max(nameHeader.count, rows.map(\.name.count).max() ?? 0)
        let sourceWidth = max(sourceHeader.count, rows.map(\.source.count).max() ?? 0)
        let filesWidth = max(filesHeader.count, rows.map(\.status.count).max() ?? 0)

        // Print table
        let header = "\(nameHeader.padding(toLength: nameWidth, withPad: " ", startingAt: 0))  \(sourceHeader.padding(toLength: sourceWidth, withPad: " ", startingAt: 0))  \(filesHeader)"
        print(header)
        print(String(repeating: "-", count: nameWidth + 2 + sourceWidth + 2 + filesWidth))

        for row in rows {
            let line = "\(row.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0))  \(row.source.padding(toLength: sourceWidth, withPad: " ", startingAt: 0))  \(row.status)"
            print(line)
        }
    }
}
