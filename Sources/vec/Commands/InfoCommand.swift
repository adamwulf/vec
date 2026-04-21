import Foundation
import ArgumentParser
import VecKit

struct InfoCommand: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Show metadata about a specific database"
    )

    @Option(name: .shortAndLong, help: "Name of the database (stored in ~/.vec/<name>/). Omit to resolve from current directory.")
    var db: String?

    func run() async throws {
        let (dbDir, config, sourceDir) = try db != nil
            ? DatabaseLocator.resolve(db!)
            : DatabaseLocator.resolveFromCurrentDirectory()

        // Dimension is only needed for open() to succeed when the DB
        // already has rows. The recorded profile carries the real dim;
        // on a fresh/reset/pre-profile DB we pass any non-zero dim as a
        // placeholder since open() won't read vectors here.
        let probeDim = config.profile?.dimension ?? 1
        let database = VectorDatabase(
            databaseDirectory: dbDir,
            sourceDirectory: sourceDir,
            dimension: probeDim
        )
        try await database.open()

        let fileCount = try await database.allIndexedFiles().count
        let chunkCount = try await database.totalChunkCount()

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

        let profileString = try Self.renderProfileLine(
            profile: config.profile,
            chunkCount: chunkCount
        )

        print("Database:     \(dbDir.lastPathComponent)")
        print("Source:       \(sourceDir.path)")
        print("Created:      \(createdString)")
        print("Profile:      \(profileString)")
        print("Files:        \(fileCount)")
        print("Chunks:       \(chunkCount)")
        print("DB size:      \(sizeString)")
    }

    /// Renders the `Profile:` line body per §"Open questions (answered)" Q1.
    /// Split out so future testing can assert the exact strings without
    /// spinning up an on-disk DB.
    static func renderProfileLine(
        profile: DatabaseConfig.ProfileRecord?,
        chunkCount: Int
    ) throws -> String {
        guard let recorded = profile else {
            if chunkCount > 0 {
                return "(pre-profile database — run `vec reset <db>` to rebuild)"
            } else {
                return "(not yet recorded)"
            }
        }
        // Resolve identity through the factory so `isBuiltIn` reflects
        // whether the recorded chunk params match the alias defaults.
        // Per plan Q1: on unknown-alias or malformed identity the resolve
        // error propagates so `info` surfaces the standard
        // `unknownProfile` / `malformedProfileIdentity` message.
        let live = try IndexingProfileFactory.resolve(identity: recorded.identity)
        if live.isBuiltIn {
            return "\(live.identity) (\(live.embedder.dimension)d)"
        } else {
            let parsed = try IndexingProfile.parseIdentity(live.identity)
            return "\(live.identity) (custom, based on \(parsed.alias)) (\(live.embedder.dimension)d)"
        }
    }
}
