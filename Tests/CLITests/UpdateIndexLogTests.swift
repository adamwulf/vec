import XCTest
import Foundation
@testable import vec
@testable import VecKit

/// End-to-end integration tests for E8 — `index.log` written by
/// `UpdateIndexCommand` after every run.
///
/// Each test creates a uniquely-named DB under the real `~/.vec/` (so
/// `DatabaseLocator.resolve` works) plus a temp source directory, runs
/// `update-index`, and asserts on the resulting `index.log` contents.
///
/// Tests use the `nl` embedder (`NLEmbedding.sentenceEmbedding(for:
/// .english)`) because it ships with the OS — no CoreML model
/// download or load latency. That keeps these tests fast enough to run
/// on every CI cycle.
final class UpdateIndexLogTests: XCTestCase {

    private var sourceDir: URL!
    private var testDBName: String!

    override func setUp() {
        super.setUp()
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateIndexLogTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        // Resolve symlinks so the source path round-trips through
        // FileScanner without surprises (matches what other tests do).
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        sourceDir = realpath(raw.path, &buf) != nil
            ? URL(fileURLWithPath: String(cString: buf), isDirectory: true)
            : raw

        testDBName = "vectest-updateindexlog-\(UUID().uuidString)"
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

    // MARK: - Helpers

    /// Initialize an empty DB folder pointed at `sourceDir`. Mirrors
    /// what `vec init` does: create the dir, initialize the SQLite
    /// database with `dimension: 0` (the dimension is set on first
    /// `update-index`), and persist a profile-less config.
    private func initEmptyDB() async throws -> URL {
        let dbDir = DatabaseLocator.databaseDirectory(for: testDBName)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)

        let database = VectorDatabase(
            databaseDirectory: dbDir,
            sourceDirectory: sourceDir,
            dimension: 0
        )
        try await database.initialize()

        let config = DatabaseConfig(
            sourceDirectory: sourceDir.path,
            createdAt: Date(),
            profile: nil
        )
        try DatabaseLocator.writeConfig(config, to: dbDir)
        return dbDir
    }

    @discardableResult
    private func writeFile(_ relativePath: String, content: String) throws -> URL {
        let url = sourceDir.appendingPathComponent(relativePath)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Read every record in the on-disk index.log and return decoded entries.
    private func readLog(_ dbDir: URL) throws -> [IndexLogEntry] {
        let logURL = dbDir.appendingPathComponent(IndexLog.filename)
        let contents = try String(contentsOf: logURL, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        let decoder = IndexLog.makeDecoder()
        return try lines.map { try decoder.decode(IndexLogEntry.self, from: Data($0.utf8)) }
    }

    /// Build and run an UpdateIndexCommand against the test DB.
    private func runUpdateIndex(extraArgs: [String] = []) async throws {
        var args = ["--db", testDBName!, "--embedder", "nl"]
        args.append(contentsOf: extraArgs)
        var cmd = try UpdateIndexCommand.parseAsRoot(args) as! UpdateIndexCommand
        try await cmd.run()
    }

    // MARK: - Logging contract

    /// After a normal run with one English text file, the log gains a
    /// single entry whose `embedder` is the alias (`"nl"`) and whose
    /// `profile` is the full identity (`"nl@2000/200"` — the alias
    /// default for `nl`). Pin both so a buggy implementation that
    /// stores the identity in both fields fails loudly.
    func testEmbedderIsAliasAndProfileIsIdentity() async throws {
        let dbDir = try await initEmptyDB()
        try writeFile(
            "hello.md",
            content: "Hello world. This is an English sentence to embed and index.\n"
        )

        try await runUpdateIndex()

        let entries = try readLog(dbDir)
        XCTAssertEqual(entries.count, 1, "one run = one log entry")
        let entry = entries[0]
        XCTAssertEqual(entry.embedder, "nl",
                       "embedder must be the alias only, not the full identity")
        XCTAssertEqual(entry.profile, "nl@2000/200",
                       "profile must be the full canonical identity")
        XCTAssertEqual(entry.schemaVersion, 1)
        XCTAssertGreaterThanOrEqual(entry.added, 1, "the English file must land in the DB")
    }

    /// After a run with at least one unreadable file, the log entry's
    /// `skippedUnreadable` array contains the file's relative-to-source
    /// path — the exact same string `IndexResult.skippedUnreadable`
    /// emits. An empty `.md` produces zero chunks during extract, so
    /// the pipeline classifies it as `.skippedUnreadable`.
    func testLogRecordsRelativeSkippedPath() async throws {
        let dbDir = try await initEmptyDB()
        // One real file so the run doesn't trip the silent-failure guard.
        try writeFile("real.md",
                      content: "An English sentence to keep the run from being entirely skips.\n")
        // Empty file → extracts to zero chunks → `.skippedUnreadable`.
        try writeFile("empty.md", content: "")

        try await runUpdateIndex()

        let entries = try readLog(dbDir)
        XCTAssertEqual(entries.count, 1)
        let entry = entries[0]
        XCTAssertTrue(entry.skippedUnreadable.contains("empty.md"),
                      "empty.md must appear in skippedUnreadable; got: \(entry.skippedUnreadable)")
        XCTAssertFalse(entry.skippedUnreadable.contains { $0.hasPrefix("/") },
                       "skipped paths must be relative to source dir, not absolute")
    }

    /// After a no-op run (all files unchanged from a prior run), the
    /// log still gets a fresh entry with `added=0, updated=0`. This is
    /// the "the log is per-invocation, not per-change" invariant.
    func testNoOpRunStillWritesLogEntry() async throws {
        let dbDir = try await initEmptyDB()
        let docURL = try writeFile(
            "doc.md",
            content: "Some English content for the embedder.\n"
        )

        // Pin the file's mtime to a fixed point in the past so the
        // "modificationDate > stored" check in UpdateIndexCommand
        // deterministically reports unchanged. Without this pin,
        // filesystem mtime precision (APFS nanoseconds vs SQLite
        // Double round-trip) can land the comparison on the
        // "updated" side of the threshold and the test reports
        // updated=1 spuriously.
        let pinned = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: pinned],
            ofItemAtPath: docURL.path
        )

        // First run: indexes the file.
        try await runUpdateIndex()
        let firstEntries = try readLog(dbDir)
        XCTAssertEqual(firstEntries.count, 1)
        XCTAssertGreaterThanOrEqual(firstEntries[0].added, 1)

        // Re-pin in case any indexing-side touch bumped the mtime.
        // The pipeline doesn't write to source files, but this is
        // belt-and-suspenders against future regressions.
        try FileManager.default.setAttributes(
            [.modificationDate: pinned],
            ofItemAtPath: docURL.path
        )

        // Second run: same files, nothing modified → no-op.
        try await runUpdateIndex()
        let secondEntries = try readLog(dbDir)
        XCTAssertEqual(secondEntries.count, 2,
                       "no-op run must still append a log entry")
        let noOp = secondEntries[1]
        XCTAssertEqual(noOp.added, 0, "no-op run: nothing added")
        XCTAssertEqual(noOp.updated, 0, "no-op run: nothing updated")
    }

