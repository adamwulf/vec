import Foundation
import NaturalLanguage

/// Result of indexing a single file.
public enum IndexResult: Sendable {
    case indexed(filePath: String, wasUpdate: Bool, chunkCount: Int)
    case skippedUnreadable(filePath: String)
    case skippedEmbedFailure(filePath: String)
}

/// Structured progress event emitted by the pipeline. Consumers are expected to
/// maintain their own counters; the pipeline carries no presentation concerns.
public enum ProgressEvent: Sendable {
    case fileFinished(chunks: Int)
    case fileSkipped
    case nonEnglishDetected
    case chunksEmbedded(count: Int)
}

public typealias ProgressHandler = @Sendable (ProgressEvent) -> Void

/// A batch of embedded records for a complete file, ready for DB insertion.
struct SaveWork: Sendable {
    let file: FileInfo
    let label: String
    let records: [ChunkRecord]
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

    /// Number of concurrent file workers.
    private let workerCount: Int

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
    ) async throws -> [IndexResult] {
        guard !workItems.isEmpty else { return [] }

        let batchSize = embedBatchSize
        let pool = self.pool

        // Save stream: file workers → DB writer (single consumer)
        let (saveStream, saveContinuation) = AsyncStream<SaveWork>.makeStream(
            bufferingPolicy: .unbounded
        )

        let resultCollector = ResultCollector()

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
                                    progress: progress
                                )

                                switch result {
                                case .skipped(let indexResult):
                                    await resultCollector.record(indexResult)
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
                        progress?(.fileSkipped)
                        continue
                    }

                    // Crash-safe: unmark → replace (atomic delete+insert) → mark
                    try await database.unmarkFileIndexed(path: path)
                    try await database.replaceEntries(forPath: path, with: work.records)
                    try await database.markFileIndexed(path: path, modifiedAt: work.file.modificationDate)

                    let wasUpdate = work.label == "Updated"
                    await resultCollector.record(.indexed(filePath: path, wasUpdate: wasUpdate, chunkCount: work.records.count))
                    progress?(.fileFinished(chunks: work.records.count))
                }
            }

            try await group.waitForAll()
        }

        return await resultCollector.allResults()
    }

    // MARK: - Per-file Processing

    private enum FileProcessResult: Sendable {
        case skipped(IndexResult)
        case save(SaveWork)
    }

    /// Process a single file: extract chunks, check language, embed in parallel, return results.
    private static func processFile(
        _ file: FileInfo,
        label: String,
        extractor: TextExtractor,
        pool: EmbedderPool,
        batchSize: Int,
        progress: ProgressHandler?
    ) async -> FileProcessResult {
        // Extract chunks
        let chunks: [TextChunk]
        do {
            chunks = try extractor.extract(from: file)
        } catch {
            progress?(.fileSkipped)
            return .skipped(.skippedUnreadable(filePath: file.relativePath))
        }

        if chunks.isEmpty {
            progress?(.fileSkipped)
            return .skipped(.skippedUnreadable(filePath: file.relativePath))
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
        let allRecords: [[ChunkRecord]] = await withTaskGroup(of: (Int, [ChunkRecord]).self) { group in
            for (index, batch) in batches.enumerated() {
                group.addTask {
                    let embedder = await pool.acquire()
                    // Swift doesn't allow `await` in `defer`, so we use an
                    // unstructured Task to return the embedder to the pool.
                    // The release runs shortly after the closure exits —
                    // safe because every acquire path has a matching release.
                    defer { Task { await pool.release(embedder) } }

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
                    if !records.isEmpty {
                        progress?(.chunksEmbedded(count: records.count))
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

        let records = allRecords.flatMap { $0 }

        return .save(SaveWork(
            file: file,
            label: label,
            records: records
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
