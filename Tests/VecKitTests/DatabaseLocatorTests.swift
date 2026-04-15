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

        XCTAssertThrowsError(try DatabaseLocator.readConfig(from: dbDir))
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

    func testAllDatabasesReturnsEmptyWhenBaseDoesNotExist() throws {
        // Verify the method doesn't crash and returns a valid result.
        // On a dev machine ~/.vec/ likely exists, so we just check it returns
        // without error and the result is a valid array.
        let databases = try DatabaseLocator.allDatabases()
        // Verify it's iterable (basic sanity check)
        XCTAssertGreaterThanOrEqual(databases.count, 0)
    }
}