    /// Silent-failure shape on disk: when every file's chunks fail to
    /// embed, the log entry has `added=0, updated=0` and lists each
    /// failed file in `skippedEmbedFailures`.
    ///
    /// **Why this is a unit test and not an integration test.** The
    /// silent-failure code path in `UpdateIndexCommand.run()` only
    /// fires when the pipeline returns `.skippedEmbedFailure` for
    /// every attempted file. No stock embedder produces that outcome
    /// deterministically: `NLEmbedder` happily embeds non-English /
    /// CJK / emoji / control-character input (verified empirically on
    /// Darwin 25 — `NLEmbedding.sentenceEmbedding(for:.english)`
    /// returns vectors for Russian, Japanese, Chinese, Arabic, and
    /// pure-symbol strings); the heavier CoreML embedders are
    /// network-dependent and far too slow for CI. The pipeline-level
    /// silent-failure contract is already pinned by
    /// `VecKitTests.SilentFailureGuardTests` using a `SelectiveMockEmbedder`.
    /// The throw-after-append *ordering* (log written before the
    /// throw propagates) is enforced by the physical layout of
    /// `UpdateIndexCommand.run()` — `IndexLog.append` precedes the
    /// `throw VecError.indexingProducedNoVectors` block — and is
    /// observed by reading the source, not by another mocked test.
    /// What this test pins is the on-disk *shape*: hand-build the
    /// `IndexLogEntry` exactly as the silent-failure path does, write
    /// it through the real `IndexLog.append`, decode it back, and
    /// assert the contract documented in `IndexLog.swift`. A buggy
    /// `IndexLogEntry` codable surface (renamed field, dropped array,
    /// wrong key) would fail this test the same way it would fail a
    /// hypothetical integration test.
    func testSilentFailureLogEntryShape() async throws {
        let dbDir = try await initEmptyDB()

        let entry = IndexLogEntry(
            timestamp: Date(),
            embedder: "nl",
            profile: "nl@2000/200",
            wallSeconds: 0.123,
            filesScanned: 1,
            added: 0,
            updated: 0,
            removed: 0,
            unchanged: 0,
            skippedUnreadable: [],
            skippedEmbedFailures: ["ru.md"]
        )
        try IndexLog.append(entry, to: dbDir)

        let decoded = try readLog(dbDir)
        XCTAssertEqual(decoded.count, 1)
        let stored = decoded[0]
        XCTAssertEqual(stored.added, 0, "silent-failure: added=0")
        XCTAssertEqual(stored.updated, 0, "silent-failure: updated=0")
        XCTAssertEqual(stored.skippedEmbedFailures, ["ru.md"])
        XCTAssertEqual(stored.embedder, "nl")
        XCTAssertEqual(stored.profile, "nl@2000/200")
    }

    /// Best-effort write failure: poison the log location by creating
    /// `index.log` as a *directory* (so the `tmp+rename` swap fails on
    /// the rename step). The run itself succeeds; the command still
    /// exits cleanly. The plan documents this exact path: "best-effort,
    /// stderr warning, no exit-status change."
    func testBestEffortFailureDoesNotChangeExitStatus() async throws {
        let dbDir = try await initEmptyDB()
        try writeFile("doc.md",
                      content: "Some English content for the embedder.\n")

        // Pre-create a *directory* at the index.log path. A rename onto
        // a directory fails on macOS (`replaceItemAt` cannot replace a
        // dir with a file). The wrapping `do/catch` in
        // `UpdateIndexCommand` must swallow that error and emit the
        // documented stderr warning instead of throwing.
        let logURL = dbDir.appendingPathComponent(IndexLog.filename)
        try FileManager.default.createDirectory(at: logURL, withIntermediateDirectories: true)

        // Should NOT throw — log failure is best-effort.
        try await runUpdateIndex()

        // The directory should still be there (we made no attempt to
        // delete it; the failure is observable only via stderr).
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: logURL.path, isDirectory: &isDir)
        XCTAssertTrue(exists)
        XCTAssertTrue(isDir.boolValue,
                      "index.log location must remain a directory — log write failed cleanly")
    }
}
