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
///
/// **H7 note on per-file embed seconds.** Under the three-stage pipeline a
/// file's chunks no longer embed inside one worker — they fan out across the
/// pool and arrive at the per-file accumulator out of order. The per-file
/// `embedSeconds` recorded here is therefore an *embed span*: wall-clock from
/// the first chunk leaving extract to the last chunk arriving at the
/// accumulator. It includes pool waits and overlaps with other files'
/// chunks, so its absolute magnitude isn't directly comparable to the
/// pre-H7 per-file embed time. The aggregate `embedSeconds` and
/// `totalBatchEmbedSeconds` (now: summed per-chunk wall-clock across every
/// embed task) remain the right inputs for pool-utilization math.
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

    /// 50th percentile embed-span-seconds-per-file across non-skipped files
    /// (0 if empty). See struct doc on the post-H7 meaning of "embed seconds".
    public var p50EmbedSeconds: Double = 0
    /// 95th percentile embed-span-seconds-per-file across non-skipped files
    /// (0 if empty). See struct doc on the post-H7 meaning of "embed seconds".
    public var p95EmbedSeconds: Double = 0
    /// File that produced the most chunks, if any files were indexed.
    public var largestFile: FileTiming?
    /// Wall-clock seconds from pipeline start to the first `.chunkEmbedded`
    /// event. Approximates the "extract-bound startup" window — if this is
    /// much larger than a typical per-file extract time, the extract stage
    /// got blocked before any chunk could embed.
    public var firstBatchLatencySeconds: Double?
    /// Total embed tasks completed across all files. Under H7 each task
    /// embeds exactly one chunk, so post-refactor this equals
    /// `totalChunksEmbedded` for any successful run. The field name is kept
    /// for API stability; the verbose footer's "mean batch size" therefore
    /// always reads as 1.0 chunks/task post-H7 — that's the truth, not a
    /// renderer bug.
    public var totalBatches: Int = 0
    /// Total chunks across all embed tasks. Cross-check against
    /// `totalChunksEmbedded` (summed from `recordFile`): equality means
    /// no embed result was dropped between embed-time and DB-time.
    public var totalBatchChunks: Int = 0
    /// Summed seconds spent in `EmbeddingService.embed` calls across all
    /// per-chunk embed tasks. Equal to or slightly less than
    /// `embedSeconds` — the gap reflects embedder-pool waits and
    /// task-group bookkeeping.
    public var totalBatchEmbedSeconds: Double = 0
}

/// Structured progress event emitted by the pipeline. Consumers are expected to
/// maintain their own counters; the pipeline carries no presentation concerns.
///
/// Events fall into four groups by origin:
///
/// - **Stage-transition events** — `.extractEnqueued`/`.extractDequeued` and
///   `.embedEnqueued`/`.embedDequeued`: emitted when items move between
///   stages. Difference (enqueued − dequeued) is the live queue depth and
///   tells you which stage is the current bottleneck. Replaces the old
///   `.workerBusy`/`.workerIdle` pair, which doesn't have a coherent
///   meaning under the three-stage pipeline (extract is single-threaded,
///   embed is one task per chunk so "in flight" equals pool size whenever
///   there's work).
///
/// - **Embed-task events** — `.chunkEmbedded`: emitted from each per-chunk
///   embed task. Replaces the old `.batchEmbedded`. Lock-traffic note:
///   even at post-H7 throughput (~50–100 c/s) this is one event per chunk
///   per second, well within an `NSLock`'s capacity in `ProgressRenderer`.
///
/// - **File-lifecycle events** — `.fileFinished`, `.fileSkipped`,
///   `.nonEnglishDetected`: emitted from extract (skips/lang) and the DB
///   writer (success). The non-English event now fires from extract on
///   the first chunk per file; under H7 there's no longer an "embed
///   stage in worker" where it could naturally live.
///
/// - **Save-channel events** — `.saveEnqueued`, `.saveDequeued`,
///   `.poolWarmed`: unchanged from pre-H7.
public enum ProgressEvent: Sendable {
    /// File popped off the input queue and started extracting.
    case extractEnqueued
    /// File done extracting and all its chunks have been pushed to the
    /// embed stream (or the file produced zero chunks and a sentinel was
    /// pushed to the accumulator).
    case extractDequeued
    /// A chunk was extracted and pushed to the embed stream, awaiting
    /// pool capacity.
    case embedEnqueued
    /// An embed task picked up a chunk and acquired a pooled embedder.
    case embedDequeued
    case fileFinished(chunks: Int)
    case fileSkipped
    case nonEnglishDetected(filePath: String, language: String)
    /// One chunk finished embedding. `seconds` is the wall-clock spent in
    /// this single `EmbeddingService.embed` call (pool wait excluded).
    case chunkEmbedded(seconds: Double)
    /// File handed off from the per-file accumulator to the DB-writer save
    /// stream. Paired with `.saveDequeued` from the DB writer so renderers
    /// can show live save-queue depth as a bottleneck signal.
    case saveEnqueued
    case saveDequeued
    /// Pool warmup completed. Emitted once per `run()` after every pooled
    /// embedder has been pre-touched serially, before any worker task starts.
    /// `seconds` is wall-clock time spent in the warmup loop.
    case poolWarmed(seconds: Double)
}

