# Indexing Pipeline Plan

## Goal

Replace the sequential file-indexing loop in `UpdateIndexCommand` (and the similar logic in `InsertCommand`) with a two-stage producer/consumer pipeline that parallelizes chunking and embedding across CPU cores while keeping DB writes serial and crash-safe.

## Current Architecture

### Flow (sequential)

```
for each file:
    extract chunks (TextExtractor)           ← CPU + I/O (PDF, image OCR)
    unmark file in indexed_files             ← DB
    delete existing chunks                   ← DB
    for each batch of 20 chunks:
        embed sequentially (EmbeddingService) ← CPU bound
        insert batch to DB                    ← DB
    mark file in indexed_files               ← DB
```

### Key Constraints

1. **NLEmbedding thread safety**: The `EmbeddingService.swift` header comment states that `NLEmbedding` is "immutable after init and its `vector(for:)` method is safe to call from multiple threads." However, empirical testing during prior parallel-indexing work found that concurrent calls to `vector(for:)` on the **same** `NLEmbedding` instance cause segfaults in the underlying C++ runtime. The previous parallel implementation (removed in recent merge) used one `EmbeddingService` per concurrent task specifically to avoid this crash. **Action**: The header comment in `EmbeddingService.swift` is incorrect and must be updated during implementation to reflect the actual behavior: separate instances are safe, same-instance concurrent calls are not. Our design uses separate instances.

2. **Crash safety**: The `indexed_files` completion record must only be written after all chunks for a file succeed. The current sequence in `UpdateIndexCommand` is: `unmarkFileIndexed` → `removeEntries` → `insertBatch` (per batch) → `markFileIndexed`. Note: `removeEntries` (the public method) internally calls `unmarkFileIndexed` again, resulting in a harmless double-unmark. Our pipeline will use `replaceEntries` (atomic delete + insert in one transaction) to avoid this.

3. **VectorDatabase is an actor**: All DB calls serialize through the actor — no external locking needed, but only one operation runs at a time. This makes it a natural fit for a single DB writer consumer.

4. **TextExtractor is thread-safe**: All stored properties are immutable after init (`let`). Safe to share across concurrent tasks.

5. **EmbeddingService cost**: Each instance calls `NLEmbedding.sentenceEmbedding(for: .english)` on init, loading a ~50 MB model into memory. Creating and destroying instances per-batch would be prohibitively expensive. Instances must be pre-created and reused.

## Chosen Design

### Two-Stage Pipeline with Embedder Pool

```
[Work Queue (actor)] → [File Workers (N)] → [Save Stream] → [DB Writer (1)]
                             |
                    per-file: chunk extraction (sequential)
                    per-file: language warning (before embedding)
                    per-file: parallel embedding (inner TaskGroup)
                    per-file: collect all records
                    per-file: yield complete file to save stream
```

- **N** = `ProcessInfo.processInfo.activeProcessorCount` (minimum 2) — concurrent files in flight
- **Embedder pool** pre-creates N `EmbeddingService` instances at pipeline startup. The pool actor vends instances to embed tasks and accepts them back when done. At most N instances exist for the pipeline's lifetime. Peak memory: N x 50MB.

### Stage 1: File Workers

N concurrent tasks pull work items from a shared `WorkQueue` actor. For each file:

1. **Extract chunks** via `TextExtractor.extract(from:)` — sequential, I/O-bound
2. **Language warning** via `NLLanguageRecognizer.dominantLanguage(for:)` — called on the first chunk's text, before entering the TaskGroup. This is a type method (class method) that does not use `NLEmbedding`, so no concurrency concern. If non-English, a warning is emitted to stderr. This avoids the `inout Bool` / `@Sendable` closure incompatibility entirely.
3. **Parallel embedding** via inner `TaskGroup`:
   - All chunk batches are submitted to the TaskGroup
   - Each task: `pool.acquire()` → embed batch with the vended `EmbeddingService` → `pool.release(embedder)` → return `[ChunkRecord]`
   - The pool gates concurrency globally: at most N embed tasks run across all file workers
4. **Collect results** and yield a single `SaveWork` (complete file) to the save stream

### Stage 2: DB Writer

A single task consumes `SaveWork` items from an `AsyncStream`. For each file:

1. Call `unmarkFileIndexed(path:)` — remove completion record so crash during write triggers re-index
2. Call `replaceEntries(forPath:with:)` — atomic delete + insert in one transaction
3. Call `markFileIndexed(path:modifiedAt:)` — write completion record
4. Record the `IndexResult`

