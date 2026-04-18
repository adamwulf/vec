import XCTest
import Darwin
@testable import VecKit

/// H7 measurement test (see optimization-plan.md): runs the three-stage
/// pipeline on a "huge first file" corpus (one ~500-line file followed by
/// 20 smaller files) and reports first-file-completion wall-clock plus
/// total wall-clock. The motivating production observation was that with
/// the pre-H7 nested-TaskGroup design, the first file in a mixed-size
/// corpus monopolized pool capacity for ~170s while nine other workers
/// held smaller files hostage waiting for embedders. H7 should interleave
/// those smaller files' chunks onto the shared embed stage and drop
/// first-file-completion dramatically.
///
/// This test measures only — it does NOT gate on a speedup target, because
/// there is no in-test old-architecture baseline to compare against. The
/// reported numbers plus an implicit production comparison (from
/// optimization-plan.md) are the artifacts.
///
/// NOTE: slow (2 timed trials × real NLEmbedding). Skipped unless
/// `VEC_PERF_TESTS=1` is set, e.g.
///
///     VEC_PERF_TESTS=1 swift test --filter VecKitTests.ThreeStagePipelineTests/testThreeStage_hugeFirstFile
final class ThreeStagePipelineTests: XCTestCase {

    private var tempDir: URL!
    private var sourceDir: URL!

