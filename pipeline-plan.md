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

1. **NLEmbedding thread safety**: `NLEmbedding.vector(for:)` is **not safe** to call concurrently on the *same* instance — it causes a segfault in the underlying C++ runtime. However, **separate instances** each own an independent model and can run in parallel safely. This is documented in the `EmbeddingService` header comment and was empirically verified when the codebase previously used parallel file workers. Each instance costs ~50 MB resident memory.

2. **Crash safety**: The `indexed_files` completion record must only be written after all chunks for a file succeed. The current sequence in `UpdateIndexCommand` is: `unmarkFileIndexed` → `removeEntries` → `insertBatch` (per batch) → `markFileIndexed`. Note: `removeEntries` (the public method) internally calls `unmarkFileIndexed` again, resulting in a harmless double-unmark. Our pipeline will use `replaceEntries` (atomic delete + insert in one transaction) to avoid this.

3. **VectorDatabase is an actor**: All DB calls serialize through the actor — no external locking needed, but only one operation runs at a time. This makes it a natural fit for a single DB writer consumer.

4. **TextExtractor is thread-safe**: All stored properties are immutable after init (`let`). Safe to share across concurrent tasks.

5. **EmbeddingService is `@unchecked Sendable`**: The underlying `NLEmbedding` is immutable after init, so each instance is internally thread-safe. But concurrent calls to `vector(for:)` on the **same** instance crash. Each concurrent embed task needs its own instance.

## Chosen Design

### Two-Stage Pipeline with Global Embed Semaphore

```
[Work Queue (actor)] → [File Workers (N)] → [Save Stream] → [DB Writer (1)]
                             |
                    per-file: chunk extraction (sequential)
                    per-file: parallel embedding (inner TaskGroup)
                    per-file: language warning (before embedding)
                    per-file: collect all records
                    per-file: yield complete file to save stream
```

- **N** = `ProcessInfo.processInfo.activeProcessorCount` (minimum 2) — concurrent files in flight
- **Global embed semaphore** limits total concurrent `EmbeddingService` instances to N across all file workers. Peak memory: N x 50MB.

### Stage 1: File Workers

N concurrent tasks pull work items from a shared `WorkQueue` actor. For each file:

1. **Extract chunks** via `TextExtractor.extract(from:)` — sequential, I/O-bound
2. **Language warning** via `EmbeddingService.warnIfNonEnglish` — called once on the first chunk, before entering the TaskGroup. This avoids the `inout Bool` / `@Sendable` closure incompatibility.
3. **Parallel embedding** via inner `TaskGroup`:
   - All chunk batches are submitted to the TaskGroup
   - Each task: `semaphore.acquire()` → create `EmbeddingService` → embed batch → `semaphore.release()` → return `[ChunkRecord]`
   - The semaphore gates concurrency globally: at most N embed tasks run across all file workers
4. **Collect results** and yield a single `SaveWork` (complete file) to the save stream

### Stage 2: DB Writer

A single task consumes `SaveWork` items from an `AsyncStream`. For each file:

1. Call `replaceEntries(forPath:with:)` — atomic delete + insert in one transaction
2. Call `markFileIndexed(path:modifiedAt:)` — write completion record
3. Record the `IndexResult`

If a file produced zero successfully-embedded records, record `.skippedEmbedFailure` without touching the DB (preserving any existing data).

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

### Global Embed Semaphore

```swift
actor EmbedSemaphore {
    private let limit: Int
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
        self.available = limit
    }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            available += 1
        }
    }
}
```

**Cancellation safety**: If a task is cancelled while waiting in `acquire()`, the `CheckedContinuation` will still be resumed (continuations must be resumed exactly once). The cancelled task will proceed briefly, create and immediately discard the embedder, and release the permit. This is safe but wastes a small amount of work. For the typical workload (indexing local files), task cancellation is rare (only process termination), so this tradeoff is acceptable.

**Concurrency tradeoff**: With N file workers and N global permits, the effective parallelism depends on the workload:
- **Many small files**: Each worker holds ~1 permit at a time. N files embed concurrently, each sequentially — equivalent to the simpler "one embedder per worker" design. This is fine because the bottleneck is distributed across many files.
- **Few large files**: Fewer workers are active, so remaining permits are available for inner parallelism. A single 500-chunk file can use all N permits, embedding N batches concurrently.

This is the correct adaptive behavior — the semaphore automatically allocates embedding capacity where it's needed.

## Types

```swift
// Public — in IndexingPipeline.swift
public enum IndexResult: Sendable {
    case indexed(filePath: String, wasUpdate: Bool)
    case skippedUnreadable(filePath: String)
    case skippedEmbedFailure(filePath: String)
}

public final class IndexingPipeline: @unchecked Sendable {
    private let embedBatchSize: Int
    private let workerCount: Int
    private let semaphore: EmbedSemaphore

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
actor EmbedSemaphore { ... }
```