If a file produced zero successfully-embedded records, record `.skippedEmbedFailure` without touching the DB (preserving any existing data).

**Future improvement**: `unmarkFileIndexed` + `replaceEntries` + `markFileIndexed` could be combined into a single VectorDatabase method that runs all three in one transaction. For now, the three separate actor calls are correct — the actor serializes them, and the crash-safety analysis below accounts for crashes between calls.

### Work Distribution

`AsyncStream` is contractually a single-consumer type. Having multiple tasks iterate the same stream works in practice but is not guaranteed by the Swift specification. To distribute files safely across N workers, we use an actor-based work queue:

```swift
actor WorkQueue<T: Sendable> {
    private var items: IndexingIterator<[T]>

    init(_ items: [T]) {
        self.items = items.makeIterator()
    }

    func next() -> T? {
        items.next()
    }
}
```

Each worker calls `await queue.next()` in a loop. The actor serializes access, guaranteeing each item is delivered to exactly one worker.

The save stream (file workers → DB writer) uses a standard `AsyncStream` with a single consumer, which is the intended usage pattern.

### Embedder Pool

Instead of a bare semaphore that gates creation/destruction of `EmbeddingService` instances, we use a pool that pre-creates N instances at startup and vends them on demand:

```swift
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
```

This avoids the ~50MB model load/unload per batch. All N instances are created once at pipeline startup and reused throughout. Each `EmbeddingService` instance is used by only one task at a time (the pool guarantees exclusive access), so there is no concurrent `vector(for:)` call on the same instance.

**Cancellation safety**: Swift task cancellation is cooperative — it sets a flag but does not interrupt suspended code. A `CheckedContinuation` stored in `waiters` remains suspended until another task calls `release()`, which resumes it. Since each embed task calls `release()` in a `defer` block, every acquired embedder is always returned, ensuring waiting continuations are eventually resumed. The cancelled task receives the embedder, the `defer` returns it to the pool, and no instances leak. In the edge case where structured cancellation (e.g., parent `TaskGroup` cancellation) cancels all tasks simultaneously, tasks that have already acquired embedders will release them via `defer` as they unwind, which resumes any waiters.

**Concurrency tradeoff**: With N file workers and N pooled embedders, the effective parallelism depends on the workload:
- **Many small files**: Each worker holds ~1 embedder at a time. N files embed concurrently, each sequentially — equivalent to the simpler "one embedder per worker" design. This is fine because the bottleneck is distributed across many files.
- **Few large files**: Fewer workers are active, so remaining embedders are available for inner parallelism. A single 500-chunk file can use all N embedders, embedding N batches concurrently.

This is the correct adaptive behavior — the pool automatically allocates embedding capacity where it's needed.

## Types

```swift
// Public — in IndexingPipeline.swift
public enum IndexResult: Sendable {
    case indexed(filePath: String, wasUpdate: Bool)
    case skippedUnreadable(filePath: String)
    case skippedEmbedFailure(filePath: String)
}

public final class IndexingPipeline: Sendable {
    private let embedBatchSize: Int
    private let workerCount: Int
    private let pool: EmbedderPool

    public init(embedBatchSize: Int = 20, concurrency: Int = ...)

    public func run(
        workItems: [(file: FileInfo, label: String)],
        extractor: TextExtractor,
        database: VectorDatabase,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> [IndexResult]
}

// Internal
struct SaveWork: Sendable {
    let file: FileInfo
    let label: String
    let records: [ChunkRecord]
    let totalChunks: Int
}

actor WorkQueue<T: Sendable> { ... }
actor EmbedderPool { ... }
```

**Sendable correctness**: `IndexingPipeline` is `Sendable` because all stored properties are `let` and themselves `Sendable` (`Int` is `Sendable`; `EmbedderPool` is an actor, which is `Sendable`). The `progress` callback is passed as a parameter to `run()` rather than stored as mutable state.

**IndexResult includes file identity**: Each case carries the `filePath` so callers can determine which files were added, updated, skipped, or failed.

## Files Changed

| File | Change |
|------|--------|
| `Sources/VecKit/IndexingPipeline.swift` | **New** — `IndexingPipeline`, `IndexResult`, `SaveWork`, `WorkQueue`, `EmbedderPool` |
| `Sources/VecKit/EmbeddingService.swift` | **Fix header comment** — update thread-safety docs to reflect that concurrent calls on the same instance are unsafe |
| `Sources/vec/Commands/UpdateIndexCommand.swift` | Replace sequential loop with `IndexingPipeline.run()` |
| `Sources/vec/Commands/InsertCommand.swift` | Replace sequential embed loop with `IndexingPipeline.run()` for single-file case |

