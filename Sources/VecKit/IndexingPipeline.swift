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
/// pre-H7 per-file embed time.
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
    /// Summed wall-clock seconds spent in `Embedder.embedDocument()` across
    /// every per-chunk embed task — pool waits excluded, overlaps across
    /// concurrent workers preserved. Strictly bounded by
    /// `wallSeconds * workerCount`, so this is the correct numerator for
    /// pool-utilization math. `embedSeconds` above is a per-file embed
    /// *span* and is not suitable for that calculation.
    public var totalEmbedCallSeconds: Double = 0
}

/// Structured progress event emitted by the pipeline. Consumers are expected to
/// maintain their own counters; the pipeline carries no presentation concerns.
///
/// Events fall into four groups by origin:
///
/// - **Stage-transition events** — `.extractEnqueued`/`.extractDequeued`:
///   emitted when files move into/out of extract. Difference (enqueued −
///   dequeued) is the live extract queue depth.
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
    case fileFinished(chunks: Int)
    case fileSkipped
    case nonEnglishDetected(filePath: String, language: String)
    /// One chunk finished embedding. `seconds` is the wall-clock spent in
    /// this single `Embedder.embedDocument` call (pool wait excluded).
    case chunkEmbedded(seconds: Double)
    /// File handed off from the per-file accumulator to the DB-writer save
    /// stream. Paired with `.saveDequeued` from the DB writer so renderers
    /// can show live save-queue depth as a bottleneck signal.
    case saveEnqueued
    case saveDequeued
    /// An embed child task has acquired an `Embedder` from the
    /// pool and is about to start embedding. Paired with `.poolReleased`.
    /// Difference is the true pool-occupancy gauge: it pins at pool size
    /// under saturation.
    case poolAcquired
    /// An embed child task has released its `Embedder` back to
    /// the pool after the `embedDocument()` call returned.
    case poolReleased
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
    /// Lines for text, pages for PDFs, nil for images / unknown.
    let linePageCount: Int?
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

    /// Max number of chunks per batch passed to `Embedder.embedDocuments`.
    /// The batch-former length-buckets chunks and flushes when a bucket
    /// reaches this size or the extract stream finishes. Capped at 32 to
    /// avoid BNNS crashes in `swift-embeddings` (jkrukowski#17).
    public let batchSize: Int

    /// Bounded pool of N embedder instances sized to `workerCount`.
    private let pool: EmbedderPool

    public init(
        concurrency: Int = max(ProcessInfo.processInfo.activeProcessorCount, 2),
        batchSize: Int = 16,
        profile: IndexingProfile
    ) {
        precondition(batchSize >= 1 && batchSize <= 32,
                     "batchSize must be in 1…32 (BNNS cap per swift-embeddings #17)")
        self.workerCount = concurrency
        self.batchSize = batchSize
        self.pool = EmbedderPool(factory: profile.embedderFactory, count: concurrency)
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
        let warmStart = DispatchTime.now()
        await pool.warmAll()
        let warmSeconds = Self.elapsed(since: warmStart)
        progress?(.poolWarmed(seconds: warmSeconds))

        // Embed stream: extract task → batch-former.
        // Unbounded buffering: extract should always be faster than embed
        // (no embed call), so chunks queue here until the batch-former
        // drains them.
        let (embedStream, embedContinuation) = AsyncStream<EmbedWork>.makeStream(
            bufferingPolicy: .unbounded
        )

        // Batch stream: batch-former → embed-spawner. Carries grouped
        // chunks so each pool acquisition processes a full batch.
        let (batchStream, batchContinuation) = AsyncStream<BatchWork>.makeStream(
            bufferingPolicy: .unbounded
        )

        // Accumulator stream: embed tasks → per-file accumulator.
        let (accumStream, accumContinuation) = AsyncStream<EmbeddedChunk>.makeStream(
            bufferingPolicy: .unbounded
        )

        // Save stream: per-file accumulator → DB writer (single consumer).
        // Unbounded by design — there is **no** upstream backpressure on
        // this stream: `extractGate` releases its permit (line ~488)
        // *before* the accumulator yields a `SaveWork`, so save-queue
        // depth depends entirely on the DB writer keeping up with the
        // file-completion rate. SaveWork instances carry chunk records
        // (~3 KB per record); realistic depth stays in single digits
        // because sqlite writes are O(10 MB/s) on this stack and
        // file-completion is paced by chunk extraction. If a future
        // embedder pairs wide vectors with a slow DB stage, this is the
        // first stream to add an explicit bound on (e.g. switch
        // bufferingPolicy to `.bufferingNewest(workerCount * 4)`).
        let (saveStream, saveContinuation) = AsyncStream<SaveWork>.makeStream(
            bufferingPolicy: .unbounded
        )

        let resultCollector = ResultCollector()
        let statsCollector = StatsCollector()
        let accumulator = FileAccumulator()
        // Per-chunk backpressure: sized to `workerCount * batchSize * 2`
        // so extract can queue up to ~2 batches per worker before blocking.
        // Undersizing this would stall extract immediately once the batched
        // pipeline starts consuming in batches rather than one-at-a-time.
        let extractGate = ExtractBackpressure(capacity: workerCount * batchSize * 2)
        let batchSize = self.batchSize

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
                    let extraction: ExtractionResult
                    do {
                        extraction = try extractor.extract(from: item.file)
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
                            firstChunkAt: nil,
                            linePageCount: nil
                        )
                        if let work = await accumulator.closeIfComplete(path: item.file.relativePath) {
                            progress?(.saveEnqueued)
                            saveContinuation.yield(work)
                        }
                        progress?(.extractDequeued)
                        continue
                    }
                    let chunks = extraction.chunks
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
                            firstChunkAt: nil,
                            linePageCount: extraction.linePageCount
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
                        firstChunkAt: firstChunkAt,
                        linePageCount: extraction.linePageCount
                    )

                    for (index, chunk) in chunks.enumerated() {
                        // Block until the embed queue has room. Permit
                        // released in the embed task after handoff to the
                        // accumulator. Keeps extract from running ahead
                        // of embed on large corpora.
                        try await extractGate.acquire()
                        let work = EmbedWork(
                            file: item.file,
                            label: item.label,
                            chunk: chunk,
                            ordinal: index,
                            totalChunks: chunks.count,
                            extractSeconds: extractSeconds,
                            firstChunkAt: firstChunkAt
                        )
                        embedContinuation.yield(work)
                    }
                    progress?(.extractDequeued)
                }
                // All files extracted; close the embed stream so the
                // embed-spawner stage knows it's done.
                embedContinuation.finish()
            }

            // Stage 1.5: Batch-former. Drains embedStream, length-buckets
            // by chunk.text.count / 500 (minimizes batchEncode padding
            // waste). Flush rules, in order:
            //   1. If any bucket hits batchSize, flush it (preferred: full
            //      batch = best pool utilization, minimal padding).
            //   2. Else, if total buffered items reaches batchSize, flush
            //      the largest bucket. Needed to guarantee forward
            //      progress — without this, pathological inputs where
            //      every few chunks go to a different bucket would stall
            //      extract behind its backpressure gate forever (no
            //      bucket ever reaches batchSize; stream-close never fires).
            //   3. On embed-stream close, flush every remaining partial
            //      bucket so the run finishes cleanly.
            // Rule 2 caps the amount of work sitting in buckets at
            // 2*batchSize − 1 worst case (totalBuffered hits batchSize
            // pre-flush, Rule 2 drops the largest bucket of ≥1 item) —
            // guarantees bounded memory under any input distribution.
            group.addTask {
                var buckets: [Int: [EmbedWork]] = [:]
                var totalBuffered = 0
                for await work in embedStream {
                    // Each loop iteration appends exactly one chunk, so at
                    // most one bucket's count increments per pass. Rule 1
                    // (full-bucket flush) and Rule 2 (largest-bucket flush)
                    // are mutually exclusive via `else if`, so at most one
                    // flush fires per iteration. This is what keeps the
                    // 2*batchSize − 1 worst-case `totalBuffered` bound.
                    let bucket = work.chunk.text.count / 500
                    buckets[bucket, default: []].append(work)
                    totalBuffered += 1
                    if buckets[bucket]!.count >= batchSize {
                        let flushed = buckets.removeValue(forKey: bucket)!
                        totalBuffered -= flushed.count
                        batchContinuation.yield(BatchWork(items: flushed))
                    } else if totalBuffered >= batchSize {
                        // No bucket has filled, but we've accumulated a
                        // batch's worth spread across buckets. Flush the
                        // largest bucket to keep the pool fed.
                        // Tie-break is Dictionary.max's unspecified order —
                        // non-deterministic across runs. Embeddings are
                        // unaffected (ordinals preserved); only the padding
                        // cost of the chosen batch varies, making wall-clock
                        // a slightly noisy signal on heterogeneous corpora.
                        if let (biggest, _) = buckets.max(by: { $0.value.count < $1.value.count }) {
                            let flushed = buckets.removeValue(forKey: biggest)!
                            totalBuffered -= flushed.count
                            batchContinuation.yield(BatchWork(items: flushed))
                        }
                    }
                }
                // Extract stream closed — flush remaining partial buckets.
                for (_, items) in buckets where !items.isEmpty {
                    batchContinuation.yield(BatchWork(items: items))
                }
                batchContinuation.finish()
            }

            // Stage 2: Embed-spawner. Drains the batch stream, spawns one
            // task per batch inside a TaskGroup. Each task acquires a
            // pooled embedder, calls `embedDocuments` on the whole batch,
            // then fans the result rows out as per-chunk events so the
            // accumulator stage and UI progress semantics are unchanged.
            group.addTask {
                // Throwing inner group: pool.acquire() and
                // extractGate.acquire() are now cancellation-aware and
                // can throw CancellationError when the outer group
                // unwinds (e.g. DB writer failure → throwingTaskGroup
                // cancels siblings). Propagating that throw here lets
                // the inner group tear down promptly instead of
                // dead-locking. The `defer` ensures the accumulator
                // stream is closed on both success and throw paths so
                // the accumulator stage can drain and exit cleanly.
                defer { accumContinuation.finish() }
                try await withThrowingTaskGroup(of: Void.self) { embedGroup in
                    for await batch in batchStream {
                        embedGroup.addTask {
                            let embedder = try await pool.acquire()
                            progress?(.poolAcquired)
                            let batchStart = DispatchTime.now()
                            let vectors: [[Float]]
                            do {
                                let texts = batch.items.map { $0.chunk.text }
                                vectors = try await embedder.embedDocuments(texts)
                            } catch is CancellationError {
                                // Cancellation: return the embedder and
                                // re-throw so the inner group tears down.
                                // Distinct from whole-batch model failure
                                // (caught below) — that one's a per-batch
                                // recoverable failure mode.
                                await pool.release(embedder)
                                throw CancellationError()
                            } catch {
                                // Whole-batch failure → every chunk in the
                                // batch gets a nil record. Per-item failure
                                // isolation via retry-with-single-calls is
                                // intentionally not implemented (would be a
                                // separate experiment).
                                vectors = Array(repeating: [], count: batch.items.count)
                            }
                            let batchSeconds = Self.elapsed(since: batchStart)
                            await pool.release(embedder)
                            progress?(.poolReleased)

                            // Amortize the batch-wall across chunks for
                            // the per-chunk progress event. Keeps the UI
                            // and stats collector's per-chunk view of
                            // "how much wall-clock per chunk" continuous
                            // with the pre-batch pipeline.
                            let perChunk = batchSeconds / Double(max(batch.items.count, 1))
                            for (work, vector) in zip(batch.items, vectors) {
                                progress?(.chunkEmbedded(seconds: perChunk))
                                await statsCollector.recordChunkEmbed(seconds: perChunk)

                                let chunk = work.chunk
                                let record: ChunkRecord?
                                if !vector.isEmpty {
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
                                    record = nil
                                }

                                let emitted = EmbeddedChunk(
                                    filePath: work.file.relativePath,
                                    ordinal: work.ordinal,
                                    record: record
                                )
                                // Release one gate permit per chunk, not
                                // per batch — extract acquires per-chunk.
                                await extractGate.release()
                                accumContinuation.yield(emitted)
                            }
                        }
                    }
                    // Explicit waitForAll to surface the first child
                    // throw. Without this, withThrowingTaskGroup's
                    // closure body never `try`s and the rethrows
                    // attribute fires no propagation — child errors
                    // get silently dropped at scope exit.
                    try await embedGroup.waitForAll()
                }
                // accumContinuation.finish() runs via the `defer`
                // above so it executes on both success and throw paths.
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
                    try await database.markFileIndexed(
                        path: path,
                        modifiedAt: work.file.modificationDate,
                        linePageCount: work.linePageCount
                    )
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

/// One unit of work flowing from extract → batch-former. Every `EmbedWork`
/// carries a real chunk — empty-file sentinels never traverse the embed
/// stream (the accumulator closes them out directly in extract).
struct EmbedWork: Sendable {
    let file: FileInfo
    let label: String
    let chunk: TextChunk
    let ordinal: Int
    let totalChunks: Int
    let extractSeconds: Double
    let firstChunkAt: DispatchTime?
}

/// A grouped batch of `EmbedWork`s produced by the batch-former. All items
/// share a length bucket (roughly similar tokenized length), which keeps
/// `batchEncode` padding waste low. Per-item ordinals are preserved; the
/// embed-spawner fans the returned vectors back out to the accumulator in
/// their original per-file order via `EmbeddedChunk.ordinal`.
struct BatchWork: Sendable {
    let items: [EmbedWork]
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
        var linePageCount: Int?
    }

    private var files: [String: PartialFile] = [:]

    func markFileTotal(
        path: String,
        file: FileInfo,
        label: String,
        total: Int,
        extractSeconds: Double,
        firstChunkAt: DispatchTime?,
        linePageCount: Int?
    ) {
        // First contact for this file. Extract is single-threaded so
        // markFileTotal always runs before any add() for the same file.
        files[path] = PartialFile(
            file: file,
            label: label,
            total: total,
            received: [],
            extractSeconds: extractSeconds,
            firstChunkAt: firstChunkAt,
            linePageCount: linePageCount
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
            totalChunksExtracted: partial.total,
            linePageCount: partial.linePageCount
        )
    }
}

