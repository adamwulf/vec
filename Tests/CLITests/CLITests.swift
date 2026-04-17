import XCTest
import ArgumentParser
@testable import vec

final class CLITests: XCTestCase {

    // MARK: - Vec Subcommand Registration

    func testVecHasExpectedSubcommands() {
        let subcommands = Vec.configuration.subcommands
        let names = subcommands.map { $0.configuration.commandName ?? "" }

        XCTAssertTrue(names.contains("init"), "Missing 'init' subcommand")
        XCTAssertTrue(names.contains("deinit"), "Missing 'deinit' subcommand")
        XCTAssertTrue(names.contains("update-index"), "Missing 'update-index' subcommand")
        XCTAssertTrue(names.contains("search"), "Missing 'search' subcommand")
        XCTAssertTrue(names.contains("insert"), "Missing 'insert' subcommand")
        XCTAssertTrue(names.contains("remove"), "Missing 'remove' subcommand")
        XCTAssertTrue(names.contains("list"), "Missing 'list' subcommand")
        XCTAssertTrue(names.contains("info"), "Missing 'info' subcommand")
    }

    // MARK: - InitCommand

    func testInitCommandParsesDbName() throws {
        let cmd = try InitCommand.parseAsRoot(["my-project"]) as! InitCommand
        XCTAssertEqual(cmd.dbName, "my-project")
        XCTAssertFalse(cmd.force)
    }

    func testInitCommandParsesWithoutDbName() throws {
        let cmd = try InitCommand.parseAsRoot([]) as! InitCommand
        XCTAssertNil(cmd.dbName)
        XCTAssertFalse(cmd.force)
    }

    func testInitCommandParsesWithForceFlag() throws {
        let cmd = try InitCommand.parseAsRoot(["my-project", "--force"]) as! InitCommand
        XCTAssertEqual(cmd.dbName, "my-project")
        XCTAssertTrue(cmd.force)
    }

    func testInitCommandSanitizePreservesValidName() {
        XCTAssertEqual(InitCommand.sanitize("my-project"), "my-project")
        XCTAssertEqual(InitCommand.sanitize("my_project_2"), "my_project_2")
        XCTAssertEqual(InitCommand.sanitize("ABC123"), "ABC123")
    }

    func testInitCommandSanitizeReplacesDisallowedCharacters() {
        XCTAssertEqual(InitCommand.sanitize("my.project"), "my-project")
        XCTAssertEqual(InitCommand.sanitize("my project"), "my-project")
        XCTAssertEqual(InitCommand.sanitize("my/project"), "my-project")
        XCTAssertEqual(InitCommand.sanitize("foo!bar@baz"), "foo-bar-baz")
    }

    func testInitCommandSanitizeCollapsesAndTrimsDashes() {
        XCTAssertEqual(InitCommand.sanitize("...name..."), "name")
        XCTAssertEqual(InitCommand.sanitize("a  b   c"), "a-b-c")
        XCTAssertEqual(InitCommand.sanitize("-leading"), "leading")
        XCTAssertEqual(InitCommand.sanitize("trailing-"), "trailing")
    }

    func testInitCommandSanitizeEmptyResult() {
        XCTAssertEqual(InitCommand.sanitize("..."), "")
        XCTAssertEqual(InitCommand.sanitize(""), "")
    }

    // MARK: - DeinitCommand

    func testDeinitCommandParsesDbName() throws {
        let cmd = try DeinitCommand.parseAsRoot(["my-project"]) as! DeinitCommand
        XCTAssertEqual(cmd.dbName, "my-project")
        XCTAssertFalse(cmd.force)
    }

    func testDeinitCommandFailsWithoutDbName() {
        XCTAssertThrowsError(try DeinitCommand.parseAsRoot([]))
    }

    func testDeinitCommandParsesWithForceFlag() throws {
        let cmd = try DeinitCommand.parseAsRoot(["my-project", "--force"]) as! DeinitCommand
        XCTAssertEqual(cmd.dbName, "my-project")
        XCTAssertTrue(cmd.force)
    }

    // MARK: - SearchCommand

    func testSearchCommandParsesQueryOnly() throws {
        let cmd = try SearchCommand.parseAsRoot(["hello world"]) as! SearchCommand
        XCTAssertNil(cmd.db)
        XCTAssertEqual(cmd.query, "hello world")
        XCTAssertEqual(cmd.limit, 10)
        XCTAssertFalse(cmd.includePreview)
    }

    func testSearchCommandParsesDbFlagAndQuery() throws {
        let cmd = try SearchCommand.parseAsRoot(["-d", "my-db", "hello world"]) as! SearchCommand
        XCTAssertEqual(cmd.db, "my-db")
        XCTAssertEqual(cmd.query, "hello world")
        XCTAssertEqual(cmd.limit, 10)
        XCTAssertFalse(cmd.includePreview)
    }

    func testSearchCommandParsesLongDbFlag() throws {
        let cmd = try SearchCommand.parseAsRoot(["--db", "my-db", "hello world"]) as! SearchCommand
        XCTAssertEqual(cmd.db, "my-db")
        XCTAssertEqual(cmd.query, "hello world")
    }

    func testSearchCommandFailsWithoutQuery() {
        XCTAssertThrowsError(try SearchCommand.parseAsRoot([]))
    }