## Crash Safety

Each file's DB write goes through: `unmarkFileIndexed` → `replaceEntries` → `markFileIndexed`. These are three separate actor calls (serialized by the actor). If the process is interrupted:

- **Mid-chunking/embedding**: No DB changes yet for this file. For new files, there's no completion record — the file will be indexed on next run. For updated files, the old completion record has the old timestamp — the newer file mod date will trigger re-indexing on next run.
- **After unmarkFileIndexed, before replaceEntries**: Completion record is removed. Old chunks still exist. On restart, file appears un-indexed (no completion record), so it will be re-indexed. The old chunks get replaced.
- **After replaceEntries, before markFileIndexed**: New chunks are written but completion record is missing. File will be re-indexed on next run, which will replace the chunks again. No data corruption.
- **After markFileIndexed**: File is fully indexed. No rework needed.

**Tradeoff vs. current design**: The current sequential design flushes batches to DB incrementally as they're embedded. Our pipeline buffers all chunks for a file in memory before writing. This means a crash mid-embedding loses more in-progress work (all chunks for that file vs. just the current batch). However, since the existing crash-safety model already re-indexes the entire file in both cases (the completion record is missing either way), the practical impact is identical — the same file gets re-indexed on restart. The benefit is a simpler, atomic DB write.

## Memory Budget

- **EmbeddingService instances**: N (pool size) x ~50MB = N x 50MB — created once at startup, reused
- **Chunks in memory**: At most N files' chunks simultaneously. Each file's chunks are released after embedding completes.
- **Save stream**: At most N `SaveWork` items buffered (one per file worker). Each contains `[ChunkRecord]` for one file.
- **Example (8-core machine)**: ~400MB for embedders + variable chunk/record data

## Edge Cases

1. **Single-chunk file**: Inner TaskGroup has one task. Embedder acquired from pool and released quickly. No overhead vs. sequential.
2. **Very large file (1000+ chunks)**: 50+ batches. Inner TaskGroup submits all, pool gates them N-at-a-time. Other file workers may pause while waiting for embedders — this is correct behavior, preventing memory explosion.
3. **Embed failure (`vector` returns nil)**: Chunk is skipped. If all chunks fail, file result is `.skippedEmbedFailure`. Existing DB data is preserved (no DB calls made for this file).
4. **Non-English content**: Language is detected via `NLLanguageRecognizer.dominantLanguage(for:)` on the first chunk *before* entering the TaskGroup. This is a type method that does not use `NLEmbedding` and has no concurrency constraints. At most one warning per file.
5. **Empty work list**: `run()` returns `[]` immediately.
6. **Task cancellation**: Pool continuations are always resumed. Cancelled tasks receive an embedder, release it via `defer`, and the embedder returns to the pool. No leaked instances or deadlocks.

## Alternatives Considered

1. **Three-stage pipeline** (separate chunker pool → embedder pool → writer): Correctly parallelizes chunking and embedding independently, but introduces complex ordering problems — the DB writer must know when all batches for a file have arrived. Sentinel-based and batch-counting approaches both have race conditions when multiple embedder workers process batches from the same file. Rejected in favor of the simpler two-stage design where each file is fully processed before being sent to the writer.

2. **One embedder per file worker, no inner parallelism**: N workers each own one `EmbeddingService`, embed chunks sequentially. Simple and correct, but doesn't parallelize within a single large file. The pool-gated inner TaskGroup achieves the same behavior for many-files workloads and adds inner parallelism for few-files workloads.

3. **AsyncChannel from swift-async-algorithms**: Would provide proper multi-consumer distribution, but adds an external dependency. The actor-based `WorkQueue` achieves the same result with no dependencies.

4. **Semaphore (permits only) instead of pool**: A semaphore gates concurrency but doesn't manage instances. Each embed task would create and destroy an `EmbeddingService` (~50MB model load per batch). With a pool, instances are created once at startup and reused, avoiding the repeated model load/unload overhead.

## Testing

- Existing `VecKitTests` and `IntegrationTests` verify end-to-end indexing behavior
- `CLITests` verify CLI output format
- No new test file needed if existing tests continue to pass
- Manual verification: run `vec update-index -v` on a real directory and compare output/timing with the sequential version
