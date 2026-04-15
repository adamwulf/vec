import XCTest
import ArgumentParser
@testable import vec

final class CLITests: XCTestCase {

    // MARK: - Vec Subcommand Registration

    func testVecHasExpectedSubcommands() {
        let subcommands = Vec.configuration.subcommands
        let names = subcommands.map { $0.configuration.commandName ?? "" }

        XCTAssertTrue(names.contains("init"), "Missing 'init' subcommand")
        XCTAssertTrue(names.contains("update-index"), "Missing 'update-index' subcommand")
        XCTAssertTrue(names.contains("search"), "Missing 'search' subcommand")
        XCTAssertTrue(names.contains("insert"), "Missing 'insert' subcommand")
        XCTAssertTrue(names.contains("remove"), "Missing 'remove' subcommand")
        XCTAssertTrue(names.contains("list"), "Missing 'list' subcommand")
    }

    // MARK: - InitCommand

    func testInitCommandParsesDbName() throws {
        let cmd = try InitCommand.parseAsRoot(["my-project"]) as! InitCommand
        XCTAssertEqual(cmd.dbName, "my-project")
        XCTAssertFalse(cmd.force)
    }

    func testInitCommandFailsWithoutDbName() {
        XCTAssertThrowsError(try InitCommand.parseAsRoot([]))
    }

    func testInitCommandParsesWithForceFlag() throws {
        let cmd = try InitCommand.parseAsRoot(["my-project", "--force"]) as! InitCommand
        XCTAssertEqual(cmd.dbName, "my-project")
        XCTAssertTrue(cmd.force)
    }

    func testInitCommandParsesAllowHiddenFlag() throws {
        let cmd = try InitCommand.parseAsRoot(["my-project", "--allow-hidden"]) as! InitCommand
        XCTAssertEqual(cmd.dbName, "my-project")
        XCTAssertTrue(cmd.allowHidden)
    }

    func testInitCommandAllowHiddenDefaultsFalse() throws {
        let cmd = try InitCommand.parseAsRoot(["my-project"]) as! InitCommand
        XCTAssertFalse(cmd.allowHidden)
    }

    // MARK: - SearchCommand

    func testSearchCommandFailsWithoutArguments() {
        XCTAssertThrowsError(try SearchCommand.parseAsRoot([]))
    }

    func testSearchCommandFailsWithOnlyDbName() {
        XCTAssertThrowsError(try SearchCommand.parseAsRoot(["my-db"]))
    }

    func testSearchCommandParsesDbNameAndQuery() throws {
        let cmd = try SearchCommand.parseAsRoot(["my-db", "hello world"]) as! SearchCommand
        XCTAssertEqual(cmd.dbName, "my-db")
        XCTAssertEqual(cmd.query, "hello world")
        XCTAssertEqual(cmd.limit, 10)
        XCTAssertFalse(cmd.includePreview)
    }

    func testSearchCommandParsesAllFlags() throws {
        let cmd = try SearchCommand.parseAsRoot([
            "my-db",
            "some query",
            "--limit", "5",
            "--include-preview"
        ]) as! SearchCommand
        XCTAssertEqual(cmd.dbName, "my-db")
        XCTAssertEqual(cmd.query, "some query")
        XCTAssertEqual(cmd.limit, 5)
        XCTAssertTrue(cmd.includePreview)
    }

    func testSearchCommandParsesShortLimitFlag() throws {
        let cmd = try SearchCommand.parseAsRoot(["my-db", "test query", "-l", "3"]) as! SearchCommand
        XCTAssertEqual(cmd.dbName, "my-db")
        XCTAssertEqual(cmd.query, "test query")
        XCTAssertEqual(cmd.limit, 3)
    }

    func testSearchCommandDefaultFormatIsText() throws {
        let cmd = try SearchCommand.parseAsRoot(["my-db", "hello"]) as! SearchCommand
        XCTAssertEqual(cmd.format, .text)
    }

    func testSearchCommandParsesFormatJson() throws {
        let cmd = try SearchCommand.parseAsRoot(["my-db", "hello", "--format", "json"]) as! SearchCommand
        XCTAssertEqual(cmd.format, .json)
    }

    func testSearchCommandParsesFormatText() throws {
        let cmd = try SearchCommand.parseAsRoot(["my-db", "hello", "--format", "text"]) as! SearchCommand
        XCTAssertEqual(cmd.format, .text)
    }

    // MARK: - UpdateIndexCommand

    func testUpdateIndexCommandParsesDbName() throws {
        let cmd = try UpdateIndexCommand.parseAsRoot(["my-db"]) as! UpdateIndexCommand
        XCTAssertEqual(cmd.dbName, "my-db")
        XCTAssertFalse(cmd.allowHidden)
    }

    func testUpdateIndexCommandFailsWithoutDbName() {
        XCTAssertThrowsError(try UpdateIndexCommand.parseAsRoot([]))
    }

    func testUpdateIndexCommandParsesAllowHiddenFlag() throws {
        let cmd = try UpdateIndexCommand.parseAsRoot(["my-db", "--allow-hidden"]) as! UpdateIndexCommand
        XCTAssertEqual(cmd.dbName, "my-db")
        XCTAssertTrue(cmd.allowHidden)
    }

    // MARK: - InsertCommand

    func testInsertCommandFailsWithoutArguments() {
        XCTAssertThrowsError(try InsertCommand.parseAsRoot([]))
    }

    func testInsertCommandFailsWithOnlyDbName() {
        XCTAssertThrowsError(try InsertCommand.parseAsRoot(["my-db"]))
    }

    func testInsertCommandParsesDbNameAndPath() throws {
        let cmd = try InsertCommand.parseAsRoot(["my-db", "src/main.swift"]) as! InsertCommand
        XCTAssertEqual(cmd.dbName, "my-db")
        XCTAssertEqual(cmd.path, "src/main.swift")
    }

    // MARK: - RemoveCommand

    func testRemoveCommandFailsWithoutArguments() {
        XCTAssertThrowsError(try RemoveCommand.parseAsRoot([]))
    }

    func testRemoveCommandFailsWithOnlyDbName() {
        XCTAssertThrowsError(try RemoveCommand.parseAsRoot(["my-db"]))
    }

    func testRemoveCommandParsesDbNameAndPath() throws {
        let cmd = try RemoveCommand.parseAsRoot(["my-db", "docs/readme.md"]) as! RemoveCommand
        XCTAssertEqual(cmd.dbName, "my-db")
        XCTAssertEqual(cmd.path, "docs/readme.md")
    }

    // MARK: - ListCommand

    func testListCommandParsesWithNoArguments() throws {
        _ = try ListCommand.parseAsRoot([]) as! ListCommand
    }
}
