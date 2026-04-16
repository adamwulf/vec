import Foundation
import NaturalLanguage

/// Result of indexing a single file.
public enum IndexResult: Sendable {
    case indexed(filePath: String, wasUpdate: Bool, chunkCount: Int)
    case skippedUnreadable(filePath: String)
    case skippedEmbedFailure(filePath: String)
}

/// Per-stage wall-clock totals (summed across all files and concurrent workers)
/// plus the slowest individual files. Useful for spotting which stage dominates
/// real time and which files are tail-latency outliers.
public struct IndexingStats: Sendable {
    public struct FileTiming: Sendable {
        public let path: String
        public let totalSeconds: Double
        public let extractSeconds: Double
        public let embedSeconds: Double
        public let dbSeconds: Double
        public let chunkCount: Int
    }
    public var extractSeconds: Double = 0
    public var embedSeconds: Double = 0
    public var dbSeconds: Double = 0
    public var totalChunksEmbedded: Int = 0
    public var slowestFiles: [FileTiming] = []

    /// 50th percentile embed-seconds-per-file across non-skipped files (0 if empty).
    public var p50EmbedSeconds: Double = 0
    /// 95th percentile embed-seconds-per-file across non-skipped files (0 if empty).
    public var p95EmbedSeconds: Double = 0
    /// File that produced the most chunks, if any files were indexed.
    public var largestFile: FileTiming?
    /// Wall-clock seconds from pipeline start to the first `.batchEmbedded`
    /// event. Approximates the "extract-bound startup" window — if this is
    /// much larger than a typical per-file extract time, workers all got
    /// stuck in extract before any embedding could start.
    public var firstBatchLatencySeconds: Double?
    /// Total batches embedded across all files. Useful for computing mean
    /// batch size and batch-embed throughput.
    public var totalBatches: Int = 0
    /// Total chunks across all batches. Cross-check against
    /// `totalChunksEmbedded` (summed from `recordFile`): equality means
    /// no batch result was dropped between embed-time and DB-time.
    public var totalBatchChunks: Int = 0
    /// Summed seconds spent in `EmbeddingService.embed` calls across all
    /// batches. Equal to or slightly less than `embedSeconds` — the gap
    /// reflects embedder-pool waits and task-group bookkeeping.
    public var totalBatchEmbedSeconds: Double = 0
}

/// Structured progress event emitted by the pipeline. Consumers are expected to
/// maintain their own counters; the pipeline carries no presentation concerns.
///
/// Events fall into two groups with different task-origin guarantees:
///
/// - **Worker-side events** — `.workerBusy`, `.workerIdle`, `.nonEnglishDetected`,
///   `.batchEmbedded`: emitted from the N file-worker tasks. `.workerBusy` is
///   always paired with a matching `.workerIdle` from the *same* task, so a
///   renderer can maintain a balanced busy counter.
///
/// - **DB-writer events** — `.fileFinished`, `.fileSkipped`: emitted from the
///   single serial DB writer (or from a worker task in the unreadable/no-text
///   path, before the save stream). These are decoupled from worker busy/idle
///   — do *not* try to derive "workers in flight" from file-finish events.
public enum ProgressEvent: Sendable {
    case workerBusy
    case workerIdle
    case fileFinished(chunks: Int)
    case fileSkipped
    case nonEnglishDetected
    case batchEmbedded(seconds: Double, chunks: Int)
}

public typealias ProgressHandler = @Sendable (ProgressEvent) -> Void

/// A batch of embedded records for a complete file, ready for DB insertion.
struct SaveWork: Sendable {
    let file: FileInfo
    let label: String
    let records: [ChunkRecord]
    let extractSeconds: Double
    let embedSeconds: Double
}

/// A two-stage producer/consumer pipeline that parallelizes file indexing:
///
/// 1. **File Workers (N)** — extract chunks and embed them in parallel
/// 2. **DB Writer (1)** — serial consumer that flushes complete files to the database
///
/// The embedder pool pre-creates N `EmbeddingService` instances at startup
/// and vends them to embed tasks on demand. Each instance is used by only
/// one task at a time, avoiding the `NLEmbedding` concurrent-access crash.
public final class IndexingPipeline: Sendable {

    /// Maximum chunks per embed batch.
    private let embedBatchSize: Int

    /// Number of concurrent file workers. Exposed so callers can size
    /// progress displays ("N/M busy") against the same value the pool uses.
    public let workerCount: Int

