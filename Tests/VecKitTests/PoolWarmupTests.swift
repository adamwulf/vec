import XCTest
import Darwin
@testable import VecKit

/// H5 measurement test (see optimization-plan.md): compares pipeline runs
/// with the new eager pool warmup ON vs OFF, on the same synthetic
/// log-shaped corpus that ConcurrencySweepTests uses. Reports
/// first-batch-latency and wall-clock for both. Does not gate — the test
/// is measurement, not a pass/fail throughput check.
///
/// NOTE: this test is intentionally slow (4 timed runs + 1 warm-up against
/// real NLEmbedding, ~90s). Skipped unless `VEC_PERF_TESTS=1` is set, e.g.
///
///     VEC_PERF_TESTS=1 swift test --filter VecKitTests.PoolWarmupTests
final class PoolWarmupTests: XCTestCase {

    private var tempDir: URL!
    private var sourceDir: URL!

    override func setUp() {
        super.setUp()
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("VecPoolWarmup-\(UUID().uuidString)")
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

    /// 70 files: 30 short, 25 medium, 15 long — same shape as the H2 corpus.
    private func generateCorpus() throws -> Int {
        let plan: [(count: Int, lineCount: Int)] = [
            (30, 25),
            (25, 100),
            (15, 400)
        ]
        var fileIndex = 0
        var totalLines = 0
        for (count, lineCount) in plan {
            for _ in 0..<count {
                let body = Self.makeFileBody(lineCount: lineCount, fileSeed: fileIndex)
                let url = sourceDir.appendingPathComponent("file_\(fileIndex).txt")
                try body.write(to: url, atomically: true, encoding: .utf8)
                fileIndex += 1
                totalLines += lineCount
            }
        }
        return totalLines
    }

    // MARK: - Single run

    /// Builds a fresh DB, runs the pipeline once at the default concurrency
    /// with the requested warmup setting, and returns wall-clock + stats.
    private func runOnce(warmup: Bool, runTag: String) async throws -> (wallSeconds: Double, stats: IndexingStats) {
        let dbDir = tempDir.appendingPathComponent("db-\(runTag)")
        let db = VectorDatabase(databaseDirectory: dbDir, sourceDirectory: sourceDir)
        try await db.initialize()

        let scanner = FileScanner(directory: sourceDir)
        let files = try scanner.scan()
        let workItems = files.map { (file: $0, label: "Added") }

        let extractor = TextExtractor()
        // Use the internal init seam so we can compare warm vs cold runs
        // without changing the public API. Default concurrency
        // (activeProcessorCount) — the H2 result — is implicit via the
        // default arg.
        let pipeline = IndexingPipeline(warmup: warmup)

        let start = DispatchTime.now()
        let (_, stats) = try await pipeline.run(
            workItems: workItems,
            extractor: extractor,
            database: db
        )
        let nanos = DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds
        let wall = Double(nanos) / 1_000_000_000

        try? FileManager.default.removeItem(at: dbDir)

        return (wall, stats)
    }

    // MARK: - Test

    private func logLine(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }

    func testPoolWarmup_syntheticCorpus() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["VEC_PERF_TESTS"] != nil,
            "Perf test — set VEC_PERF_TESTS=1 to run (takes ~90 seconds)"
        )
        logLine("[pool-warmup] WARNING: this test is slow — 4 timed runs against real NLEmbedding")

        let totalLines = try generateCorpus()
        let fileCount = try FileManager.default
            .contentsOfDirectory(at: sourceDir, includingPropertiesForKeys: nil)
            .count
        logLine("[pool-warmup] corpus files=\(fileCount) total_lines=\(totalLines)")

        // NOTE: no discarded warm-up. The whole point of this test is to
        // measure cold-start behavior, and a discarded run would prime the
        // NLEmbedding model weights at process scope — masking the very
        // cost the H5 warmup is meant to attack. So trial 1 of the first
        // condition pays the genuine cold-load cost; later trials measure
        // steady-state.

        struct Row {
            let warmupOn: Bool
            let trial: Int
            let wallSeconds: Double
            let firstBatchLatency: Double?
            let chunksEmbedded: Int
        }

        // Interleave warmup-on vs warmup-off across trials so any system
        // drift (thermal, background load) hits both conditions roughly
        // equally. Order: off-1, on-1, off-2, on-2 — and crucially
        // off-1 pays the process-wide cold load, isolating the cost the
        // warmup is supposed to amortize.
        let plan: [(warmup: Bool, trial: Int)] = [
            (false, 1),
            (true, 1),
            (false, 2),
            (true, 2)
        ]

        var rows: [Row] = []
        for step in plan {
            let tag = (step.warmup ? "warm" : "cold") + "-\(step.trial)"
            let (wall, stats) = try await runOnce(warmup: step.warmup, runTag: tag)
            XCTAssertGreaterThan(stats.totalChunksEmbedded, 0,
                "warmup=\(step.warmup) trial=\(step.trial) must embed some chunks")
            let row = Row(
                warmupOn: step.warmup,
                trial: step.trial,
                wallSeconds: wall,
                firstBatchLatency: stats.firstBatchLatencySeconds,
                chunksEmbedded: stats.totalChunksEmbedded
            )
            rows.append(row)

            let fb = row.firstBatchLatency.map { String(format: "%.2f", $0) + "s" } ?? "n/a"
            let line = [
                "[pool-warmup-row]",
                "warmup=\(row.warmupOn ? "on " : "off")",
                "trial=\(row.trial)",
                "wall=\(String(format: "%.2f", row.wallSeconds))s",
                "first_batch=\(fb)",
                "chunks=\(row.chunksEmbedded)"
            ].joined(separator: " ")
            logLine(line)
        }

        // Before/after summary table.
        logLine("[pool-warmup] ==== SUMMARY ====")
        let header = NSString(format: "[pool-warmup] %-10@ %-12@ %-12@ %-12@ %-12@",
                              "warmup" as NSString,
                              "trial1_fb" as NSString, "trial2_fb" as NSString,
                              "trial1_wall" as NSString, "trial2_wall" as NSString)
        logLine(header as String)

        let grouped = Dictionary(grouping: rows, by: \.warmupOn)
        // Emit "off" then "on" for natural before-after reading.
        for warmupOn in [false, true] {
            guard let pair = grouped[warmupOn], pair.count == 2 else { continue }
            let r1 = pair.first { $0.trial == 1 }!
            let r2 = pair.first { $0.trial == 2 }!
            let fb1 = r1.firstBatchLatency.map { String(format: "%.2fs", $0) } ?? "n/a"
            let fb2 = r2.firstBatchLatency.map { String(format: "%.2fs", $0) } ?? "n/a"
            let line = NSString(format: "[pool-warmup] %-10@ %-12@ %-12@ %-12.2f %-12.2f",
                                (warmupOn ? "on" : "off") as NSString,
                                fb1 as NSString, fb2 as NSString,
                                r1.wallSeconds, r2.wallSeconds)
            logLine(line as String)
        }
        logLine("[pool-warmup] ==== END SUMMARY ====")
    }
}