public typealias ProgressHandler = @Sendable (ProgressEvent) -> Void

/// A batch of embedded records for a complete file, ready for DB insertion.
///
/// `totalChunksExtracted` is the number of chunks the extract stage produced
/// for this file (before any embed attempts). The DB writer uses it to
/// distinguish:
///
/// - `records.isEmpty && totalChunksExtracted == 0` — extract produced no
///   chunks (unreadable / empty file) → `.skippedUnreadable`.
/// - `records.isEmpty && totalChunksExtracted > 0` — every chunk failed to
///   embed → `.skippedEmbedFailure` (with a per-file stats entry recording
///   `chunkCount: 0`, matching pre-H7 behavior).
struct SaveWork: Sendable {
    let file: FileInfo
    let label: String
    let records: [ChunkRecord]
    let extractSeconds: Double
    let embedSeconds: Double
    let totalChunksExtracted: Int
}

/// A three-stage producer/consumer pipeline that parallelizes file indexing.
///
/// **Stage 1 — Extract (single task).** Pulls files off the input queue
/// serially, calls `TextExtractor.extract(from:)`, stamps each chunk with
/// `(filePath, ordinal, totalChunks)`, and pushes one `EmbedWork` per chunk
/// onto the embed stream. Single-threaded by design: extract is cheap
/// relative to embed, and a serial extractor keeps order deterministic per
/// file (so the accumulator's sort is stable). Files that produce zero
/// chunks (unreadable / empty) push a synthetic `EmbedWork` with
/// `totalChunks == 0` so the accumulator can fire an empty save and close
/// out the file.
///
/// **Stage 2 — Embed (one task per chunk, pool-gated).** Each `EmbedWork`
/// spawns its own task inside a TaskGroup. The task awaits an embedder
/// from `EmbedderPool` (effective concurrency limit = pool size =
/// `activeProcessorCount`), runs `embed()`, builds a `ChunkRecord`, and
/// pushes a `(filePath, ordinal, total, record)` tuple onto the
/// accumulator stream. Releases the embedder back to the pool. Compared
/// to pre-H7's per-file batched embed: a huge file no longer holds nine
/// other workers' chunks hostage — every chunk competes equally for pool
/// capacity, and small files' chunks interleave naturally.
///
/// **Stage 3a — Per-file accumulator (actor).** Groups incoming
/// `EmbeddedChunk`s by file path. Each file's `total` is known at first
/// contact (carried on every chunk). When a file's accumulated record
/// count equals `total`, the accumulator sorts by ordinal and emits one
/// `SaveWork` to the save stream. Empty files (`total == 0`) emit
/// immediately.
///
/// **Stage 3b — DB writer (single task).** Serial consumer of the save
/// stream, identical in shape to pre-H7.
public final class IndexingPipeline: Sendable {

    /// Number of pooled embedders, also the effective concurrency cap for
    /// the embed stage (every embed task acquires one). Exposed so callers
    /// can size progress displays against the same value the pool uses.
    public let workerCount: Int