// MARK: - Embedder Pool

/// Bounded pool of N embedder instances. Each call to `acquire()`
/// returns a unique, currently-idle instance; `release(_:)` either
/// hands the just-freed instance to the oldest waiter or marks it
/// idle. Enforces **one-worker-per-instance**: the pool MUST NOT
/// hand the same instance to two workers simultaneously, because
/// each embedder is an `actor` with its own mailbox and letting two
/// workers land on the same mailbox is exactly the single-instance
/// bottleneck this pool exists to eliminate.
///
/// Pattern mirrors `ExtractBackpressure` below — continuation-based
/// waiter queue — but the continuation generic is `any Embedder`
/// (not `Void`), so `release` can resume a waiter directly with the
/// specific instance that just became available. A "mark available,
/// let the waiter re-race for it" design is a correctness bug under
/// this invariant.
actor EmbedderPool {
    /// All N instances. Nonisolated because the slice is fixed at
    /// init and readable by `name`/`dimension` without a hop.
    private nonisolated let instances: [any Embedder]

    /// Indices into `instances` that are currently free. We pop the
    /// last element (LIFO) so the most-recently-used instance gets
    /// reused first — good for any internal caches the embedder may
    /// have warmed up.
    private var freeIndices: [Int]

    /// Waiters are resumed with the specific instance being handed
    /// off. Carrying the instance here (not a Void permit) is the
    /// invariant that makes one-worker-per-instance hold without a
    /// re-race window. Each waiter gets a monotonic id so the
    /// cancellation handler can locate and remove its own entry
    /// without racing other waiters.
    private struct WaiterEntry {
        let id: UInt64
        let continuation: CheckedContinuation<any Embedder, any Error>
    }
    private var waiters: [WaiterEntry] = []
    private var nextWaiterID: UInt64 = 0

    init(factory: @Sendable () -> any Embedder, count: Int) {
        precondition(count >= 1, "EmbedderPool requires count ≥ 1")
        var made: [any Embedder] = []
        made.reserveCapacity(count)
        for _ in 0..<count {
            made.append(factory())
        }
        self.instances = made
        self.freeIndices = Array(0..<count)
    }

    /// Acquire an embedder. **Cancellable.** If the surrounding task is
    /// cancelled while parked on the waiter list, the continuation is
    /// removed and resumed with `CancellationError` — the caller throws
    /// instead of holding a permit it would never release. The
    /// non-cancellable variant we shipped earlier deadlocked the entire
    /// `withThrowingTaskGroup` if any throwing sibling tripped: cancelled
    /// peers parked on `withCheckedContinuation` (Never-throwing) never
    /// woke up. See `e4-review-phase2-arch.md` finding B1.
    func acquire() async throws -> any Embedder {
        try Task.checkCancellation()
        if let idx = freeIndices.popLast() {
            return instances[idx]
        }
        // Mint the waiter id outside the continuation closure so the
        // cancellation handler below can capture exactly the entry this
        // call enqueued — not whichever happens to be at the tail when
        // cancellation arrives.
        let myID = nextWaiterID
        nextWaiterID &+= 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(WaiterEntry(id: myID, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: myID) }
        }
    }

    /// Removes the waiter with the given id (if still parked) and
    /// resumes it with `CancellationError`. Best-effort: if the waiter
    /// has already been resumed by `release` racing in first, the entry
    /// is no longer present and this is a no-op.
    private func cancelWaiter(id: UInt64) {
        guard let idx = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let entry = waiters.remove(at: idx)
        entry.continuation.resume(throwing: CancellationError())
    }

    func release(_ embedder: any Embedder) {
        // Locate the instance by identity — all instances came from
        // the factory at init so we can trust `ObjectIdentifier`
        // equality on class/actor references. **Caveat**: every current
        // conformer (BGE, Nomic, NL, NLContextual) is an `actor`, so the
        // `as AnyObject` bridge resolves to the same heap reference on
        // both sides of the comparison. A future `struct` conformer
        // would box on each cast and identity comparison would fail
        // silently, hanging acquire() waiters. If that ever changes,
        // tighten `Embedder` to `Embedder: AnyObject` (or use a UUID).
        guard let idx = instances.firstIndex(where: { ObjectIdentifier($0 as AnyObject) == ObjectIdentifier(embedder as AnyObject) }) else {
            // Programmer error: caller passed an instance that did not
            // come from this pool's factory. The only legitimate caller
            // (the embed-spawner) round-trips the exact reference from
            // acquire(), so this is unreachable today. assertionFailure
            // surfaces it in debug builds; the silent return preserves
            // release semantics in production rather than crashing.
            assertionFailure("EmbedderPool.release called with an instance that did not come from this pool")
            return
        }
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.continuation.resume(returning: instances[idx])
            return
        }
        freeIndices.append(idx)
    }

    /// Canonical embedder name/dimension. Every instance shares the
    /// same type and config, so the first is a safe exemplar.
    nonisolated var name: String { instances[0].name }
    nonisolated var dimension: Int { instances[0].dimension }

    /// Force-loads every instance's model serially — one `await` per
    /// instance completes before the next begins. Serial because:
    /// (a) the first run ever populates the HuggingFace on-disk
    /// cache, and N parallel cold loaders would all race to write
    /// the same files; (b) per-instance parallel cold-load
    /// contends for the same memory bandwidth and gains nothing.
    /// Swallows errors — a warmup failure will surface on the first
    /// real embed.
    ///
    /// **Per-embedder cost**: BGE/Nomic/NLContextual lazy-load on first
    /// call, so the warmup embed materializes the model bundle (the
    /// expensive thing). NLEmbedder loads at `init()`, so its warmup
    /// runs a real embed for no load-amortization benefit — small,
    /// but the `poolWarmed(seconds:)` event conflates the two cases.
    func warmAll() async {
        for instance in instances {
            do {
                _ = try await instance.embedDocument("warmup")
            } catch {
                // swallow — real embed will surface the failure
            }
        }
    }
}

