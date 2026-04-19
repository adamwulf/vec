import Foundation
import ArgumentParser
import VecKit

struct ListCommand: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
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
        var rows: [(name: String, source: String, files: String, size: String, profile: String)] = []

        for entry in databases {
            let dbDir = DatabaseLocator.databaseDirectory(for: entry.name)
            let sourceExists = FileManager.default.fileExists(atPath: entry.config.sourceDirectory)
            let sourceDisplay = sourceExists
                ? entry.config.sourceDirectory
                : "\(entry.config.sourceDirectory) (missing)"

            // Probe dim: recorded profile carries the real dim; on a
            // pre-profile/fresh DB any non-zero dim works since open()
            // only reads metadata tables.
            let probeDim = entry.config.profile?.dimension ?? 1
            var fileCount: String = ""
            var chunkCount: Int = 0
            do {
                let sourceURL = URL(fileURLWithPath: entry.config.sourceDirectory, isDirectory: true)
                let db = VectorDatabase(
                    databaseDirectory: dbDir,
                    sourceDirectory: sourceURL,
                    dimension: probeDim
                )
                try await db.open()
                let files = try await db.allIndexedFiles()
                chunkCount = try await db.totalChunkCount()
                fileCount = "\(files.count)"
            } catch {
                fileCount = "(error: \(error.localizedDescription))"
                chunkCount = 0
            }

            let dbFilePath = dbDir.appendingPathComponent("index.db").path
            let sizeDisplay: String
            if let attrs = try? FileManager.default.attributesOfItem(atPath: dbFilePath),
               let fileSize = attrs[.size] as? Int64 {
                sizeDisplay = sizeFormatter.string(fromByteCount: fileSize)
            } else {
                sizeDisplay = "unknown"
            }

            let profileDisplay = Self.renderProfileColumn(
                profile: entry.config.profile,
                chunkCount: chunkCount
            )

            rows.append((
                name: entry.name,
                source: sourceDisplay,
                files: fileCount,
                size: sizeDisplay,
                profile: profileDisplay
            ))
        }

        // Calculate column widths
        let nameHeader = "Name"
        let sourceHeader = "Source Directory"
        let filesHeader = "Files"
        let sizeHeader = "Size"
        let profileHeader = "Profile"

        let nameWidth = max(nameHeader.count, rows.map(\.name.count).max() ?? 0)
        let sourceWidth = max(sourceHeader.count, rows.map(\.source.count).max() ?? 0)
        let filesWidth = max(filesHeader.count, rows.map(\.files.count).max() ?? 0)
        let sizeWidth = max(sizeHeader.count, rows.map(\.size.count).max() ?? 0)
        let profileWidth = max(profileHeader.count, rows.map(\.profile.count).max() ?? 0)

        // Print table
        let header = "\(nameHeader.padding(toLength: nameWidth, withPad: " ", startingAt: 0))  "
            + "\(sourceHeader.padding(toLength: sourceWidth, withPad: " ", startingAt: 0))  "
            + "\(filesHeader.padding(toLength: filesWidth, withPad: " ", startingAt: 0))  "
            + "\(sizeHeader.padding(toLength: sizeWidth, withPad: " ", startingAt: 0))  "
            + "\(profileHeader)"
        print(header)
        print(String(repeating: "-",
                     count: nameWidth + 2 + sourceWidth + 2 + filesWidth + 2 + sizeWidth + 2 + profileWidth))

        for row in rows {
            let line = "\(row.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0))  "
                + "\(row.source.padding(toLength: sourceWidth, withPad: " ", startingAt: 0))  "
                + "\(row.files.padding(toLength: filesWidth, withPad: " ", startingAt: 0))  "
                + "\(row.size.padding(toLength: sizeWidth, withPad: " ", startingAt: 0))  "
                + "\(row.profile)"
            print(line)
        }
    }

    /// Per §"Open questions (answered)" Q4: render the profile identity,
    /// or `(not recorded)` / `(pre-profile)` for the two missing-profile
    /// shapes.
    static func renderProfileColumn(
        profile: DatabaseConfig.ProfileRecord?,
        chunkCount: Int
    ) -> String {
        if let recorded = profile {
            return recorded.identity
        }
        return chunkCount > 0 ? "(pre-profile)" : "(not recorded)"
    }
}