    /// Pool of pre-created EmbeddingService instances.
    private let pool: EmbedderPool

    public init(
        embedBatchSize: Int = 20,
        concurrency: Int = max(ProcessInfo.processInfo.activeProcessorCount, 2)
    ) {
        self.embedBatchSize = embedBatchSize
        self.workerCount = concurrency
        self.pool = EmbedderPool(count: concurrency)
    }

    /// Run the full indexing pipeline for a set of file work items.
    ///
    /// - Parameters:
    ///   - workItems: Files to index, each with a label ("Added"/"Updated") for progress.
    ///   - extractor: Shared text extractor (thread-safe, immutable after init).
    ///   - database: The vector database actor to write into.
    ///   - progress: Optional callback for verbose progress messages.
    /// - Returns: Array of results, one per input work item, in arbitrary order.
    public func run(
        workItems: [(file: FileInfo, label: String)],
        extractor: TextExtractor,
        database: VectorDatabase,
        progress: ProgressHandler? = nil
    ) async throws -> (results: [IndexResult], stats: IndexingStats) {
        guard !workItems.isEmpty else { return ([], IndexingStats()) }

        let batchSize = embedBatchSize
        let pool = self.pool

        // Save stream: file workers → DB writer (single consumer)
        let (saveStream, saveContinuation) = AsyncStream<SaveWork>.makeStream(
            bufferingPolicy: .unbounded
        )

        let resultCollector = ResultCollector()
        let statsCollector = StatsCollector(pipelineStart: DispatchTime.now())

        try await withThrowingTaskGroup(of: Void.self) { group in

            // Stage 1: File Workers
            group.addTask {
                let queue = WorkQueue(workItems)

                await withTaskGroup(of: Void.self) { workers in
                    for _ in 0..<self.workerCount {
                        workers.addTask {
                            while let item = await queue.next() {
                                let result = await Self.processFile(
                                    item.file,
                                    label: item.label,
                                    extractor: extractor,
                                    pool: pool,
                                    batchSize: batchSize,
                                    progress: progress,
                                    statsCollector: statsCollector
                                )

                                switch result {
                                case .skipped(let indexResult, let extractSeconds):
                                    await resultCollector.record(indexResult)
                                    await statsCollector.recordSkipped(
                                        path: item.file.relativePath,
                                        extractSeconds: extractSeconds
                                    )
                                case .save(let saveWork):
                                    saveContinuation.yield(saveWork)
                                }
                            }
                        }
                    }
                }
                // All workers done — close the save stream
                saveContinuation.finish()
            }

            // Stage 2: DB Writer (single serial consumer)
            group.addTask {
                for await work in saveStream {
                    let path = work.file.relativePath

                    if work.records.isEmpty {
                        await resultCollector.record(.skippedEmbedFailure(filePath: path))
                        await statsCollector.recordFile(
                            path: path,
                            extractSeconds: work.extractSeconds,
                            embedSeconds: work.embedSeconds,
                            dbSeconds: 0,
                            chunkCount: 0
                        )
                        progress?(.fileSkipped)
                        continue
                    }

                    let dbStart = DispatchTime.now()
                    // Crash-safe: unmark → replace (atomic delete+insert) → mark
                    try await database.unmarkFileIndexed(path: path)
                    try await database.replaceEntries(forPath: path, with: work.records)
                    try await database.markFileIndexed(path: path, modifiedAt: work.file.modificationDate)
                    let dbSeconds = Self.elapsed(since: dbStart)

                    let wasUpdate = work.label == "Updated"
                    await resultCollector.record(.indexed(filePath: path, wasUpdate: wasUpdate, chunkCount: work.records.count))
                    await statsCollector.recordFile(
                        path: path,
                        extractSeconds: work.extractSeconds,
                        embedSeconds: work.embedSeconds,
                        dbSeconds: dbSeconds,
                        chunkCount: work.records.count
                    )
                    progress?(.fileFinished(chunks: work.records.count))
                }
            }

            try await group.waitForAll()
        }

        let results = await resultCollector.allResults()
        let stats = await statsCollector.snapshot()
        return (results, stats)
    }

    /// Wall-clock seconds since the given DispatchTime.
    fileprivate static func elapsed(since start: DispatchTime) -> Double {
        let nanos = DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds
        return Double(nanos) / 1_000_000_000
    }

    // MARK: - Per-file Processing

