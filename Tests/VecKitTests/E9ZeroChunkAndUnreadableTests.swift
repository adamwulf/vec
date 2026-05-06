import XCTest
import Darwin
@testable import VecKit

/// Integration tests for E9 — `IndexingPipeline`'s zero-chunk arm
/// distinguishes "extract succeeded but found no text" (mark indexed
/// with linePageCount=0 so the file stops re-extracting) from
/// "extract threw" (don't mark, so the next run retries the file).
///
/// Uses the `nl` embedder (`NLEmbedding.sentenceEmbedding(for:
/// .english)`) — ships with the OS, no model download or load
/// latency, fast enough for every CI cycle.
final class E9ZeroChunkAndUnreadableTests: XCTestCase {

    private var tempDir: URL!
    private var sourceDir: URL!
    private var dbDir: URL!

    override func setUp() {
        super.setUp()
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("VecE9Tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        tempDir = realpath(raw.path, &buf) != nil
            ? URL(fileURLWithPath: String(cString: buf), isDirectory: true)
            : raw
        sourceDir = tempDir.appendingPathComponent("source")
        try! FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        dbDir = tempDir.appendingPathComponent("db")
    }

    override func tearDown() {
        if let tempDir = tempDir {
            // Restore perms before delete so chmod-000 files don't
            // jam tearDown.
            if let enumerator = FileManager.default.enumerator(at: tempDir,
                includingPropertiesForKeys: nil) {
                for case let url as URL in enumerator {
                    try? FileManager.default.setAttributes(
                        [.posixPermissions: 0o644],
                        ofItemAtPath: url.path
                    )
                }
            }
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeProfile() throws -> IndexingProfile {
        return try IndexingProfileFactory.resolve(identity: "nl@2000/200")
    }

    private func makeDB(profile: IndexingProfile) async throws -> VectorDatabase {
        let db = VectorDatabase(
            databaseDirectory: dbDir,
            sourceDirectory: sourceDir,
            dimension: profile.embedder.dimension
        )
        try await db.initialize()
        return db
    }

    private func writeFile(_ relativePath: String, content: String) -> URL {
        let url = sourceDir.appendingPathComponent(relativePath)
        try! FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try! content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func runPipeline(
        profile: IndexingProfile,
        db: VectorDatabase
    ) async throws -> (results: [IndexResult], stats: IndexingStats) {
        let scanner = FileScanner(directory: sourceDir)
        let files = try scanner.scan()
        let workItems = files.map { (file: $0, label: "Added") }
        let pipeline = IndexingPipeline(profile: profile)
        let extractor = TextExtractor(splitter: profile.splitter)
        return try await pipeline.run(
            workItems: workItems,
            extractor: extractor,
            database: db
        )
    }

    // MARK: - Tests

    /// Empty file: extract succeeds with zero chunks, file gets a
    /// completion record with linePageCount=0, and the second
    /// `update-index`-style scan categorizes it as `unchanged`.
    func testEmptyFile_marksIndexed_secondRunIsNoOp() async throws {
        writeFile("empty.txt", content: "")
        let profile = try makeProfile()
        let db = try await makeDB(profile: profile)

        let (results, _) = try await runPipeline(profile: profile, db: db)

        // Result: file recorded as skipped.
        XCTAssertEqual(results.count, 1)
        if case .skippedUnreadable(let path) = results[0] {
            XCTAssertEqual(path, "empty.txt")
        } else {
            XCTFail("expected .skippedUnreadable, got \(results[0])")
        }

        // DB invariant: indexed_files contains the row with linePageCount=0.
        let indexed = try await db.allIndexedFiles()
        XCTAssertNotNil(indexed["empty.txt"], "empty file must be marked indexed")
        let metadata = try await db.indexedFileMetadata(paths: ["empty.txt"])
        XCTAssertEqual(metadata["empty.txt"]?.linePageCount, 0,
                       "empty file should record linePageCount=0")

        // Categorize a fresh scan against the existing DB. With the
        // completion record present, the file lands in `unchanged`.
        let scanner = FileScanner(directory: sourceDir)
        let scanned = try scanner.scan()
        let categorization = categorizeForUpdate(scanned: scanned, indexed: indexed)
        XCTAssertEqual(categorization.workItems.count, 0,
                       "second scan must not re-extract the empty file")
        XCTAssertEqual(categorization.unchanged, 1)
    }

    /// Whitespace-only file: same shape as an empty file — extract
    /// succeeds, produces zero chunks (after trimming), gets marked
    /// indexed.
    func testWhitespaceOnlyFile_marksIndexed() async throws {
        writeFile("blank.txt", content: "   \n\n   \t\n")
        let profile = try makeProfile()
        let db = try await makeDB(profile: profile)

        _ = try await runPipeline(profile: profile, db: db)

        let indexed = try await db.allIndexedFiles()
        XCTAssertNotNil(indexed["blank.txt"],
                        "whitespace-only file must be marked indexed")
    }

    /// Permission-denied file: extract throws, the file does NOT get
    /// a completion record, and a second pass still treats it as
    /// "needs work" (so a transient permission glitch retries
    /// instead of being suppressed).
    func testUnreadableFile_isNotMarkedIndexed_secondRunRetries() async throws {
        // Skip on CI environments running as root, where chmod 000
        // doesn't actually deny reads.
        if getuid() == 0 {
            throw XCTSkip("chmod 000 is not enforced for root")
        }

        let url = writeFile("locked.txt", content: "some text")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: url.path
        )
        defer {
            // Best-effort restore so tearDown can clean up; the
            // overall sweep in tearDown also covers this.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: url.path
            )
        }

        let profile = try makeProfile()
        let db = try await makeDB(profile: profile)
        let (results, _) = try await runPipeline(profile: profile, db: db)

        XCTAssertEqual(results.count, 1)
        if case .skippedUnreadable(let path) = results[0] {
            XCTAssertEqual(path, "locked.txt")
        } else {
            XCTFail("expected .skippedUnreadable, got \(results[0])")
        }

        // Critical: locked file must NOT be in indexed_files. The
        // failure was likely transient; a future run should retry.
        let indexed = try await db.allIndexedFiles()
        XCTAssertNil(indexed["locked.txt"],
                     "unreadable file must not be marked indexed")

        // Verify the categorizer treats the missing-row file as
        // "needs work" on the next pass.
        let scanner = FileScanner(directory: sourceDir)
        let scanned = try scanner.scan()
        let categorization = categorizeForUpdate(scanned: scanned, indexed: indexed)
        XCTAssertEqual(categorization.workItems.count, 1,
                       "unreadable file must be retried on next run")
        XCTAssertEqual(categorization.workItems.first?.label, "Added")
    }

    /// File-count semantics: zero-chunk files now appear in the
    /// `allIndexedFiles` count surfaced by `vec info` / `vec list`.
    /// This is more honest — they were processed; they just produced
    /// no embeddings — but the user-visible number changes from
    /// "files with chunks" to "files processed".
    func testFileCount_includesZeroChunkFiles() async throws {
        writeFile("a.md", content: "Some indexable content here.")
        writeFile("empty.txt", content: "")
        writeFile("blank.txt", content: "  \n")
        let profile = try makeProfile()
        let db = try await makeDB(profile: profile)
        _ = try await runPipeline(profile: profile, db: db)

        let indexed = try await db.allIndexedFiles()
        XCTAssertEqual(indexed.count, 3,
                       "indexed_files must include all three files including the two zero-chunk ones")
    }
}