**Sendable correctness**: `IndexingPipeline` is marked `@unchecked Sendable` because all stored properties are `let` (immutable after init). The `progressHandler` is passed as a parameter to `run()` instead of stored as mutable state, avoiding the Sendable violation. Alternatively, we could make it a plain `Sendable` class since all properties are `let` — the `@unchecked` is only needed if we later add mutable state (e.g., metrics).

**IndexResult includes file identity**: Each case carries the `filePath` so callers can determine which files were added, updated, skipped, or failed.

## Files Changed

| File | Change |
|------|--------|
| `Sources/VecKit/IndexingPipeline.swift` | **New** — `IndexingPipeline`, `IndexResult`, `SaveWork`, `WorkQueue`, `EmbedSemaphore` |
| `Sources/vec/Commands/UpdateIndexCommand.swift` | Replace sequential loop with `IndexingPipeline.run()` |
| `Sources/vec/Commands/InsertCommand.swift` | Replace sequential embed loop with `IndexingPipeline.run()` for single-file case |

## Crash Safety

Each file's DB write is atomic via `replaceEntries` (single transaction for delete + insert) followed by `markFileIndexed`. If the process is interrupted:

- **Mid-chunking/embedding**: No DB changes yet for this file. Existing data (if any) is untouched. File will be re-indexed on next run because the completion record is unchanged (for new files) or already removed (for updates — we call `unmarkFileIndexed` before starting embedding).
- **After replaceEntries, before markFileIndexed**: Chunks are written but completion record is missing. File will be re-indexed on next run, which will replace the chunks again. No data corruption.
- **After markFileIndexed**: File is fully indexed. No rework needed.

**Tradeoff vs. current design**: The current sequential design flushes batches to DB incrementally as they're embedded. Our pipeline buffers all chunks for a file in memory before writing. This means a crash mid-embedding loses more in-progress work (all chunks for that file, not just the current batch). However, since the existing crash-safety model already re-indexes the entire file in both cases (the completion record is missing either way), the practical impact is identical — the same file gets re-indexed on restart. The benefit is a simpler, atomic DB write.

## Memory Budget

- **EmbeddingService instances**: N (semaphore-capped) x ~50MB = N x 50MB
- **Chunks in memory**: At most N files' chunks simultaneously. Each file's chunks are released after embedding completes.
- **Save stream**: At most N `SaveWork` items buffered (one per file worker). Each contains `[ChunkRecord]` for one file.
- **Example (8-core machine)**: ~400MB for embedders + variable chunk/record data

## Edge Cases

1. **Single-chunk file**: Inner TaskGroup has one task. Semaphore acquired and released quickly. No overhead vs. sequential.
2. **Very large file (1000+ chunks)**: 50+ batches. Inner TaskGroup submits all, semaphore gates them N-at-a-time. Other file workers may pause while waiting for permits — this is correct behavior, preventing memory explosion.
3. **Embed failure (`vector` returns nil)**: Chunk is skipped. If all chunks fail, file result is `.skippedEmbedFailure`. Existing DB data is preserved (no `replaceEntries` call made).
4. **Non-English content**: `warnIfNonEnglish` is called once per file on the first chunk *before* entering the TaskGroup. This avoids `inout Bool` across `@Sendable` boundaries. At most one warning per file.
5. **Empty work list**: `run()` returns `[]` immediately.
6. **Task cancellation**: Semaphore continuations are always resumed. Cancelled tasks proceed briefly and release permits. No leaked permits or deadlocks.

## Alternatives Considered

1. **Three-stage pipeline** (separate chunker pool → embedder pool → writer): Correctly parallelizes chunking and embedding independently, but introduces complex ordering problems — the DB writer must know when all batches for a file have arrived. Sentinel-based and batch-counting approaches both have race conditions when multiple embedder workers process batches from the same file. Rejected in favor of the simpler two-stage design where each file is fully processed before being sent to the writer.

2. **One embedder per file worker, no inner parallelism**: N workers each own one `EmbeddingService`, embed chunks sequentially. Simple and correct, but doesn't parallelize within a single large file. The semaphore-gated inner TaskGroup achieves the same behavior for many-files workloads and adds inner parallelism for few-files workloads.

3. **AsyncChannel from swift-async-algorithms**: Would provide proper multi-consumer distribution, but adds an external dependency. The actor-based `WorkQueue` achieves the same result with no dependencies.

## Testing

- Existing `VecKitTests` and `IntegrationTests` verify end-to-end indexing behavior
- `CLITests` verify CLI output format
- No new test file needed if existing tests continue to pass
- Manual verification: run `vec update-index -v` on a real directory and compare output/timing with the sequential version