    override func setUp() {
        super.setUp()
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("VecThreeStage-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        tempDir = realpath(raw.path, &buf) != nil
            ? URL(fileURLWithPath: String(cString: buf), isDirectory: true)
            : raw
        sourceDir = tempDir.appendingPathComponent("source")
        try! FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    // MARK: - Synthetic corpus generator (mirrors ConcurrencySweepTests)

    private static let linePool: [String] = [
        "The project ships a CLI that indexes local files into a vector database.",
        "On-device embeddings avoid sending private content to any cloud provider.",
        "Benchmarking concurrency changes requires holding the corpus constant.",
        "A worker pool of ten instances duplicates embedding model weights.",
        "If the framework is already thread-safe a shared instance would save memory.",
        "Tokenization and model setup dominate the cost of small embeddings.",
        "First-batch latency is fifteen seconds on a typical run of the pipeline.",
        "Thread sanitizer reports on data races even when the program does not crash.",
        "Running the stress test five times in a row guards against intermittent failures.",
        "The sentence embedding model for English produces five-hundred-twelve-dimensional vectors.",
        "A chunk that exceeds ten thousand characters is truncated before being passed in.",
        "The save queue stays near zero depth throughout indexing in the common case.",
        "Worker count defaults to max of active processor count and two cores.",
        "The test corpus mixes short phrases medium sentences and long paragraphs.",
        "If the hypothesis succeeds we collapse the pool to one shared embedder.",
        "The verbose stats renderer prints average and rolling throughput numbers.",
        "Each hypothesis in the optimization plan has its own success criteria.",
        "Swift structured concurrency makes it straightforward to fan out work.",
        "We prefer an empirical answer because the original claim may be stale.",
        "The embedder pool currently round-robins across ten instances by default.",
        "Vector search retrieves content by meaning rather than by keyword matching.",
        "The query is encoded into the same space as the documents for retrieval.",
        "Nearest neighbors in the embedding space surface as search results.",
        "On a warm cache file system reads are negligible compared to embed cost.",
        "Cold cache read latency can dominate and distort micro-benchmarks.",
        "A single embedding instance loads the model weights into memory once.",
        "Ten instances load ten copies of the model weights into memory.",
        "Contention on shared caches can hurt throughput even without locks.",
        "Swift task groups compose well with throwing APIs and propagate cancellation.",
        "Task groups are a natural fit for concurrent stress tests with clean teardown."
    ]

    private static func makeFileBody(lineCount: Int, fileSeed: Int) -> String {
        var lines: [String] = []
        lines.reserveCapacity(lineCount)
        for i in 0..<lineCount {
            let pick = Self.linePool[(fileSeed &* 17 &+ i &* 3) % Self.linePool.count]
            lines.append("Line \(i) of file \(fileSeed): \(pick)")
        }
        return lines.joined(separator: "\n")
    }

    /// Huge-first-file corpus: one 500-line file (produces ~20 chunks via
    /// the default 30-line chunking with 8-line overlap, plus the whole-doc
    /// chunk), then 20 smaller files mixing short and medium sizes. The
    /// FileScanner orders alphabetically, so naming the huge file
    /// `file_00_huge.txt` guarantees it sorts first.
    private func generateCorpus() throws -> (fileCount: Int, totalLines: Int) {
        // One huge file, sorted first.
        let hugeBody = Self.makeFileBody(lineCount: 500, fileSeed: 0)
        try hugeBody.write(
            to: sourceDir.appendingPathComponent("file_00_huge.txt"),
            atomically: true,
            encoding: .utf8
        )

        // 20 smaller files, mix of short (~25 lines) and medium (~100
        // lines). File names sort after `file_00_huge.txt` so the huge
        // file is guaranteed first off the work queue.
        var totalLines = 500
        let smallerPlan: [(count: Int, lineCount: Int)] = [
            (12, 25),
            (8, 100)
        ]
        var fileIndex = 1
        for (count, lineCount) in smallerPlan {
            for _ in 0..<count {
                let body = Self.makeFileBody(lineCount: lineCount, fileSeed: fileIndex)
                let url = sourceDir.appendingPathComponent(String(format: "file_%02d.txt", fileIndex))
                try body.write(to: url, atomically: true, encoding: .utf8)
                fileIndex += 1
                totalLines += lineCount
            }
        }

        let fileCount = try FileManager.default
            .contentsOfDirectory(at: sourceDir, includingPropertiesForKeys: nil)
            .count
        return (fileCount, totalLines)
    }

    // MARK: - Single run

    private struct RunResult {
        let wallSeconds: Double
        let firstFileCompletionSeconds: Double?
        let chunksEmbedded: Int
        let filesIndexed: Int
    }

    /// Run the pipeline once on the pre-generated corpus. The progress
    /// callback watches for the first `.fileFinished` event and records
    /// the wall-clock at that moment so we can surface "first file
    /// completion" separately from total wall.
    private func runOnce(runTag: String) async throws -> RunResult {
        let dbDir = tempDir.appendingPathComponent("db-\(runTag)")
        let db = VectorDatabase(databaseDirectory: dbDir, sourceDirectory: sourceDir)
        try await db.initialize()

        let scanner = FileScanner(directory: sourceDir)
        let files = try scanner.scan()
        let workItems = files.map { (file: $0, label: "Added") }

        let extractor = TextExtractor()
        let pipeline = IndexingPipeline(embedder: NomicEmbedder())  // default concurrency, warmup on

        // Use a lock-protected box since the progress callback is
        // @Sendable and synchronous.
        final class FirstFileBox: @unchecked Sendable {
            private let lock = NSLock()
            private var seconds: Double?
            private let start: DispatchTime
            init(start: DispatchTime) { self.start = start }
            func recordIfFirst() {
                lock.lock()
                defer { lock.unlock() }
                if seconds == nil {
                    let nanos = DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds
                    seconds = Double(nanos) / 1_000_000_000
                }
            }
            func value() -> Double? {
                lock.lock()
                defer { lock.unlock() }
                return seconds
            }
        }

        let start = DispatchTime.now()
        let box = FirstFileBox(start: start)
        let progress: ProgressHandler = { event in
            switch event {
            case .fileFinished, .fileSkipped:
                box.recordIfFirst()
            default:
                break
            }
        }

        let (_, stats) = try await pipeline.run(
            workItems: workItems,
            extractor: extractor,
            database: db,
            progress: progress
        )
        let nanos = DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds
        let wall = Double(nanos) / 1_000_000_000

        try? FileManager.default.removeItem(at: dbDir)

        return RunResult(
            wallSeconds: wall,
            firstFileCompletionSeconds: box.value(),
            chunksEmbedded: stats.totalChunksEmbedded,
            filesIndexed: workItems.count
        )
    }

    // MARK: - Test

    private func logLine(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }

    func testThreeStage_hugeFirstFile() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["VEC_PERF_TESTS"] != nil,
            "Perf test — set VEC_PERF_TESTS=1 to run (1 warm-up + 2 timed runs against real NLEmbedding)"
        )
        logLine("[three-stage] WARNING: this test is slow — 1 warm-up + 2 timed runs against real NLEmbedding")

        let (fileCount, totalLines) = try generateCorpus()
        logLine("[three-stage] corpus files=\(fileCount) total_lines=\(totalLines) (1 huge file with 500 lines sorted first)")

        // One discarded warm-up so NLEmbedding model weights and pipeline
        // machinery are loaded before the timed runs start. Matches the
        // ConcurrencySweepTests pattern.
        logLine("[three-stage] warm-up run starting")
        let warmup = try await runOnce(runTag: "warmup")
        logLine("[three-stage] warm-up done wall=\(String(format: "%.2f", warmup.wallSeconds))s chunks=\(warmup.chunksEmbedded)")

        // Two timed trials.
        var trials: [RunResult] = []
        for trial in 1...2 {
            let result = try await runOnce(runTag: "trial\(trial)")
            XCTAssertGreaterThan(result.chunksEmbedded, 0,
                "trial=\(trial) must embed some chunks")
            trials.append(result)

            let ff = result.firstFileCompletionSeconds.map { String(format: "%.2f", $0) + "s" } ?? "n/a"
            let chps = result.wallSeconds > 0
                ? Double(result.chunksEmbedded) / result.wallSeconds
                : 0
            let line = [
                "[three-stage-row]",
                "trial=\(trial)",
                "wall=\(String(format: "%.2f", result.wallSeconds))s",
                "first_file=\(ff)",
                "chunks=\(result.chunksEmbedded)",
                "chps=\(String(format: "%.1f", chps))"
            ].joined(separator: " ")
            logLine(line)
        }

        // Summary table.
        logLine("[three-stage] ==== SUMMARY ====")
        let header = NSString(format: "[three-stage] %-8@ %-12@ %-14@ %-10@ %-10@",
                              "trial" as NSString,
                              "wall" as NSString,
                              "first_file" as NSString,
                              "chunks" as NSString,
                              "chps" as NSString)
        logLine(header as String)
        for (i, r) in trials.enumerated() {
            let ff = r.firstFileCompletionSeconds.map { String(format: "%.2fs", $0) } ?? "n/a"
            let chps = r.wallSeconds > 0 ? Double(r.chunksEmbedded) / r.wallSeconds : 0
            let line = NSString(format: "[three-stage] %-8d %-12.2f %-14@ %-10d %-10.1f",
                                i + 1,
                                r.wallSeconds,
                                ff as NSString,
                                r.chunksEmbedded,
                                chps)
            logLine(line as String)
        }
        logLine("[three-stage] ==== END SUMMARY ====")

        // Correctness assertions — no speed gating.
        for (i, r) in trials.enumerated() {
            XCTAssertEqual(r.filesIndexed, fileCount,
                "trial=\(i + 1) should process every file")
            XCTAssertGreaterThan(r.chunksEmbedded, 0,
                "trial=\(i + 1) must produce chunks")
        }
    }
}