    func testSearchCommandParsesAllFlags() throws {
        let cmd = try SearchCommand.parseAsRoot([
            "-d", "my-db",
            "some query",
            "--limit", "5",
            "--include-preview"
        ]) as! SearchCommand
        XCTAssertEqual(cmd.db, "my-db")
        XCTAssertEqual(cmd.query, "some query")
        XCTAssertEqual(cmd.limit, 5)
        XCTAssertTrue(cmd.includePreview)
    }

    func testSearchCommandParsesShortLimitFlag() throws {
        let cmd = try SearchCommand.parseAsRoot(["-d", "my-db", "test query", "-l", "3"]) as! SearchCommand
        XCTAssertEqual(cmd.db, "my-db")
        XCTAssertEqual(cmd.query, "test query")
        XCTAssertEqual(cmd.limit, 3)
    }

    func testSearchCommandDefaultFormatIsText() throws {
        let cmd = try SearchCommand.parseAsRoot(["hello"]) as! SearchCommand
        XCTAssertEqual(cmd.format, .text)
    }

    func testSearchCommandParsesFormatJson() throws {
        let cmd = try SearchCommand.parseAsRoot(["hello", "--format", "json"]) as! SearchCommand
        XCTAssertEqual(cmd.format, .json)
    }

    func testSearchCommandParsesFormatText() throws {
        let cmd = try SearchCommand.parseAsRoot(["hello", "--format", "text"]) as! SearchCommand
        XCTAssertEqual(cmd.format, .text)
    }

    // MARK: - UpdateIndexCommand

    func testUpdateIndexCommandParsesWithNoArgs() throws {
        let cmd = try UpdateIndexCommand.parseAsRoot([]) as! UpdateIndexCommand
        XCTAssertNil(cmd.db)
        XCTAssertFalse(cmd.allowHidden)
    }

    func testUpdateIndexCommandParsesDbFlag() throws {
        let cmd = try UpdateIndexCommand.parseAsRoot(["-d", "my-db"]) as! UpdateIndexCommand
        XCTAssertEqual(cmd.db, "my-db")
        XCTAssertFalse(cmd.allowHidden)
    }

    func testUpdateIndexCommandParsesAllowHiddenFlag() throws {
        let cmd = try UpdateIndexCommand.parseAsRoot(["-d", "my-db", "--allow-hidden"]) as! UpdateIndexCommand
        XCTAssertEqual(cmd.db, "my-db")
        XCTAssertTrue(cmd.allowHidden)
    }

    // MARK: - InsertCommand

    func testInsertCommandParsesPathOnly() throws {
        let cmd = try InsertCommand.parseAsRoot(["src/main.swift"]) as! InsertCommand
        XCTAssertNil(cmd.db)
        XCTAssertEqual(cmd.path, "src/main.swift")
    }

    func testInsertCommandParsesDbFlagAndPath() throws {
        let cmd = try InsertCommand.parseAsRoot(["-d", "my-db", "src/main.swift"]) as! InsertCommand
        XCTAssertEqual(cmd.db, "my-db")
        XCTAssertEqual(cmd.path, "src/main.swift")
    }

    func testInsertCommandFailsWithoutPath() {
        XCTAssertThrowsError(try InsertCommand.parseAsRoot([]))
    }

    // MARK: - RemoveCommand

    func testRemoveCommandParsesPathOnly() throws {
        let cmd = try RemoveCommand.parseAsRoot(["docs/readme.md"]) as! RemoveCommand
        XCTAssertNil(cmd.db)
        XCTAssertEqual(cmd.path, "docs/readme.md")
    }

    func testRemoveCommandParsesDbFlagAndPath() throws {
        let cmd = try RemoveCommand.parseAsRoot(["-d", "my-db", "docs/readme.md"]) as! RemoveCommand
        XCTAssertEqual(cmd.db, "my-db")
        XCTAssertEqual(cmd.path, "docs/readme.md")
    }

    func testRemoveCommandFailsWithoutPath() {
        XCTAssertThrowsError(try RemoveCommand.parseAsRoot([]))
    }

    // MARK: - ListCommand

    func testListCommandParsesWithNoArguments() throws {
        _ = try ListCommand.parseAsRoot([]) as! ListCommand
    }

    // MARK: - InfoCommand

    func testInfoCommandParsesWithNoArgs() throws {
        let cmd = try InfoCommand.parseAsRoot([]) as! InfoCommand
        XCTAssertNil(cmd.db)
    }

    func testInfoCommandParsesDbFlag() throws {
        let cmd = try InfoCommand.parseAsRoot(["-d", "my-db"]) as! InfoCommand
        XCTAssertEqual(cmd.db, "my-db")
    }

    func testInfoCommandParsesLongDbFlag() throws {
        let cmd = try InfoCommand.parseAsRoot(["--db", "my-db"]) as! InfoCommand
        XCTAssertEqual(cmd.db, "my-db")
    }

    // MARK: - Default Subcommand

    func testDefaultSubcommandRoutesToSearch() throws {
        // "vec hello" (no explicit "search") should route to SearchCommand
        let cmd = try Vec.parseAsRoot(["hello"]) as! SearchCommand
        XCTAssertNil(cmd.db)
        XCTAssertEqual(cmd.query, "hello")
    }

    func testExplicitListSubcommandTakesPrecedenceOverDefaultSearch() throws {
        // "vec list" should invoke ListCommand, not search for "list"
        let cmd = try Vec.parseAsRoot(["list"])
        XCTAssertTrue(cmd is ListCommand)
    }
}
