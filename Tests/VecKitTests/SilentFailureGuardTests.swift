import XCTest
@testable import VecKit

/// Tests the E5.1 silent-failure observability guard.
///
/// The guard in `UpdateIndexCommand.run()` exits non-zero when the
/// indexing pipeline attempts ≥1 file and every attempt falls into
/// `.skippedEmbedFailure`. This covers the case that hid nomic's
/// CoreML/ANE load failure for a release cycle — before the guard,
/// the CLI printed "Update complete: 674 added, 0 updated" with exit 0
/// despite zero vectors landing in the DB.
///
/// The CLI-level tally+throw is unit-tested via:
///
///  1. `VecError.indexingProducedNoVectors` description sanity.
///  2. The pipeline contract this guard relies on: when every embed
///     call returns `[]`, every non-empty input file produces
///     `.skippedEmbedFailure` with `added + updated == 0`.
///  3. Negative cases: mixed outcomes and unreadable-only runs must
///     NOT trip the guard condition — the CLI's false-positive paths.
final class SilentFailureGuardTests: XCTestCase {

    private var tempDir: URL!
    private var sourceDir: URL!
    private var dbDir: URL!

    override func setUp() {
        super.setUp()
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("VecSilentFailure-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        tempDir = realpath(raw.path, &buf) != nil
            ? URL(fileURLWithPath: String(cString: buf), isDirectory: true)
            : raw
        sourceDir = tempDir.appendingPathComponent("src")
        try! FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        dbDir = tempDir.appendingPathComponent("db")
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        super.tearDown()
    }

    // MARK: - VecError surface

    /// Uses distinct counts so the assertion can't accidentally pass when
    /// the description drops one of the fields. The 10/7 shape also
    /// mirrors the realistic "some attempted, some failed" case.
    func testIndexingProducedNoVectorsErrorDescriptionCarriesBothCounts() {
        let err = VecError.indexingProducedNoVectors(filesAttempted: 10, filesFailed: 7)
        let desc = err.errorDescription ?? ""
        XCTAssertTrue(desc.contains("10"),
                      "error description should surface filesAttempted")
        XCTAssertTrue(desc.contains("7"),
                      "error description should surface filesFailed")
        XCTAssertFalse(desc.isEmpty,
                       "error description must not be empty")
    }

    // MARK: - Positive pipeline contract (guard SHOULD trip)

    /// When the embedder fails every batch, the pipeline must report
    /// `.skippedEmbedFailure` for every file the extract stage produced
    /// chunks for. The CLI tally relies on this: its silent-failure
    /// guard trips when `added + updated == 0 && skippedEmbedFailures > 0`.
    func testPipelineReportsSkippedEmbedFailureWhenEveryBatchReturnsEmpty() async throws {
        for i in 0..<3 {
            try writeFile("file-\(i).md",
                          content: "Content for file \(i). Some words to produce at least one chunk.\n")
        }

        let files = try FileScanner(directory: sourceDir).scan()
        XCTAssertEqual(files.count, 3, "fixture should expose three files")

        let profile = makeMockProfile { _ in EmbedOutcome.fail }
        let (added, updated, embedFailures, unreadable) = try await runPipeline(
            profile: profile,
            files: files
        )

        XCTAssertEqual(added, 0, "no successful adds when every embed returns []")
        XCTAssertEqual(updated, 0, "no successful updates when every embed returns []")
        XCTAssertEqual(embedFailures, 3, "every file should report .skippedEmbedFailure")
        XCTAssertEqual(unreadable, 0, "fixtures are readable")

        // CLI guard condition re-checked here so a regression in the
        // pipeline's accounting (e.g. a future change that routes empty
        // batches to `.indexed` with a zero chunk count) would fail this
        // test *before* reaching the CLI.
        let guardTrips = !files.isEmpty
            && added == 0 && updated == 0
            && embedFailures > 0
        XCTAssertTrue(guardTrips,
                      "CLI silent-failure guard condition must hold for this input")
    }

    // MARK: - Negative pipeline contract (guard must NOT trip)

    /// Mixed outcomes: 1 file embeds successfully, 2 fail. The CLI guard
    /// requires `added + updated == 0` to fire — a single success must
    /// block it. This is the most important false-positive path.
    func testMixedOutcomeDoesNotTripGuard() async throws {
        try writeFile("success.md",
                      content: "This file should embed successfully end to end.\n")
        try writeFile("fail-a.md",
                      content: "This file's embeds will all be rejected by the mock.\n")
        try writeFile("fail-b.md",
                      content: "This file's embeds will also all be rejected.\n")

        let files = try FileScanner(directory: sourceDir).scan()
        XCTAssertEqual(files.count, 3)

        // Succeed for any file whose relative path starts with "success".
        let profile = makeMockProfile { text in
            // Mock decision is based on text content since the embedder
            // API doesn't pass paths. The "success.md" content contains
            // the unique token "successfully" — use it as a selector.
            text.contains("successfully") ? .succeed : .fail
        }

        let (added, updated, embedFailures, unreadable) = try await runPipeline(
            profile: profile,
            files: files
        )

        XCTAssertEqual(added, 1, "the success file should land in the DB")
        XCTAssertEqual(updated, 0)
        XCTAssertEqual(embedFailures, 2, "both fail files should skip")
        XCTAssertEqual(unreadable, 0)

        // Guard MUST NOT trip on a partial success — a single success
        // means the DB has real vectors, and failing hard here would
        // hide the same information the error is meant to surface.
        let guardTrips = !files.isEmpty
            && added == 0 && updated == 0
            && embedFailures > 0
        XCTAssertFalse(guardTrips,
                       "guard must not trip when at least one file succeeded")
    }

    /// `.skippedUnreadable`-only: a run over a corpus with no indexable
    /// files (e.g. binaries filtered out, or every file is empty) should
    /// not trip the guard. No embed attempts happened, so there is no
    /// silent failure to report.
    func testUnreadableOnlyDoesNotTripGuard() async throws {
        // Empty text files → extract produces zero chunks → pipeline
        // emits `.skippedUnreadable` for each. This is the "every file
        // in the corpus is filtered out" path the guard must ignore.
        try writeFile("empty-a.md", content: "")
        try writeFile("empty-b.md", content: "")

        let files = try FileScanner(directory: sourceDir).scan()
        XCTAssertEqual(files.count, 2)

        let profile = makeMockProfile { _ in .fail }
        let (added, updated, embedFailures, unreadable) = try await runPipeline(
            profile: profile,
            files: files
        )

        XCTAssertEqual(added, 0)
        XCTAssertEqual(updated, 0)
        XCTAssertEqual(embedFailures, 0,
                       "no embed calls happen when extract produces zero chunks")
        XCTAssertEqual(unreadable, 2, "both empty files should be .skippedUnreadable")

        let guardTrips = !files.isEmpty
            && added == 0 && updated == 0
            && embedFailures > 0
        XCTAssertFalse(guardTrips,
                       "guard must not trip when only `.skippedUnreadable` was recorded")
    }

    // MARK: - Helpers

    @discardableResult
    private func writeFile(_ relativePath: String, content: String) throws -> URL {
        let url = sourceDir.appendingPathComponent(relativePath)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeMockProfile(
        decider: @escaping @Sendable (String) -> EmbedOutcome
    ) -> IndexingProfile {
        let factory: @Sendable () -> any Embedder = {
            SelectiveMockEmbedder(decider: decider)
        }
        return IndexingProfile(
            identity: "mock@1200/240",
            embedder: factory(),
            embedderFactory: factory,
            splitter: RecursiveCharacterSplitter(chunkSize: 1200, chunkOverlap: 240),
            chunkSize: 1200,
            chunkOverlap: 240,
            isBuiltIn: false
        )
    }

    /// Runs the pipeline and returns the per-outcome tally the CLI uses.
    private func runPipeline(
        profile: IndexingProfile,
        files: [FileInfo]
    ) async throws -> (added: Int, updated: Int, embedFailures: Int, unreadable: Int) {
        let database = VectorDatabase(
            databaseDirectory: dbDir,
            sourceDirectory: sourceDir,
            dimension: 768
        )
        try await database.initialize()

        let workItems = files.map { (file: $0, label: "Added") }
        let pipeline = IndexingPipeline(concurrency: 2, batchSize: 4, profile: profile)
        let (results, _) = try await pipeline.run(
            workItems: workItems,
            extractor: TextExtractor(splitter: profile.splitter),
            database: database
        )

        XCTAssertEqual(results.count, workItems.count,
                       "pipeline must return one result per input file")

        var added = 0, updated = 0, embedFailures = 0, unreadable = 0
        for r in results {
            switch r {
            case .indexed(_, let wasUpdate, _, _):
                if wasUpdate { updated += 1 } else { added += 1 }
            case .skippedEmbedFailure:
                embedFailures += 1
            case .skippedUnreadable:
                unreadable += 1
            }
        }
        return (added, updated, embedFailures, unreadable)
    }
}

/// Per-call decision for the selective mock embedder.
enum EmbedOutcome: Sendable {
    case succeed  // returns a deterministic 768-dim vector
    case fail     // returns []
}

/// Mock embedder whose per-call outcome is driven by the caller. The
/// `decider` runs on the text being embedded, so tests can simulate
/// realistic mixed-outcome pipelines (some chunks embed, others fail).
/// Actor to match the protocol's Sendable expectation.
private actor SelectiveMockEmbedder: Embedder {
    nonisolated var name: String { "selective-mock-768" }
    nonisolated var dimension: Int { 768 }

    private let decider: @Sendable (String) -> EmbedOutcome

    init(decider: @escaping @Sendable (String) -> EmbedOutcome) {
        self.decider = decider
    }

    func embedDocument(_ text: String) async throws -> [Float] {
        switch decider(text) {
        case .succeed: return Array(repeating: Float(0.1), count: 768)
        case .fail:    return []
        }
    }

    func embedQuery(_ text: String) async throws -> [Float] {
        try await embedDocument(text)
    }

    func embedDocuments(_ texts: [String]) async throws -> [[Float]] {
        texts.map { text in
            switch decider(text) {
            case .succeed: return Array(repeating: Float(0.1), count: 768)
            case .fail:    return []
            }
        }
    }
}
