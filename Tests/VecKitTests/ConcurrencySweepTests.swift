import XCTest
import Darwin
@testable import VecKit

/// H2 measurement test (see optimization-plan.md): sweeps
/// `IndexingPipeline(concurrency:)` across a set of values and reports
/// chunks-per-second for each. Does not assert a winner — the goal is to
/// produce data the operator can use to pick a default worker count.
///
/// NOTE: this test is intentionally slow (several configs × 2 runs ×
/// synthetic corpus with real NLEmbedding, ~4 minutes). Skipped unless
/// `VEC_PERF_TESTS=1` is set, e.g.
///
///     VEC_PERF_TESTS=1 swift test --filter VecKitTests.ConcurrencySweepTests
final class ConcurrencySweepTests: XCTestCase {

    private var tempDir: URL!
    private var sourceDir: URL!

    override func setUp() {
        super.setUp()
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("VecConcurrencySweep-\(UUID().uuidString)")
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

    // MARK: - CPU info via host_info(HOST_BASIC_INFO)

    /// Reads physical and logical CPU counts from Mach's `host_basic_info`.
    /// Falls back to `activeProcessorCount` for both if the call fails, which
    /// is pessimistic but keeps the sweep functional.
    private static func cpuCounts() -> (physical: Int, logical: Int) {
        var info = host_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { p in
                host_info(mach_host_self(), HOST_BASIC_INFO, p, &count)
            }
        }
        guard kr == KERN_SUCCESS else {
            let n = ProcessInfo.processInfo.activeProcessorCount
            return (n, n)
        }
        return (Int(info.physical_cpu), Int(info.logical_cpu))
    }

    // MARK: - Synthetic corpus generator

    /// Deterministic English-ish line generator. Picks from a fixed pool of
    /// phrases so generated lines embed successfully under NLEmbedding.
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

    /// Produce a deterministic file body of the requested line count by
    /// cycling the line pool with a file-seeded offset so files differ.
    private static func makeFileBody(lineCount: Int, fileSeed: Int) -> String {
        var lines: [String] = []
        lines.reserveCapacity(lineCount)
        for i in 0..<lineCount {
            let pick = Self.linePool[(fileSeed &* 17 &+ i &* 3) % Self.linePool.count]
            // Prefix with a line number so nothing dedupes inside chunking.
            lines.append("Line \(i) of file \(fileSeed): \(pick)")
        }
        return lines.joined(separator: "\n")
    }

    /// Generate a synthetic corpus: mix of short (~25 lines), medium (~100
    /// lines), and long (~400 lines) files. Returns total expected lines
    /// as a sanity print. File sizes are chosen so the mid/long files produce
    /// multiple line-chunks each; short files produce whole-document chunks
    /// only (they sit below the 30-line chunking threshold).
    private func generateCorpus() throws -> Int {
        // 70 files: 30 short, 25 medium, 15 long → a few hundred chunks.
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

    /// Builds a fresh DB in a given sub-directory, runs the pipeline once,
    /// returns the wall-clock seconds and the pipeline's stats.
    private func runOnce(concurrency: Int, runTag: String) async throws -> (wallSeconds: Double, stats: IndexingStats) {
        let dbDir = tempDir.appendingPathComponent("db-\(runTag)")
        let db = VectorDatabase(databaseDirectory: dbDir, sourceDirectory: sourceDir, dimension: 768)
        try await db.initialize()

        let scanner = FileScanner(directory: sourceDir)
        let files = try scanner.scan()
        let workItems = files.map { (file: $0, label: "Added") }

        let extractor = TextExtractor()
        let pipeline = IndexingPipeline(concurrency: concurrency, embedder: NomicEmbedder())

        let start = DispatchTime.now()
        let (_, stats) = try await pipeline.run(
            workItems: workItems,
            extractor: extractor,
            database: db
        )
        let nanos = DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds
        let wall = Double(nanos) / 1_000_000_000

        // Tear down the DB directory so subsequent runs always start fresh.
        try? FileManager.default.removeItem(at: dbDir)

        return (wall, stats)
    }

    // MARK: - Test

    /// Route all sweep output through stderr and flush after every line so
    /// that a mid-test crash still produces useful diagnostics.
    private func logLine(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }

    func testConcurrencySweep_syntheticCorpus() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["VEC_PERF_TESTS"] != nil,
            "Perf test — set VEC_PERF_TESTS=1 to run (takes ~4 minutes)"
        )
        logLine("[concurrency-sweep] WARNING: this test is slow — several configs × 2 runs × real NLEmbedding")

