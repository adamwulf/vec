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
    }

    // MARK: - InitCommand

    func testInitCommandParsesWithNoArguments() throws {
        let cmd = try InitCommand.parseAsRoot([]) as! InitCommand
        XCTAssertFalse(cmd.force)
    }

    func testInitCommandParsesWithForceFlag() throws {
        let cmd = try InitCommand.parseAsRoot(["--force"]) as! InitCommand
        XCTAssertTrue(cmd.force)
    }

    func testInitCommandParsesAllowHiddenFlag() throws {
        let cmd = try InitCommand.parseAsRoot(["--allow-hidden"]) as! InitCommand
        XCTAssertTrue(cmd.allowHidden)
    }

    func testInitCommandAllowHiddenDefaultsFalse() throws {
        let cmd = try InitCommand.parseAsRoot([]) as! InitCommand
        XCTAssertFalse(cmd.allowHidden)
    }

    // MARK: - SearchCommand

    func testSearchCommandFailsWithoutQuery() {
        XCTAssertThrowsError(try SearchCommand.parseAsRoot([]))
    }

    func testSearchCommandParsesQueryWithDefaults() throws {
        let cmd = try SearchCommand.parseAsRoot(["hello world"]) as! SearchCommand
        XCTAssertEqual(cmd.query, "hello world")
        XCTAssertEqual(cmd.limit, 10)
        XCTAssertFalse(cmd.includePreview)
    }

    func testSearchCommandParsesAllFlags() throws {
        let cmd = try SearchCommand.parseAsRoot([
            "some query",
            "--limit", "5",
            "--include-preview"
        ]) as! SearchCommand
        XCTAssertEqual(cmd.query, "some query")
        XCTAssertEqual(cmd.limit, 5)
        XCTAssertTrue(cmd.includePreview)
    }

    func testSearchCommandParsesShortLimitFlag() throws {
        let cmd = try SearchCommand.parseAsRoot(["test query", "-l", "3"]) as! SearchCommand
        XCTAssertEqual(cmd.query, "test query")
        XCTAssertEqual(cmd.limit, 3)
    }

    // MARK: - UpdateIndexCommand

    func testUpdateIndexCommandParsesWithNoArguments() throws {
        let cmd = try UpdateIndexCommand.parseAsRoot([]) as! UpdateIndexCommand
        XCTAssertFalse(cmd.allowHidden)
    }

    func testUpdateIndexCommandParsesAllowHiddenFlag() throws {
        let cmd = try UpdateIndexCommand.parseAsRoot(["--allow-hidden"]) as! UpdateIndexCommand
        XCTAssertTrue(cmd.allowHidden)
    }

    // MARK: - InsertCommand

    func testInsertCommandFailsWithoutPath() {
        XCTAssertThrowsError(try InsertCommand.parseAsRoot([]))
    }

    func testInsertCommandParsesPath() throws {
        let cmd = try InsertCommand.parseAsRoot(["src/main.swift"]) as! InsertCommand
        XCTAssertEqual(cmd.path, "src/main.swift")
    }

    // MARK: - RemoveCommand

    func testRemoveCommandFailsWithoutPath() {
        XCTAssertThrowsError(try RemoveCommand.parseAsRoot([]))
    }

    func testRemoveCommandParsesPath() throws {
        let cmd = try RemoveCommand.parseAsRoot(["docs/readme.md"]) as! RemoveCommand
        XCTAssertEqual(cmd.path, "docs/readme.md")
    }
}
