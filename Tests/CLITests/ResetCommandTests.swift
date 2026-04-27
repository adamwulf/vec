import XCTest
import Foundation
@testable import vec
@testable import VecKit

/// Tests the E8 invariant that `vec reset` deletes the per-DB
/// `index.log` along with the rest of the database directory.
///
/// `ResetCommand` wipes the DB by calling `FileManager.removeItem(at:)`
/// on `~/.vec/<name>/`. The plan ("E8 — index.log") explicitly notes
/// that this is the entire reset-side requirement: no code change
/// needed in `ResetCommand`, only a regression-guard test. This file
/// is that guard.
final class ResetCommandTests: XCTestCase {

    private var sourceDir: URL!
    private var testDBName: String!

    override func setUp() {
        super.setUp()
        // Source directory must exist on disk because `ResetCommand`
        // re-creates the empty DB pointed at it after the wipe.
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResetCommandTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        sourceDir = raw

        // Unique name under the real `~/.vec/` so we don't collide
        // with the user's databases. tearDown wipes it.
        testDBName = "vectest-reset-\(UUID().uuidString)"
    }

    override func tearDown() {
        if let testDBName {
            let dbDir = DatabaseLocator.databaseDirectory(for: testDBName)
            try? FileManager.default.removeItem(at: dbDir)
        }
        if let sourceDir {
            try? FileManager.default.removeItem(at: sourceDir)
        }
        super.tearDown()
    }

    /// Construct a DB folder with a config + a synthetic `index.log`
    /// file, run `vec reset --force --db <name>`, then assert the log
    /// is gone (and so is everything else that was inside the DB
    /// folder besides what reset re-creates).
    func testResetDeletesIndexLog() async throws {
        // Create a minimal DB on disk: the dir, a config.json pointing
        // at the source dir, and an index.log seeded with a record.
        let dbDir = DatabaseLocator.databaseDirectory(for: testDBName)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)

        let config = DatabaseConfig(
            sourceDirectory: sourceDir.path,
            createdAt: Date(),
            profile: nil
        )
        try DatabaseLocator.writeConfig(config, to: dbDir)

        // Seed an index.log so we have something to assert was wiped.
        let logEntry = IndexLogEntry(
            timestamp: Date(),
            embedder: "e5-base",
            profile: "e5-base@1200/0",
            wallSeconds: 1.0,
            filesScanned: 1,
            added: 1,
            updated: 0,
            removed: 0,
            unchanged: 0,
            skippedUnreadable: [],
            skippedEmbedFailures: []
        )
        try IndexLog.append(logEntry, to: dbDir)

        let logURL = dbDir.appendingPathComponent(IndexLog.filename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: logURL.path),
                      "precondition: index.log was seeded before reset")

        // Run reset. `--force` bypasses the interactive name-confirm
        // prompt. `parseAsRoot` builds the command from CLI args
        // exactly the way the real binary's entry point does.
        var cmd = try ResetCommand.parseAsRoot(["--db", testDBName, "--force"]) as! ResetCommand
        try await cmd.run()

        // Reset re-creates an empty DB at the same path and re-writes
        // a fresh config.json (with `profile: nil`). The index.log,
        // however, is *not* re-created — `removeItem(at: dbDir)` wiped
        // it and reset has no logic to restore it.
        XCTAssertFalse(FileManager.default.fileExists(atPath: logURL.path),
                       "reset must delete index.log along with the rest of the DB folder")

        // Sanity: the DB folder itself was re-created (so future
        // `update-index` runs work) and config.json is back. This
        // protects against a regression where reset stops re-creating
        // the dir and the test "passes" via a deleted parent.
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbDir.path),
                      "reset must re-create the empty DB folder")
        let configURL = dbDir.appendingPathComponent("config.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: configURL.path),
                      "reset must re-create config.json")
    }
}