    private enum FileProcessResult: Sendable {
        case skipped(IndexResult, extractSeconds: Double)
        case save(SaveWork)
    }

    /// Process a single file: extract chunks, check language, embed in parallel, return results.
    ///
    /// Emits `.workerBusy` on entry and `.workerIdle` on every return path —
    /// balanced pair from the same task, so a renderer can track live
    /// "workers in flight". Worker-idle always fires even on the skip paths.
    private static func processFile(
        _ file: FileInfo,
        label: String,
        extractor: TextExtractor,
        pool: EmbedderPool,
        batchSize: Int,
        progress: ProgressHandler?,
        statsCollector: StatsCollector
    ) async -> FileProcessResult {
        progress?(.workerBusy)

        // Extract chunks
        let extractStart = DispatchTime.now()
        let chunks: [TextChunk]
        do {
            chunks = try extractor.extract(from: file)
        } catch {
            let extractSeconds = elapsed(since: extractStart)
            progress?(.fileSkipped)
            progress?(.workerIdle)
            return .skipped(.skippedUnreadable(filePath: file.relativePath), extractSeconds: extractSeconds)
        }
        let extractSeconds = elapsed(since: extractStart)

        if chunks.isEmpty {
            progress?(.fileSkipped)
            progress?(.workerIdle)
            return .skipped(.skippedUnreadable(filePath: file.relativePath), extractSeconds: extractSeconds)
        }

        // Language warning — before TaskGroup, no concurrency concern.
        // The stderr write stays in place for all modes; the event lets
        // verbose renderers keep a rolling non-English counter.
        if let firstText = chunks.first?.text {
            let trimmed = firstText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if let lang = NLLanguageRecognizer.dominantLanguage(for: trimmed),
                   lang != .english, lang != .undetermined {
                    FileHandle.standardError.write(
                        Data("Warning: non-English content detected in \(file.relativePath) (detected: \(lang.rawValue)), embedding quality may be reduced\n".utf8)
                    )
                    progress?(.nonEnglishDetected)
                }
            }
        }

        // Split into batches
        var batches: [[TextChunk]] = []
        for batchStart in stride(from: 0, to: chunks.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, chunks.count)
            batches.append(Array(chunks[batchStart..<batchEnd]))
        }

        // Embed batches in parallel via TaskGroup, gated by the embedder pool
        let embedStart = DispatchTime.now()
        let allRecords: [[ChunkRecord]] = await withTaskGroup(of: (Int, [ChunkRecord]).self) { group in
            for (index, batch) in batches.enumerated() {
                group.addTask {
                    let embedder = await pool.acquire()
                    // Swift doesn't allow `await` in `defer`, so we use an
                    // unstructured Task to return the embedder to the pool.
                    // The release runs shortly after the closure exits —
                    // safe because every acquire path has a matching release.
                    defer { Task { await pool.release(embedder) } }

                    let batchStart = DispatchTime.now()
                    var records: [ChunkRecord] = []
                    for chunk in batch {
                        guard let vector = embedder.embed(chunk.text) else { continue }
                        records.append(ChunkRecord(
                            filePath: file.relativePath,
                            lineStart: chunk.lineStart,
                            lineEnd: chunk.lineEnd,
                            chunkType: chunk.type,
                            pageNumber: chunk.pageNumber,
                            fileModifiedAt: file.modificationDate,
                            contentPreview: String(chunk.text.prefix(200)),
                            embedding: vector
                        ))
                    }
                    let batchSeconds = elapsed(since: batchStart)
                    if !records.isEmpty {
                        progress?(.batchEmbedded(seconds: batchSeconds, chunks: records.count))
                        await statsCollector.recordBatch(seconds: batchSeconds, chunks: records.count)
                    }
                    return (index, records)
                }
            }

            var indexed: [(Int, [ChunkRecord])] = []
            for await result in group {
                indexed.append(result)
            }
            // Sort by batch index to preserve chunk ordering
            indexed.sort { $0.0 < $1.0 }
            return indexed.map(\.1)
        }

        let embedSeconds = elapsed(since: embedStart)
        let records = allRecords.flatMap { $0 }

        progress?(.workerIdle)
        return .save(SaveWork(
            file: file,
            label: label,
            records: records,
            extractSeconds: extractSeconds,
            embedSeconds: embedSeconds
        ))
    }
}

// MARK: - Work Queue