    /// Pool of pre-created EmbeddingService instances.
    private let pool: EmbedderPool

    /// Whether to warm each pooled embedder serially before the worker
    /// task group starts. Defaults to true (the H5 result). Exposed as an
    /// internal init seam so measurement tests can compare cold vs warm
    /// without polluting the public API.
    internal let warmupEnabled: Bool

    public convenience init(
        concurrency: Int = max(ProcessInfo.processInfo.activeProcessorCount, 2)
    ) {
        self.init(concurrency: concurrency, warmup: true)
    }

    /// Internal init that exposes the warmup toggle. Used by measurement
    /// tests to bypass warmup; production callers should use the public init.
    internal init(
        concurrency: Int = max(ProcessInfo.processInfo.activeProcessorCount, 2),
        warmup: Bool
    ) {
        self.workerCount = concurrency
        self.pool = EmbedderPool(count: concurrency)
        self.warmupEnabled = warmup
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

        let pool = self.pool

        // H5: warm each pooled embedder serially before workers start, so
        // the first chunk doesn't pay 10× parallel NLEmbedding cold-load
        // cost contending for memory bandwidth.
        if warmupEnabled {
            let warmStart = DispatchTime.now()
            await pool.warmAll()
            let warmSeconds = Self.elapsed(since: warmStart)
            progress?(.poolWarmed(seconds: warmSeconds))
        }

        // Embed stream: extract task → embed-spawner.
        // Unbounded buffering: extract should always be faster than embed
        // (no embed call), so chunks queue here until the pool has
        // capacity. The embed-queue depth (.embedEnqueued − .embedDequeued)
        // is the diagnostic signal for "is embed the bottleneck?".
        let (embedStream, embedContinuation) = AsyncStream<EmbedWork>.makeStream(
            bufferingPolicy: .unbounded
        )

        // Accumulator stream: embed tasks → per-file accumulator.
        let (accumStream, accumContinuation) = AsyncStream<EmbeddedChunk>.makeStream(
            bufferingPolicy: .unbounded
        )

        // Save stream: per-file accumulator → DB writer (single consumer).
        let (saveStream, saveContinuation) = AsyncStream<SaveWork>.makeStream(
            bufferingPolicy: .unbounded
        )

        let resultCollector = ResultCollector()
        let pipelineStart = DispatchTime.now()
        let statsCollector = StatsCollector(pipelineStart: pipelineStart)
        let accumulator = FileAccumulator()
        // Per-chunk backpressure: extract blocks once the embed queue is
        // roughly two pool-sizes deep. Keeps memory bounded on large
        // corpora (previously extract would race through all files and
        // queue tens of thousands of chunks' text before embed caught up).
        let extractGate = ExtractBackpressure(capacity: workerCount * 2)

        try await withThrowingTaskGroup(of: Void.self) { group in

            // Stage 1: Extract (single serial task).
            //
            // N_extract = 1 by design. Extract is cheap and keeping it
            // single-threaded preserves intra-file ordinal monotonicity
            // and removes any need to lock a shared queue.
            group.addTask {
                for item in workItems {
                    progress?(.extractEnqueued)
                    let extractStart = DispatchTime.now()
                    let chunks: [TextChunk]
                    do {
                        chunks = try extractor.extract(from: item.file)
                    } catch {
                        let extractSeconds = Self.elapsed(since: extractStart)
                        // Unreadable file: register a zero-total file with
                        // the accumulator and immediately close it so the
                        // DB writer reports the skip. Result accounting
                        // stays single-sourced (the DB writer).
                        await accumulator.markFileTotal(
                            path: item.file.relativePath,
                            file: item.file,
                            label: item.label,
                            total: 0,
                            extractSeconds: extractSeconds,
                            firstChunkAt: nil
                        )
                        if let work = await accumulator.closeIfComplete(path: item.file.relativePath) {
                            progress?(.saveEnqueued)
                            saveContinuation.yield(work)
                        }
                        progress?(.extractDequeued)
                        continue
                    }
                    let extractSeconds = Self.elapsed(since: extractStart)

                    if chunks.isEmpty {
                        // Empty / no-text file: same close-out as the
                        // unreadable path. The DB writer will translate
                        // an empty record set into `.skippedUnreadable`.
                        await accumulator.markFileTotal(
                            path: item.file.relativePath,
                            file: item.file,
                            label: item.label,
                            total: 0,
                            extractSeconds: extractSeconds,
                            firstChunkAt: nil
                        )
                        if let work = await accumulator.closeIfComplete(path: item.file.relativePath) {
                            progress?(.saveEnqueued)
                            saveContinuation.yield(work)
                        }
                        progress?(.extractDequeued)
                        continue
                    }

                    // Language-detect on the first chunk. Pre-H7 this
                    // happened in `processFile`; with no per-file worker
                    // anymore, it lives here.
                    if let firstText = chunks.first?.text {
                        let trimmed = firstText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty,
                           let lang = NLLanguageRecognizer.dominantLanguage(for: trimmed),
                           lang != .english, lang != .undetermined {
                            progress?(.nonEnglishDetected(
                                filePath: item.file.relativePath,
                                language: lang.rawValue
                            ))
                        }
                    }

                    let firstChunkAt = DispatchTime.now()
                    await accumulator.markFileTotal(
                        path: item.file.relativePath,
                        file: item.file,
                        label: item.label,
                        total: chunks.count,
                        extractSeconds: extractSeconds,
                        firstChunkAt: firstChunkAt
                    )

                    for (index, chunk) in chunks.enumerated() {
                        // Block until the embed queue has room. Permit
                        // released in the embed task after handoff to the
                        // accumulator. Keeps extract from running ahead
                        // of embed on large corpora.
                        await extractGate.acquire()
                        let work = EmbedWork(
                            file: item.file,
                            label: item.label,
                            chunk: chunk,
                            ordinal: index,
                            totalChunks: chunks.count,
                            extractSeconds: extractSeconds,
                            firstChunkAt: firstChunkAt
                        )
                        progress?(.embedEnqueued)
                        embedContinuation.yield(work)
                    }
                    progress?(.extractDequeued)
                }
                // All files extracted; close the embed stream so the
                // embed-spawner stage knows it's done.
                embedContinuation.finish()
            }

            // Stage 2: Embed-spawner. Drains the embed stream, spawns one
            // task per chunk inside a TaskGroup. The pool's acquire/release
            // is the natural concurrency gate — we don't need a separate
            // semaphore. Tasks are unstructured-per-chunk inside the
            // group, so a long-running embed doesn't block the next chunk
            // from being scheduled.
            group.addTask {
                await withTaskGroup(of: Void.self) { embedGroup in
                    for await work in embedStream {
                        embedGroup.addTask {
                            progress?(.embedDequeued)
                            // Empty-file sentinel never goes through here
                            // (extract closes them out directly). All
                            // EmbedWork that reaches the embed stream has
                            // a non-nil chunk.
                            guard let chunk = work.chunk else { return }

                            let embedder = await pool.acquire()
                            let chunkStart = DispatchTime.now()
                            let vector = embedder.embed(chunk.text)
                            let chunkSeconds = Self.elapsed(since: chunkStart)
                            await pool.release(embedder)

                            progress?(.chunkEmbedded(seconds: chunkSeconds))
                            await statsCollector.recordChunkEmbed(seconds: chunkSeconds)

                            let record: ChunkRecord?
                            if let vector = vector {
                                record = ChunkRecord(
                                    filePath: work.file.relativePath,
                                    lineStart: chunk.lineStart,
                                    lineEnd: chunk.lineEnd,
                                    chunkType: chunk.type,
                                    pageNumber: chunk.pageNumber,
                                    fileModifiedAt: work.file.modificationDate,
                                    contentPreview: String(chunk.text.prefix(200)),
                                    embedding: vector
                                )
                            } else {
                                // Embed failed for this chunk — still
                                // contribute to the file's total so the
                                // accumulator knows when the file is done.
                                // Failed chunks just don't produce a
                                // ChunkRecord; the file is recorded with
                                // whatever subset succeeded.
                                record = nil
                            }

                            let emitted = EmbeddedChunk(
                                filePath: work.file.relativePath,
                                ordinal: work.ordinal,
                                record: record
                            )
                            accumContinuation.yield(emitted)
                            // Release the extract-gate permit that was
                            // acquired when this chunk was yielded onto
                            // the embed stream. Released on every embed
                            // path (success or vector == nil failure) —
                            // if an embed path stops releasing, extract
                            // will eventually deadlock on a full gate.
                            await extractGate.release()
                        }
                    }
                }
                // All embed tasks done; close the accumulator stream.
                accumContinuation.finish()
            }

            // Stage 3a: Per-file accumulator. Groups by file path, emits
            // SaveWork the moment a file's chunk count is reached.
            group.addTask {
                for await emitted in accumStream {
                    if let work = await accumulator.add(emitted) {
                        progress?(.saveEnqueued)
                        saveContinuation.yield(work)
                    }
                }
                // No more chunks; close the save stream.
                saveContinuation.finish()
            }

            // Stage 3b: DB Writer (single serial consumer). Identical
            // shape to pre-H7.
            group.addTask {
                for await work in saveStream {
                    progress?(.saveDequeued)
                    let path = work.file.relativePath

                    if work.records.isEmpty {
                        if work.totalChunksExtracted > 0 {
                            // Extract produced chunks but every embed
                            // failed. Pre-H7 reported this as
                            // .skippedEmbedFailure and still recorded a
                            // per-file timing with chunkCount: 0 so the
                            // file appears in fileTimings. Preserve both.
                            await resultCollector.record(.skippedEmbedFailure(filePath: path))
                            await statsCollector.recordFile(
                                path: path,
                                extractSeconds: work.extractSeconds,
                                embedSeconds: work.embedSeconds,
                                dbSeconds: 0,
                                chunkCount: 0
                            )
                        } else {
                            // Extract produced zero chunks (unreadable /
                            // no-text / empty). No embed work happened;
                            // stats only account the extract time.
                            await resultCollector.record(.skippedUnreadable(filePath: path))
                            await statsCollector.recordSkipped(
                                path: path,
                                extractSeconds: work.extractSeconds
                            )
                        }
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
}

// MARK: - Stage Payloads

/// One unit of work flowing from extract → embed. `chunk == nil` is reserved
/// for empty-file sentinels (currently the accumulator handles those
/// directly so they don't actually traverse the embed stream — kept on the
/// type for future flexibility).
struct EmbedWork: Sendable {
    let file: FileInfo
    let label: String
    let chunk: TextChunk?
    let ordinal: Int
    let totalChunks: Int
    let extractSeconds: Double
    let firstChunkAt: DispatchTime?
}

/// One embedded chunk flowing from embed → accumulator. `record == nil`
/// means the embed call returned nil for this chunk (rare); the
/// accumulator still counts it toward the file's total so the file can
/// complete, but contributes no record.
struct EmbeddedChunk: Sendable {
    let filePath: String
    let ordinal: Int
    let record: ChunkRecord?
}

// MARK: - Per-file Accumulator

/// Holds partial results for files in flight. A file's `total` is set by
/// the extract stage on first contact; chunks arrive from embed tasks in
/// arbitrary order. When `received == total`, the accumulator sorts by
/// ordinal and returns a `SaveWork` ready for the DB writer.
///
/// Empty files (`total == 0`) close out immediately via
/// `closeIfComplete(path:)` — the extract stage calls that synchronously
/// after `markFileTotal` for the unreadable / no-text paths.
actor FileAccumulator {

    private struct PartialFile {
        var file: FileInfo
        var label: String
        var total: Int
        var received: [EmbeddedChunk] = []
        var extractSeconds: Double
        // Wall-clock anchor for embed-span: time the first chunk left
        // extract for this file. nil for empty files. Used to compute
        // per-file `embedSeconds` at close time as
        // `now - firstChunkAt`. This is an *embed span*, not summed
        // per-chunk wall-clock — see IndexingStats doc.
        var firstChunkAt: DispatchTime?
    }

    private var files: [String: PartialFile] = [:]

    func markFileTotal(
        path: String,
        file: FileInfo,
        label: String,
        total: Int,
        extractSeconds: Double,
        firstChunkAt: DispatchTime?
    ) {
        // First contact for this file. Extract is single-threaded so
        // markFileTotal always runs before any add() for the same file.
        files[path] = PartialFile(
            file: file,
            label: label,
            total: total,
            received: [],
            extractSeconds: extractSeconds,
            firstChunkAt: firstChunkAt
        )
    }

    /// Append an embedded chunk. If this completes the file, remove it
    /// from the in-flight map and return a SaveWork ready for the DB
    /// writer. Otherwise return nil.
    func add(_ chunk: EmbeddedChunk) -> SaveWork? {
        guard var partial = files[chunk.filePath] else {
            // Unknown file — should never happen because extract calls
            // markFileTotal before yielding any chunks. Drop silently
            // rather than crash the pipeline; a missing record will
            // show up as a chunk-count mismatch in stats if the
            // accounting ever drifts.
            return nil
        }
        partial.received.append(chunk)
        files[chunk.filePath] = partial
        return finalizeIfReady(path: chunk.filePath)
    }

    /// Force completion check for a file (used by extract for empty /
    /// unreadable files where no chunks will ever arrive).
    func closeIfComplete(path: String) -> SaveWork? {
        return finalizeIfReady(path: path)
    }

    private func finalizeIfReady(path: String) -> SaveWork? {
        guard let partial = files[path] else { return nil }
        guard partial.received.count == partial.total else { return nil }

        // Sort by ordinal so the DB sees chunks in the order extract
        // produced them. Stable order matters for display grouping
        // even though the embed stage shuffles arrival order.
        let sortedRecords: [ChunkRecord] = partial.received
            .sorted { $0.ordinal < $1.ordinal }
            .compactMap { $0.record }

        let embedSpan: Double
        if let start = partial.firstChunkAt {
            let nanos = DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds
            embedSpan = Double(nanos) / 1_000_000_000
        } else {
            embedSpan = 0
        }

        files.removeValue(forKey: path)
        return SaveWork(
            file: partial.file,
            label: partial.label,
            records: sortedRecords,
            extractSeconds: partial.extractSeconds,
            embedSeconds: embedSpan,
            totalChunksExtracted: partial.total
        )
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

    /// Pre-touches every pooled embedder with one throwaway `embed` call.
    /// Done **serially** on purpose: the goal is to avoid N parallel cold
    /// model loads contending for memory bandwidth on the first batch.
    /// Safe to call before any acquire — operates on `available` directly.
    func warmAll() async {
        for embedder in available {
            _ = embedder.embed("warmup text")
        }
    }
}

// MARK: - Extract Backpressure

/// Counting semaphore used to gate the extract stage against the embed
/// stage. Extract acquires one permit per chunk before yielding; embed
/// releases one permit per chunk once the chunk has been handed off to the
/// accumulator. Sized to `workerCount * 2` on init — large enough that the
/// pool never idles waiting for extract (there's always a chunk queued up
/// behind the one being embedded), small enough that extract blocks before
/// chunking a second huge file worth of text into memory.
///
/// The old extract stage used an unbounded `AsyncStream` buffer, which on
/// large corpora let extract race ahead of embed by tens of thousands of
/// chunks — each carrying the chunk's text plus metadata. This actor
/// replaces that with a hard bound.
actor ExtractBackpressure {
    private let capacity: Int
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(capacity: Int) {
        self.capacity = capacity
        self.available = capacity
    }

    /// Block until a permit is available, then consume one.
    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Return one permit. Resumes the oldest waiter if any.
    func release() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            available += 1
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
    private var firstChunkAt: DispatchTime?

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

    /// Records one per-chunk embed completion. Captures the
    /// first-chunk-latency the first time it's called so the footer can
    /// diagnose extract-bound startup — the gap between pipeline start
    /// and first embed.
    func recordChunkEmbed(seconds: Double) {
        stats.totalBatches += 1
        stats.totalBatchChunks += 1
        stats.totalBatchEmbedSeconds += seconds
        if firstChunkAt == nil {
            firstChunkAt = DispatchTime.now()
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

        if let first = firstChunkAt {
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
