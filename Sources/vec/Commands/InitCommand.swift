import Foundation
import ArgumentParser
import VecKit

struct InitCommand: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Initialize a vector database for the current directory"
    )

    @Argument(help: "Name for the database (stored in ~/.vec/<db-name>/). Defaults to the current directory name if not provided and no index already exists with that name.")
    var dbName: String?

    @Flag(name: .long, help: "Overwrite existing database if present")
    var force: Bool = false

    func run() async throws {
        let sourceDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let resolvedName = try resolveName(sourceDir: sourceDir)

        let dbDir = DatabaseLocator.databaseDirectory(for: resolvedName)

        if FileManager.default.fileExists(atPath: dbDir.path) {
            if !force {
                print("Error: Database '\(resolvedName)' already exists at \(dbDir.path). Use --force to reinitialize.")
                throw ExitCode.failure
            }
            try FileManager.default.removeItem(at: dbDir)
        }

        // Dimension is set on first update-index when an embedder is chosen.
        let database = VectorDatabase(databaseDirectory: dbDir, sourceDirectory: sourceDir, dimension: 0)
        try await database.initialize()
        let config = DatabaseConfig(sourceDirectory: sourceDir.path, createdAt: Date())
        try DatabaseLocator.writeConfig(config, to: dbDir)

        print("Initialized empty database '\(resolvedName)' at \(dbDir.path)")
        print("Run 'vec update-index' from this directory to index files.")
    }

    /// Resolves the database name: uses the explicit argument if given, otherwise
    /// derives it from the current directory (sanitizing disallowed characters to `-`).
    /// When defaulting, requires that no database already exists with that name
    /// (unless `--force` is set).
    private func resolveName(sourceDir: URL) throws -> String {
        if let explicit = dbName {
            try DatabaseLocator.validateName(explicit)
            return explicit
        }

        let dirName = sourceDir.lastPathComponent
        let sanitized = InitCommand.sanitize(dirName)

        do {
            try DatabaseLocator.validateName(sanitized)
        } catch {
            print("Error: Cannot derive database name from directory '\(dirName)'. Provide a name explicitly: 'vec init <db-name>'.")
            throw ExitCode.failure
        }

        let dbDir = DatabaseLocator.databaseDirectory(for: sanitized)
        if FileManager.default.fileExists(atPath: dbDir.path) && !force {
            print("Error: Database '\(sanitized)' already exists at \(dbDir.path). Provide a different name or use --force to reinitialize.")
            throw ExitCode.failure
        }

        return sanitized
    }

    /// Replaces any character outside `[A-Za-z0-9_-]` with `-`, collapses runs of
    /// `-`, and trims leading/trailing `-`. Returns `""` if the result is empty.
    static func sanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        var result = ""
        var lastWasDash = false
        for scalar in name.unicodeScalars {
            if allowed.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasDash = (scalar == "-")
            } else {
                if !lastWasDash {
                    result.append("-")
                    lastWasDash = true
                }
            }
        }
        while result.hasPrefix("-") { result.removeFirst() }
        while result.hasSuffix("-") { result.removeLast() }
        return result
    }
}