/// Actor-based work queue for safely distributing items across concurrent workers.
/// Each call to `next()` returns the next item, or `nil` when exhausted.
actor WorkQueue<T: Sendable> {
    private var iterator: IndexingIterator<[T]>

    init(_ items: [T]) {
        self.iterator = items.makeIterator()
    }

    func next() -> T? {
        iterator.next()
    }
}

// MARK: - Embedder Pool

/// Actor-based pool of pre-created `EmbeddingService` instances.
/// Vends instances on demand and accepts them back when done.
/// Limits concurrent embedding to the pool size.
actor EmbedderPool {
    private var available: [EmbeddingService]
    private var waiters: [CheckedContinuation<EmbeddingService, Never>] = []

    init(count: Int) {
        self.available = (0..<count).map { _ in EmbeddingService() }
    }

    func acquire() async -> EmbeddingService {
        if let embedder = available.popLast() {
            return embedder
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release(_ embedder: EmbeddingService) {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume(returning: embedder)
        } else {
            available.append(embedder)
        }
    }
}

// MARK: - Result Collector

/// Thread-safe collector for per-file indexing results.
private actor ResultCollector {
    private var results: [IndexResult] = []

    func record(_ result: IndexResult) {
        results.append(result)
    }

    func allResults() -> [IndexResult] {
        results
    }
}

// MARK: - Stats Collector

/// Thread-safe collector for per-stage timings. Stage totals are summed across
/// all workers (so they can exceed wall-clock when N workers run in parallel —
/// that's the point: the ratio shows where CPU/IO time is actually spent).
private actor StatsCollector {
    private var stats = IndexingStats()
    private var fileTimings: [IndexingStats.FileTiming] = []
    private let pipelineStart: DispatchTime
    private var firstBatchAt: DispatchTime?

    init(pipelineStart: DispatchTime) {
        self.pipelineStart = pipelineStart
    }

    func recordFile(path: String, extractSeconds: Double, embedSeconds: Double, dbSeconds: Double, chunkCount: Int) {
        stats.extractSeconds += extractSeconds
        stats.embedSeconds += embedSeconds
        stats.dbSeconds += dbSeconds
        stats.totalChunksEmbedded += chunkCount
        fileTimings.append(IndexingStats.FileTiming(
            path: path,
            totalSeconds: extractSeconds + embedSeconds + dbSeconds,
            extractSeconds: extractSeconds,
            embedSeconds: embedSeconds,
            dbSeconds: dbSeconds,
            chunkCount: chunkCount
        ))
    }

    func recordSkipped(path: String, extractSeconds: Double) {
        stats.extractSeconds += extractSeconds
    }

    /// Records a batch-embed completion. Captures the first-batch-latency
    /// the first time it's called so the footer can diagnose "extract-bound
    /// startup" — the gap between pipeline start and first embed.
    func recordBatch(seconds: Double, chunks: Int) {
        stats.totalBatches += 1
        stats.totalBatchChunks += chunks
        stats.totalBatchEmbedSeconds += seconds
        if firstBatchAt == nil {
            firstBatchAt = DispatchTime.now()
        }
    }

    func snapshot() -> IndexingStats {
        var result = stats
        result.slowestFiles = fileTimings
            .sorted { $0.totalSeconds > $1.totalSeconds }
            .prefix(5)
            .map { $0 }

        // Percentiles over files that produced chunks (zero-chunk files
        // would skew p50 toward 0 and hide real embed cost).
        let embedSecondsSorted = fileTimings
            .filter { $0.chunkCount > 0 }
            .map(\.embedSeconds)
            .sorted()
        result.p50EmbedSeconds = Self.percentile(embedSecondsSorted, 0.50)
        result.p95EmbedSeconds = Self.percentile(embedSecondsSorted, 0.95)

        result.largestFile = fileTimings
            .filter { $0.chunkCount > 0 }
            .max { $0.chunkCount < $1.chunkCount }

        if let first = firstBatchAt {
            let nanos = first.uptimeNanoseconds &- pipelineStart.uptimeNanoseconds
            result.firstBatchLatencySeconds = Double(nanos) / 1_000_000_000
        }

        return result
    }

    /// Linear-interpolation percentile on a pre-sorted array. Returns 0 for
    /// an empty input.
    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        if sorted.count == 1 { return sorted[0] }
        let rank = p * Double(sorted.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = Int(rank.rounded(.up))
        if lower == upper { return sorted[lower] }
        let weight = rank - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }
}