        let (physical, logical) = Self.cpuCounts()
        logLine("[concurrency-sweep] cpu_physical=\(physical) cpu_logical=\(logical)")

        // Generate once; the same corpus is re-indexed into a fresh DB per run.
        let totalLines = try generateCorpus()
        let fileCount = try FileManager.default
            .contentsOfDirectory(at: sourceDir, includingPropertiesForKeys: nil)
            .count
        logLine("[concurrency-sweep] corpus files=\(fileCount) total_lines=\(totalLines)")

        // Sweep set from the task spec; dedupe and sort so overlapping values
        // (e.g. physical == logical) collapse cleanly.
        let rawValues = [4, 6, physical, logical, logical + 2]
        let sweepValues = Array(Set(rawValues)).sorted()
        logLine("[concurrency-sweep] sweep values=\(sweepValues)")

        // Warm-up: a single throwaway run at concurrency=2 to load NLEmbedding
        // model weights and JIT any pipeline machinery before timed runs start.
        // We discard its numbers entirely.
        logLine("[concurrency-sweep] warm-up run starting")
        let warmup = try await runOnce(concurrency: 2, runTag: "warmup")
        logLine("[concurrency-sweep] warm-up done wall=\(String(format: "%.2f", warmup.wallSeconds))s chunks=\(warmup.stats.totalChunksEmbedded)")

        struct Row {
            let concurrency: Int
            let run: Int
            let wallSeconds: Double
            let chunksEmbedded: Int
            let embedSeconds: Double
            let p95EmbedSeconds: Double
            var chunksPerSec: Double { wallSeconds > 0 ? Double(chunksEmbedded) / wallSeconds : 0 }
        }

        var rows: [Row] = []

        for c in sweepValues {
            for run in 1...2 {
                let tag = "c\(c)-r\(run)"
                let (wall, stats) = try await runOnce(concurrency: c, runTag: tag)
                XCTAssertGreaterThan(stats.totalChunksEmbedded, 0,
                    "concurrency=\(c) run=\(run) must embed some chunks")
                let row = Row(
                    concurrency: c,
                    run: run,
                    wallSeconds: wall,
                    chunksEmbedded: stats.totalChunksEmbedded,
                    embedSeconds: stats.embedSeconds,
                    p95EmbedSeconds: stats.p95EmbedSeconds
                )
                rows.append(row)

                let line = [
                    "[concurrency-sweep-row]",
                    "concurrency=\(row.concurrency)",
                    "run=\(row.run)",
                    "wall=\(String(format: "%.2f", row.wallSeconds))s",
                    "chunks=\(row.chunksEmbedded)",
                    "chps=\(String(format: "%.1f", row.chunksPerSec))",
                    "embed_sum=\(String(format: "%.2f", row.embedSeconds))s",
                    "p95_embed=\(String(format: "%.3f", row.p95EmbedSeconds))s"
                ].joined(separator: " ")
                logLine(line)
            }
        }

        // Summary table, one line per concurrency value with both runs and
        // the per-run chunks/sec so the eyeball test is immediate.
        logLine("[concurrency-sweep] ==== SUMMARY ====")
        logLine("[concurrency-sweep] cpu_physical=\(physical) cpu_logical=\(logical)")
        // Use %@ with NSString to print Swift strings safely — %s expects a C string.
        let header = NSString(format: "[concurrency-sweep] %-12@ %-10@ %-10@ %-10@ %-10@ %-10@",
                              "concurrency" as NSString, "run1_cps" as NSString, "run2_cps" as NSString,
                              "avg_cps" as NSString, "run1_wall" as NSString, "run2_wall" as NSString)
        logLine(header as String)
        let grouped = Dictionary(grouping: rows, by: \.concurrency)
        for c in sweepValues {
            guard let pair = grouped[c], pair.count == 2 else { continue }
            let r1 = pair.first { $0.run == 1 }!
            let r2 = pair.first { $0.run == 2 }!
            let avg = (r1.chunksPerSec + r2.chunksPerSec) / 2
            let line = NSString(format: "[concurrency-sweep] %-12d %-10.1f %-10.1f %-10.1f %-10.2f %-10.2f",
                                c, r1.chunksPerSec, r2.chunksPerSec, avg, r1.wallSeconds, r2.wallSeconds)
            logLine(line as String)
        }
        logLine("[concurrency-sweep] ==== END SUMMARY ====")
    }
}