// MARK: - Extract Backpressure

/// Counting semaphore used to gate the extract stage against the embed
/// stage. Extract acquires one permit per chunk before yielding; embed
/// releases one permit per chunk once the chunk has been handed off to the
/// accumulator. Sized to `workerCount * batchSize * 2` on init — large
/// enough that the batch-former always has ~2 batches' worth of chunks to
/// group (keeping the pool fed), small enough that extract blocks before
/// chunking a second huge file worth of text into memory. Pre-E4 the
/// sizing was `workerCount * 2` (one-chunk-per-acquire); the batched
/// pipeline multiplies by `batchSize` so the batch-former can fill its
/// per-bucket targets without starving extract.
///
/// **Cancellation note**: under cancellation cascade, an embed-spawner
/// child task may throw out of `pool.acquire` or `embedDocuments` before
/// reaching the per-chunk `extractGate.release()` loop. The remaining
/// chunks in that batch never get their permits returned. This is
/// acceptable in practice because each `IndexingPipeline.run(...)` call
/// builds a fresh `ExtractBackpressure` actor (the function exit reaps
/// the entire instance), so the leak does not persist across runs. If
/// the pipeline ever supports in-process restart without recreating the
/// gate, this needs a per-batch-acquire/release scheme (not per-chunk).
///
/// The old extract stage used an unbounded `AsyncStream` buffer, which on
/// large corpora let extract race ahead of embed by tens of thousands of
/// chunks — each carrying the chunk's text plus metadata. This actor
/// replaces that with a hard bound.
actor ExtractBackpressure {
    private let capacity: Int
    private var available: Int
    /// Per-waiter id so the cancellation handler can locate exactly the
    /// entry it parked. See `EmbedderPool.acquire` for the same shape.
    private struct WaiterEntry {
        let id: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }
    private var waiters: [WaiterEntry] = []
    private var nextWaiterID: UInt64 = 0

    init(capacity: Int) {
        self.capacity = capacity
        self.available = capacity
    }

    /// Block until a permit is available, then consume one.
    /// **Cancellable.** If the surrounding task is cancelled while
    /// parked, the continuation is removed and resumed with
    /// `CancellationError`. Caller throws and the gate's permit budget
    /// stays self-consistent (no permit was consumed). Without this,
    /// the throwing-task-group cancellation cascade from a DB writer
    /// failure would deadlock at `group.waitForAll()`. See
    /// `e4-review-phase2-arch.md` finding B1.
    func acquire() async throws {
        try Task.checkCancellation()
        if available > 0 {
            available -= 1
            return
        }
        let myID = nextWaiterID
        nextWaiterID &+= 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(WaiterEntry(id: myID, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: myID) }
        }
    }

    private func cancelWaiter(id: UInt64) {
        guard let idx = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let entry = waiters.remove(at: idx)
        entry.continuation.resume(throwing: CancellationError())
    }

    /// Return one permit. Resumes the oldest waiter if any.
    func release() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.continuation.resume()
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

    /// Record one per-chunk `Embedder.embedDocument()` call's wall-clock.
    /// Summed into `totalEmbedCallSeconds`, which is bounded by
    /// `wallSeconds * workerCount` and is the correct input for pool
    /// utilization.
    func recordChunkEmbed(seconds: Double) {
        stats.totalEmbedCallSeconds += seconds
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
