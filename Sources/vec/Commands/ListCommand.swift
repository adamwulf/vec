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

        let sizeFormatter = ByteCountFormatter()
        sizeFormatter.countStyle = .file

        // Gather info for each database
        var rows: [(name: String, source: String, files: String, size: String)] = []

        for entry in databases {
            let dbDir = DatabaseLocator.databaseDirectory(for: entry.name)
            let sourceExists = FileManager.default.fileExists(atPath: entry.config.sourceDirectory)
            let sourceDisplay = sourceExists
                ? entry.config.sourceDirectory
                : "\(entry.config.sourceDirectory) (missing)"

            let fileCount: String
            do {
                let sourceURL = URL(fileURLWithPath: entry.config.sourceDirectory, isDirectory: true)
                let db = VectorDatabase(databaseDirectory: dbDir, sourceDirectory: sourceURL)
                try await db.open()
                let files = try await db.allIndexedFiles()
                fileCount = "\(files.count)"
            } catch {
                fileCount = "(error: \(error.localizedDescription))"
            }

            let dbFilePath = dbDir.appendingPathComponent("index.db").path
            let sizeDisplay: String
            if let attrs = try? FileManager.default.attributesOfItem(atPath: dbFilePath),
               let fileSize = attrs[.size] as? Int64 {
                sizeDisplay = sizeFormatter.string(fromByteCount: fileSize)
            } else {
                sizeDisplay = "unknown"
            }

            rows.append((name: entry.name, source: sourceDisplay, files: fileCount, size: sizeDisplay))
        }

        // Calculate column widths
        let nameHeader = "Name"
        let sourceHeader = "Source Directory"
        let filesHeader = "Files"
        let sizeHeader = "Size"

        let nameWidth = max(nameHeader.count, rows.map(\.name.count).max() ?? 0)
        let sourceWidth = max(sourceHeader.count, rows.map(\.source.count).max() ?? 0)
        let filesWidth = max(filesHeader.count, rows.map(\.files.count).max() ?? 0)
        let sizeWidth = max(sizeHeader.count, rows.map(\.size.count).max() ?? 0)

        // Print table
        let header = "\(nameHeader.padding(toLength: nameWidth, withPad: " ", startingAt: 0))  "
            + "\(sourceHeader.padding(toLength: sourceWidth, withPad: " ", startingAt: 0))  "
            + "\(filesHeader.padding(toLength: filesWidth, withPad: " ", startingAt: 0))  "
            + "\(sizeHeader)"
        print(header)
        print(String(repeating: "-", count: nameWidth + 2 + sourceWidth + 2 + filesWidth + 2 + sizeWidth))

        for row in rows {
            let line = "\(row.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0))  "
                + "\(row.source.padding(toLength: sourceWidth, withPad: " ", startingAt: 0))  "
                + "\(row.files.padding(toLength: filesWidth, withPad: " ", startingAt: 0))  "
                + "\(row.size)"
            print(line)
        }
    }
}
