import Foundation

/// Configuration metadata stored alongside each database.
public struct DatabaseConfig: Codable {
    /// Absolute path to the directory that was indexed.
    public let sourceDirectory: String
    /// When the database was created.
    public let createdAt: Date

    public init(sourceDirectory: String, createdAt: Date) {
        self.sourceDirectory = sourceDirectory
        self.createdAt = createdAt
    }

    /// The filename used to store the config inside a database directory.
    static let filename = "config.json"
}

/// Locates and validates centralized database directories under `~/.vec/`.
public struct DatabaseLocator {

    /// The base directory for all vec databases (`~/.vec/`).
    public static var baseDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vec")
    }

    /// Returns the directory for a specific named database (`~/.vec/<name>/`).
    public static func databaseDirectory(for name: String) -> URL {
        baseDirectory.appendingPathComponent(name)
    }

    /// Reserved names that cannot be used as database names because they
    /// conflict with subcommand names.
    private static let reservedNames: Set<String> = [
        "init", "list", "search", "update-index", "insert", "remove", "help", "version"
    ]

    /// Validates that a database name contains only allowed characters
    /// and does not conflict with subcommand names.
    ///
    /// Allowed: alphanumeric characters, hyphens, and underscores.
    /// Must be non-empty.
    public static func validateName(_ name: String) throws {
        guard !name.isEmpty else {
            throw VecError.invalidDatabaseName(name)
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw VecError.invalidDatabaseName(name)
        }
        if reservedNames.contains(name) {
            throw VecError.invalidDatabaseName(name)
        }
    }

    /// Lists all databases in `~/.vec/` that contain a valid `config.json`.
    ///
    /// Directories without a parseable `config.json` are silently skipped.
    public static func allDatabases() throws -> [(name: String, config: DatabaseConfig)] {
        let fm = FileManager.default
        let base = baseDirectory

        guard fm.fileExists(atPath: base.path) else {
            return []
        }

        let contents = try fm.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var results: [(name: String, config: DatabaseConfig)] = []

        for url in contents {
            let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard resourceValues?.isDirectory == true else { continue }

            let configURL = url.appendingPathComponent(DatabaseConfig.filename)
            guard let data = try? Data(contentsOf: configURL) else { continue }
            guard let config = try? decoder.decode(DatabaseConfig.self, from: data) else { continue }

            results.append((name: url.lastPathComponent, config: config))
        }

        return results.sorted { $0.name < $1.name }
    }

    /// Writes a `DatabaseConfig` to the config.json file in the given database directory.
    public static func writeConfig(_ config: DatabaseConfig, to databaseDirectory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(config)
        let configURL = databaseDirectory.appendingPathComponent(DatabaseConfig.filename)
        try data.write(to: configURL)
    }

    /// Reads a `DatabaseConfig` from the config.json file in the given database directory.
    public static func readConfig(from databaseDirectory: URL) throws -> DatabaseConfig {
        let configURL = databaseDirectory.appendingPathComponent(DatabaseConfig.filename)
        let data: Data
        do {
            data = try Data(contentsOf: configURL)
        } catch {
            throw VecError.databaseCorrupted("config.json is missing or unreadable: \(error.localizedDescription)")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(DatabaseConfig.self, from: data)
        } catch {
            throw VecError.databaseCorrupted("config.json is malformed: \(error.localizedDescription)")
        }
    }

    /// Resolves a named database, returning its directory, config, and source directory URL.
    ///
    /// Validates the name, checks the database exists, reads config.json,
    /// and verifies the source directory still exists on disk.
    public static func resolve(_ name: String) throws -> (dbDir: URL, config: DatabaseConfig, sourceDir: URL) {
        try validateName(name)

        let dbDir = databaseDirectory(for: name)

        guard FileManager.default.fileExists(atPath: dbDir.path) else {
            throw VecError.databaseNotFound(name)
        }

        let config = try readConfig(from: dbDir)
        let sourceDir = URL(fileURLWithPath: config.sourceDirectory, isDirectory: true)

        guard FileManager.default.fileExists(atPath: sourceDir.path) else {
            throw VecError.sourceDirectoryMissing(config.sourceDirectory)
        }

        return (dbDir, config, sourceDir)
    }
}
