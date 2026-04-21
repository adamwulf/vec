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
final class SilentFailureGuardTests: XCTestCase {

    // MARK: - VecError surface

    func testIndexingProducedNoVectorsErrorDescriptionCarriesFileCounts() {
        let err = VecError.indexingProducedNoVectors(filesAttempted: 42, filesFailed: 42)
        let desc = err.errorDescription ?? ""
        XCTAssertTrue(desc.contains("42"),
                      "error description should surface the filesAttempted count")
        XCTAssertTrue(desc.contains("no vectors"),
                      "error description should name the silent-failure mode")
    }

    // MARK: - Pipeline contract

    /// When the embedder fails every batch, the pipeline must report
    /// `.skippedEmbedFailure` for every file the extract stage produced
    /// chunks for. The CLI tally relies on this: its silent-failure
    /// guard trips when `added + updated == 0 && skippedEmbedFailures > 0`.
    func testPipelineReportsSkippedEmbedFailureWhenEveryBatchReturnsEmpty() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceDir = tempDir.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)

        for i in 0..<3 {
            try "Content for file \(i). Some words to produce at least one chunk.\n"
                .write(to: sourceDir.appendingPathComponent("file-\(i).md"),
                       atomically: true, encoding: .utf8)
        }

        let files = try FileScanner(directory: sourceDir).scan()
        XCTAssertEqual(files.count, 3, "fixture should expose three files")

        let workItems = files.map { (file: $0, label: "Added") }

        // Build a profile with a mock embedder that always returns [] —
        // simulates the post-load failure mode where every embed call
        // silently returns "no vector" (the nomic CoreML/ANE case pre-fix).
        let factory: @Sendable () -> any Embedder = { EmptyVectorEmbedder() }
        let profile = IndexingProfile(
            identity: "mock@1200/240",
            embedder: factory(),
            embedderFactory: factory,
            splitter: RecursiveCharacterSplitter(chunkSize: 1200, chunkOverlap: 240),
            chunkSize: 1200,
            chunkOverlap: 240,
            isBuiltIn: false
        )

        let dbDir = tempDir.appendingPathComponent("db")
        let database = VectorDatabase(
            databaseDirectory: dbDir,
            sourceDirectory: sourceDir,
            dimension: 768
        )
        try await database.initialize()

        let pipeline = IndexingPipeline(concurrency: 2, batchSize: 4, profile: profile)
        let (results, _) = try await pipeline.run(
            workItems: workItems,
            extractor: TextExtractor(splitter: profile.splitter),
            database: database
        )

        XCTAssertEqual(results.count, 3, "one result per input file")

        var added = 0
        var updated = 0
        var embedFailures = 0
        for r in results {
            switch r {
            case .indexed(_, let wasUpdate, _):
                if wasUpdate { updated += 1 } else { added += 1 }
            case .skippedEmbedFailure:
                embedFailures += 1
            case .skippedUnreadable:
                XCTFail("fixtures are readable — unexpected .skippedUnreadable")
            }
        }

        XCTAssertEqual(added, 0, "no successful adds when every embed returns []")
        XCTAssertEqual(updated, 0, "no successful updates when every embed returns []")
        XCTAssertEqual(embedFailures, 3, "every file should report .skippedEmbedFailure")

        let chunkCount = try await database.totalChunkCount()
        XCTAssertEqual(chunkCount, 0, "no chunks should have been persisted")

        // CLI guard condition re-checked here so a regression in the
        // pipeline's accounting (e.g. a future change that routes empty
        // batches to `.indexed` with a zero chunk count) would fail this
        // test *before* reaching the CLI.
        let guardTrips = !workItems.isEmpty
            && added == 0 && updated == 0
            && embedFailures > 0
        XCTAssertTrue(guardTrips,
                      "CLI silent-failure guard condition must hold for this input")
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("VecSilentFailure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(raw.path, &buf) != nil {
            return URL(fileURLWithPath: String(cString: buf), isDirectory: true)
        }
        return raw
    }
}

/// Mock embedder that always returns empty vectors. Models the
/// post-load-failure state: the embedder reports success at the API
/// boundary but produces no data — exactly the scenario the
/// observability guard targets.
private actor EmptyVectorEmbedder: Embedder {
    nonisolated var name: String { "empty-mock-768" }
    nonisolated var dimension: Int { 768 }

    func embedDocument(_ text: String) async throws -> [Float] { [] }
    func embedQuery(_ text: String) async throws -> [Float] { [] }
    func embedDocuments(_ texts: [String]) async throws -> [[Float]] {
        Array(repeating: [], count: texts.count)
    }
}
