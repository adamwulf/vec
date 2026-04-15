import XCTest
@testable import VecKit

final class DatabaseLocatorTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("DatabaseLocatorTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        tempDir = realpath(raw.path, &buf) != nil
            ? URL(fileURLWithPath: String(cString: buf), isDirectory: true)
            : raw
    }

    override func tearDown() {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    // MARK: - validateName

    func testValidateNameAcceptsAlphanumeric() throws {
        XCTAssertNoThrow(try DatabaseLocator.validateName("myproject"))
        XCTAssertNoThrow(try DatabaseLocator.validateName("MyProject123"))
        XCTAssertNoThrow(try DatabaseLocator.validateName("abc"))
        XCTAssertNoThrow(try DatabaseLocator.validateName("A"))
        XCTAssertNoThrow(try DatabaseLocator.validateName("9"))
    }

    func testValidateNameAcceptsHyphensAndUnderscores() throws {
        XCTAssertNoThrow(try DatabaseLocator.validateName("my-project"))
        XCTAssertNoThrow(try DatabaseLocator.validateName("my_project"))
        XCTAssertNoThrow(try DatabaseLocator.validateName("a-b_c-d"))
        XCTAssertNoThrow(try DatabaseLocator.validateName("test-db-2"))
    }

    func testValidateNameRejectsEmptyString() {
        XCTAssertThrowsError(try DatabaseLocator.validateName("")) { error in
            guard let vecError = error as? VecError else {
                XCTFail("Expected VecError, got \(error)")
                return
            }
            if case .invalidDatabaseName(let name) = vecError {
                XCTAssertEqual(name, "")
            } else {
                XCTFail("Expected .invalidDatabaseName, got \(vecError)")
            }
        }
    }

    func testValidateNameRejectsSpaces() {
        XCTAssertThrowsError(try DatabaseLocator.validateName("my project"))
    }

    func testValidateNameRejectsSlashes() {
        XCTAssertThrowsError(try DatabaseLocator.validateName("my/project"))
        XCTAssertThrowsError(try DatabaseLocator.validateName("path\\name"))
    }

    func testValidateNameRejectsSpecialCharacters() {
        XCTAssertThrowsError(try DatabaseLocator.validateName("my.project"))
        XCTAssertThrowsError(try DatabaseLocator.validateName("project!"))
        XCTAssertThrowsError(try DatabaseLocator.validateName("project@name"))
        XCTAssertThrowsError(try DatabaseLocator.validateName("project#1"))
    }

    func testValidateNameRejectsPathTraversalNames() {
        XCTAssertThrowsError(try DatabaseLocator.validateName("."))
        XCTAssertThrowsError(try DatabaseLocator.validateName(".."))
    }

    func testValidateNameRejectsReservedCommandNames() {
        XCTAssertThrowsError(try DatabaseLocator.validateName("init"))
        XCTAssertThrowsError(try DatabaseLocator.validateName("list"))
        XCTAssertThrowsError(try DatabaseLocator.validateName("search"))
        XCTAssertThrowsError(try DatabaseLocator.validateName("insert"))
        XCTAssertThrowsError(try DatabaseLocator.validateName("remove"))
        XCTAssertThrowsError(try DatabaseLocator.validateName("update-index"))
        XCTAssertThrowsError(try DatabaseLocator.validateName("help"))
        XCTAssertThrowsError(try DatabaseLocator.validateName("version"))
        XCTAssertThrowsError(try DatabaseLocator.validateName("info"))
    }

    // MARK: - databaseDirectory

    func testDatabaseDirectoryReturnsCorrectPath() {
        let dir = DatabaseLocator.databaseDirectory(for: "my-db")
        let expected = DatabaseLocator.baseDirectory.appendingPathComponent("my-db")
        XCTAssertEqual(dir.path, expected.path)
    }

    func testDatabaseDirectoryUnderBaseDirectory() {
        let dir = DatabaseLocator.databaseDirectory(for: "test-project")
        XCTAssertTrue(dir.path.hasPrefix(DatabaseLocator.baseDirectory.path))
    }

    // MARK: - writeConfig / readConfig roundtrip

    func testWriteConfigAndReadConfigRoundtrip() throws {
        let dbDir = tempDir.appendingPathComponent("test-db")
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)

        let sourceDir = "/Users/someone/projects/myapp"
        let createdAt = Date(timeIntervalSince1970: 1700000000)
        let config = DatabaseConfig(sourceDirectory: sourceDir, createdAt: createdAt)

        try DatabaseLocator.writeConfig(config, to: dbDir)

        let loaded = try DatabaseLocator.readConfig(from: dbDir)
        XCTAssertEqual(loaded.sourceDirectory, sourceDir)
        // ISO8601 loses sub-second precision, so compare with 1-second accuracy
        XCTAssertEqual(loaded.createdAt.timeIntervalSince1970, createdAt.timeIntervalSince1970, accuracy: 1.0)
    }

    func testWriteConfigCreatesConfigJsonFile() throws {
        let dbDir = tempDir.appendingPathComponent("config-test")
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)

        let config = DatabaseConfig(sourceDirectory: "/tmp/src", createdAt: Date())
        try DatabaseLocator.writeConfig(config, to: dbDir)

        let configPath = dbDir.appendingPathComponent("config.json").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: configPath))
    }

    func testReadConfigThrowsWhenFileIsMissing() {
        let dbDir = tempDir.appendingPathComponent("empty-dir")
        try! FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)

        XCTAssertThrowsError(try DatabaseLocator.readConfig(from: dbDir)) { error in
            guard let vecError = error as? VecError,
                  case .databaseCorrupted(let detail) = vecError else {
                XCTFail("Expected VecError.databaseCorrupted, got \(error)")
                return
            }
            XCTAssertTrue(detail.contains("missing or unreadable"))
        }
    }

    func testReadConfigThrowsOnMalformedJSON() {
        let dbDir = tempDir.appendingPathComponent("bad-config")
        try! FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)

        // Write invalid JSON
        let configPath = dbDir.appendingPathComponent("config.json")
        try! "{ not valid json }".write(to: configPath, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try DatabaseLocator.readConfig(from: dbDir)) { error in
            guard let vecError = error as? VecError,
                  case .databaseCorrupted(let detail) = vecError else {
                XCTFail("Expected VecError.databaseCorrupted, got \(error)")
                return
            }
            XCTAssertTrue(detail.contains("malformed"))
        }
    }

    func testReadConfigThrowsOnIncompleteConfig() {
        let dbDir = tempDir.appendingPathComponent("incomplete-config")
        try! FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)

        // Write valid JSON but missing required fields
        let configPath = dbDir.appendingPathComponent("config.json")
        try! "{}".write(to: configPath, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try DatabaseLocator.readConfig(from: dbDir)) { error in
            guard let vecError = error as? VecError,
                  case .databaseCorrupted(let detail) = vecError else {
                XCTFail("Expected VecError.databaseCorrupted, got \(error)")
                return
            }
            XCTAssertTrue(detail.contains("malformed"))
        }
    }

    // MARK: - allDatabases (using real ~/.vec/ with unique test name)

    func testAllDatabasesFindsWrittenConfig() throws {
        // Use a unique name to avoid colliding with real databases
        let uniqueName = "vectest-\(UUID().uuidString)"
        let dbDir = DatabaseLocator.databaseDirectory(for: uniqueName)

        // Ensure the base directory exists
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: dbDir)
        }

        let config = DatabaseConfig(sourceDirectory: "/tmp/test-source", createdAt: Date())
        try DatabaseLocator.writeConfig(config, to: dbDir)

        let databases = try DatabaseLocator.allDatabases()
        let found = databases.first(where: { $0.name == uniqueName })

        XCTAssertNotNil(found, "Should find the test database")
        XCTAssertEqual(found?.config.sourceDirectory, "/tmp/test-source")
    }

    func testAllDatabasesSkipsDirsWithoutConfig() throws {
        let uniqueName = "vectest-noconfig-\(UUID().uuidString)"
        let dbDir = DatabaseLocator.databaseDirectory(for: uniqueName)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: dbDir)
        }

        let databases = try DatabaseLocator.allDatabases()
        let found = databases.first(where: { $0.name == uniqueName })
        XCTAssertNil(found, "Should skip directory without config.json")
    }

    func testAllDatabasesDoesNotCrash() throws {
        // Verify the method returns without crashing regardless of whether
        // ~/.vec/ exists. This is a sanity check, not an exhaustive test.
        let databases = try DatabaseLocator.allDatabases()
        XCTAssertGreaterThanOrEqual(databases.count, 0)
    }

    // MARK: - resolveFromCurrentDirectory

    /// Helper: create a uniquely-named database in ~/.vec/ whose config points at `sourceDir`.
    /// Returns the database name so the caller can clean up.
    private func createTestDatabase(sourceDirectory: String) throws -> String {
        let name = "vectest-\(UUID().uuidString)"
        let dbDir = DatabaseLocator.databaseDirectory(for: name)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let config = DatabaseConfig(sourceDirectory: sourceDirectory, createdAt: Date())
        try DatabaseLocator.writeConfig(config, to: dbDir)
        return name
    }

    /// Helper: remove a test database from ~/.vec/.
    private func removeTestDatabase(_ name: String) {
        let dbDir = DatabaseLocator.databaseDirectory(for: name)
        try? FileManager.default.removeItem(at: dbDir)
    }

    func testResolveFromCurrentDirectorySingleMatch() throws {
        // Create a real temp directory to use as source
        let sourceDir = tempDir.appendingPathComponent("source-project")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)

        // Resolve symlinks so the path matches what standardizingPath produces
        let resolvedSource = sourceDir.resolvingSymlinksInPath()

        let dbName = try createTestDatabase(sourceDirectory: resolvedSource.path)
        defer { removeTestDatabase(dbName) }

        // Change cwd to the source directory
        let originalCwd = FileManager.default.currentDirectoryPath
        FileManager.default.changeCurrentDirectoryPath(resolvedSource.path)
        defer { FileManager.default.changeCurrentDirectoryPath(originalCwd) }

        let (dbDir, config, resultSourceDir) = try DatabaseLocator.resolveFromCurrentDirectory()

        XCTAssertEqual(dbDir.lastPathComponent, dbName)
        XCTAssertEqual(config.sourceDirectory, resolvedSource.path)
        XCTAssertEqual(resultSourceDir.path, resolvedSource.path)
    }

    func testResolveFromCurrentDirectoryNoMatchThrows() throws {
        // Use a directory that no database will point to
        let noMatchDir = tempDir.appendingPathComponent("no-match-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: noMatchDir, withIntermediateDirectories: true)

        let resolvedDir = noMatchDir.resolvingSymlinksInPath()

        let originalCwd = FileManager.default.currentDirectoryPath
        FileManager.default.changeCurrentDirectoryPath(resolvedDir.path)
        defer { FileManager.default.changeCurrentDirectoryPath(originalCwd) }

        XCTAssertThrowsError(try DatabaseLocator.resolveFromCurrentDirectory()) { error in
            guard let vecError = error as? VecError,
                  case .noDatabaseForDirectory = vecError else {
                XCTFail("Expected VecError.noDatabaseForDirectory, got \(error)")
                return
            }
        }
    }

    func testResolveFromCurrentDirectoryMultipleMatchesThrows() throws {
        // Create a source directory that two databases will point to
        let sourceDir = tempDir.appendingPathComponent("multi-match")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)

        let resolvedSource = sourceDir.resolvingSymlinksInPath()

        let dbName1 = try createTestDatabase(sourceDirectory: resolvedSource.path)
        let dbName2 = try createTestDatabase(sourceDirectory: resolvedSource.path)
        defer {
            removeTestDatabase(dbName1)
            removeTestDatabase(dbName2)
        }

        let originalCwd = FileManager.default.currentDirectoryPath
        FileManager.default.changeCurrentDirectoryPath(resolvedSource.path)
        defer { FileManager.default.changeCurrentDirectoryPath(originalCwd) }

        XCTAssertThrowsError(try DatabaseLocator.resolveFromCurrentDirectory()) { error in
            guard let vecError = error as? VecError,
                  case .multipleDatabasesForDirectory(_, let names) = vecError else {
                XCTFail("Expected VecError.multipleDatabasesForDirectory, got \(error)")
                return
            }
            XCTAssertTrue(names.contains(dbName1), "Should mention first database name")
            XCTAssertTrue(names.contains(dbName2), "Should mention second database name")
        }
    }
}
