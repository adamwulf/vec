# Indexing Pipeline Plan

## Goal

Replace the sequential file-indexing loop in `UpdateIndexCommand` (and the similar logic in `InsertCommand`) with a three-stage producer/consumer pipeline that parallelizes work across CPU cores while keeping embedding services isolated and DB writes serial.

## Current Architecture

### Flow (sequential)

```
for each file:
    extract chunks (TextExtractor)       ← CPU + I/O (PDF, image OCR)
    for each batch of 20 chunks:
        embed sequentially (EmbeddingService) ← CPU bound (~50ms per chunk)
        flush batch to DB                     ← I/O bound (SQLite)
    mark file as indexed
```

### Key Constraints

1. **NLEmbedding thread safety**: `NLEmbedding.vector(for:)` segfaults when called concurrently on the *same* instance. Separate instances are safe. Each instance costs ~50 MB resident memory.

2. **Crash safety**: The `indexed_files` completion record must only be written after all chunks for a file succeed. The sequence is: `unmarkFileIndexed` → `removeEntries` → `insertBatch` → `markFileIndexed`. If interrupted mid-file, the missing completion record triggers re-indexing on the next run.

3. **VectorDatabase is an actor**: All DB calls serialize through the actor — no external locking needed, but only one operation runs at a time.

4. **TextExtractor is thread-safe**: Immutable after init, safe to share across tasks.

5. **EmbeddingService is thread-safe per-instance**: The class is `@unchecked Sendable` because `NLEmbedding` is immutable after init, but concurrent calls on the same instance crash. Each concurrent worker needs its own instance.

## Proposed Architecture

### Three-Stage Pipeline

```
[File Queue] → [Chunker Pool] → [Embedder Pool] → [DB Writer]
                  N workers         N workers        1 worker
```

Where N = `ProcessInfo.processInfo.activeProcessorCount` (minimum 2).

### Stage 1: Chunkers

**Input**: `(FileInfo, label: String)` work items from a shared `AsyncStream`.

**Work**: Call `TextExtractor.extract(from:)` to produce `[TextChunk]`. Split chunks into batches of `embedBatchSize` (default 20).

**Output**: For each file:
- Zero or more `.chunks(file, label, chunkBatch, totalChunksInFile)` items
- One `.fileComplete(filePath)` sentinel after all chunk batches are enqueued
- Or one `.skipped(filePath, result)` if the file is unreadable/empty

**Concurrency**: N workers pulling from a shared file stream. This parallelizes the I/O-heavy work (reading files, PDF extraction, image OCR).

### Stage 2: Embedders

**Input**: `EmbedItem` enum from the chunker stage's `AsyncStream`.

**Work**: Each worker creates its own `EmbeddingService` instance. For `.chunks` items, embed each chunk and produce `ChunkRecord`s. Pass-through `.fileComplete` and `.skipped` sentinels unchanged.

**Output**: `SaveItem` enum:
- `.records(file, label, records, totalChunksInFile)` — embedded chunk records
- `.fileComplete(filePath)` — sentinel indicating all batches for this file have been processed
- `.skipped(filePath, result)` — pass-through from chunker

**Concurrency**: N workers, each with its own `EmbeddingService`. Since `AsyncStream` distributes items to whichever consumer calls `next()` first, different batches from the same file may be processed by different embedders — this is fine since each embedder owns its own NLEmbedding instance.

**Important ordering property**: The `.fileComplete` sentinel for a file is yielded by the chunker *after* all `.chunks` items for that file. Since `AsyncStream` preserves FIFO order, an embedder will only see `.fileComplete` after all `.chunks` items for that file have been *dequeued* (though possibly not yet *processed* by other embedders). However, since the sentinel is consumed by a single embedder worker and immediately forwarded, there's a race: other embedders may still be processing chunk batches for that file when the sentinel arrives at the DB writer.

**Fix**: The embedder that receives `.fileComplete` must wait until all prior `.chunks` items for that file have been processed. We accomplish this by tracking batch counts: the chunker records how many batches it sent for each file, and the DB writer counts received `.records` items per file. The `.fileComplete` sentinel tells the writer "no more batches are coming" — the writer waits until received count matches expected count before flushing.

Actually, a simpler approach: since `AsyncStream` is single-consumer by specification (iterating the same `AsyncStream` from multiple tasks is not guaranteed to distribute items), we need a different distribution mechanism. We'll use `AsyncStream` as the channel and have each worker iterate it — in practice with the current Swift runtime this does distribute items across consumers, but it's not contractually guaranteed.

### Revised approach: Per-file TaskGroup in embedders

A cleaner alternative that avoids the ordering problem:

```
[File Queue] → [Worker Pool] → [DB Writer]
                 N workers        1 worker
```

Each worker:
1. Pulls a file from the queue
2. Extracts chunks (chunking)
3. Splits into batches, embeds each batch (using its own EmbeddingService)
4. Sends all records + completion to the DB writer stream

This is simpler because each file is fully processed by a single worker — no cross-worker ordering issues. The parallelism comes from multiple files being processed concurrently by different workers.

**But**: This doesn't parallelize chunk embedding *within* a single file. A large file with 500 chunks would still be embedded sequentially by one worker. The user specifically asked about parallelizing chunks within a file.

### Revised approach: Two-stage with inner parallelism

```
[File Queue] → [File Workers] → [DB Writer]
                 N workers          1 worker
                    |
              [Inner Embed Pool]
               per-file TaskGroup
```

Each file worker:
1. Pulls a file from the queue
2. Extracts chunks
3. Uses an inner `TaskGroup` to embed chunks in parallel, each task creating its own `EmbeddingService`
4. Collects all records
5. Sends the complete set of records to the DB writer

The DB writer:
1. Receives `(file, label, records)` — always a complete file's worth
2. Does the atomic unmark → delete → insert → mark sequence
3. No need to track batches or sentinels

**Pros**:
- Simple ordering: each file's records arrive as a single complete batch
- Parallelism at both levels: multiple files in flight AND chunks within each file embedded concurrently
- No sentinel/tracking complexity
- Natural backpressure: the file worker blocks until all its chunks are embedded before pulling the next file

**Cons**:
- Inner parallelism spawns embedders per-file, which allocates/deallocates NLEmbedding instances. However, TaskGroup tasks reuse the cooperative thread pool, so the actual concurrency is bounded by the Swift runtime.
- Memory: A file with 500 chunks could spawn 500 embed tasks. Each creates an EmbeddingService (~50MB). Need an inner concurrency cap.

### Final Design: Two-stage pipeline with capped inner parallelism

```
[File Queue] → [File Workers (N)] → [DB Writer (1)]
                     |
              [Embed tasks, capped at N per file]
```

**Implementation**:

#### New file: `Sources/VecKit/IndexingPipeline.swift`

```swift
public final class IndexingPipeline: Sendable {
    let embedBatchSize: Int     // chunks per embed unit (default 20)
    let workerCount: Int        // concurrent file workers (default: core count)
    let embedConcurrency: Int   // max concurrent embed tasks per file (default: core count)
    var progressHandler: (@Sendable (String) -> Void)?
}
```

#### `IndexResult` enum (public, in VecKit)

```swift
public enum IndexResult: Sendable {
    case indexed(wasUpdate: Bool)
    case skippedUnreadable
    case skippedEmbedFailure
}
```

#### Pipeline stages

**File distribution**: An `AsyncStream<WorkItem>` feeds file workers. A producer task enqueues all work items, then finishes the stream. N worker tasks iterate the stream concurrently — each pulls one file at a time.

**Chunk embedding** (inside each file worker): A `TaskGroup` with a capped-iterator pattern (same pattern previously used in `UpdateIndexCommand` for file-level parallelism). Seed the group with up to `embedConcurrency` tasks, then as each completes, start the next. Each task gets its own `EmbeddingService` and embeds one batch of chunks.

**DB writing**: A single `AsyncStream<SaveWork>` carries complete file results from workers to the writer. Each `SaveWork` contains all records for one file. The writer does the atomic DB sequence.

#### SaveWork type

```swift
struct SaveWork: Sendable {
    let file: FileInfo
    let label: String
    let records: [ChunkRecord]  // all records for this file
    let totalChunks: Int        // for progress reporting
}
```

#### Concurrency budget

- File workers: N (core count, min 2)
- Embed tasks per file: N (core count, min 2)
- Total EmbeddingService instances alive at peak: N files x N embed tasks = N^2
- Memory at peak: N^2 x 50MB. On an 8-core machine: 64 x 50MB = 3.2 GB

This is too much. We need a global concurrency limit for embed tasks, not per-file.

**Better approach**: Use a shared semaphore (actor-based) to cap total concurrent embed tasks globally at N. Each file worker's inner TaskGroup tasks acquire a permit before creating an EmbeddingService and release it when done. This way at most N EmbeddingService instances exist at any time, regardless of how many files are in flight.

But this gets complex. Simpler alternative:

**Simplest correct design**: N file workers, each owns ONE EmbeddingService. Within a file, chunks are embedded sequentially by that worker's embedder. Parallelism comes from N files being processed simultaneously. This matches the original parallel design but with a clean pipeline to the DB writer.

This is what the codebase had before the recent merge made it sequential! The user wants more: parallel chunk embedding within a file.

**Practical design**: Since the main bottleneck is embedding (CPU-bound), and we want at most N embedders alive for memory, let's use the original three-stage design but handle ordering correctly:

```
[File Queue] → [Chunker Pool (N)] → [Embedder Pool (N)] → [DB Writer (1)]
```

The chunker pool produces chunk batches. The embedder pool processes them. The DB writer accumulates records per-file and flushes when complete.

**Ordering solution**: Each file generates a known number of chunk batches. The chunker sends this count to the DB writer directly (via the save stream as metadata). The DB writer counts received record batches per file and flushes when the count matches.

```
Chunker sends:
  .fileMeta(path, label, file, totalBatches)  ← first, before any chunks
  .chunks(file, label, batch, ...)             ← N batches
  
Embedder forwards .fileMeta unchanged, converts .chunks → .records

DB Writer:
  on .fileMeta: register expected batch count
  on .records: accumulate, increment received count
  when received == expected: flush to DB
```

This avoids the ordering race because `.fileMeta` is sent *before* any `.chunks` items for that file in the stream. Even if an embedder processes the `.fileMeta` and another embedder processes chunk batches, the DB writer sees `.fileMeta` first (FIFO within the single save stream from each embedder, and `.fileMeta` is sent before `.chunks` by the same chunker task for a given file).

Wait — the save stream receives items from *multiple* embedder tasks. There's no global ordering guarantee. An embedder processing `.fileMeta` might yield to the save stream *after* another embedder yields `.records` for the same file if the chunks were already in the embed stream when the meta was enqueued.

Actually, this can't happen: for a given file, the chunker sends `.fileMeta` first, then `.chunks`. The `.fileMeta` must be dequeued from the embed stream before (or at the same time as) the `.chunks`. An embedder that gets `.fileMeta` forwards it to the save stream. An embedder that gets a `.chunks` item processes it and sends `.records`. But the `.chunks` item was enqueued *after* `.fileMeta`, so it's dequeued after `.fileMeta`. The embedder processing `.chunks` can only start after `.fileMeta` has been dequeued. But the embedder that dequeued `.fileMeta` may not have yielded to the save stream yet...

This ordering analysis is getting circular. Let's use the simplest correct approach.

## Final Design (chosen)

### Architecture

```
[File Queue] → [File Workers (N)] → [Save Stream] → [DB Writer (1)]
                     |
              sequential chunking
              parallel embedding (inner TaskGroup, capped at M)
              collect all records
              yield complete file to save stream
```

- **N** = active processor count (min 2) — concurrent files in flight
- **M** = embed concurrency cap per file — use a shared actor-based semaphore to limit total concurrent EmbeddingService instances across all file workers to N

### Shared Embed Semaphore

```swift
actor EmbedSemaphore {
    private let limit: Int
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    
    func acquire() async { ... }
    func release() { ... }
}
```

Each embed task: `acquire()` → create EmbeddingService → embed batch → `release()`. At most N EmbeddingService instances alive at any time. Peak memory: N x 50MB (e.g., 8 cores = 400MB).

### Pipeline Flow

1. **File distribution**: Producer enqueues all `(FileInfo, label)` items into an `AsyncStream`. N worker tasks pull from it.

2. **Per-file processing** (in each worker):
   - Extract chunks via `TextExtractor`
   - Split into batches of `embedBatchSize`
   - Use `TaskGroup` with capped-iterator pattern: seed with up to M tasks (acquiring semaphore), as each completes start the next
   - Each task: acquire semaphore → create `EmbeddingService` → embed batch → release semaphore → return `[ChunkRecord]`
   - Collect all records from the TaskGroup
   - Yield `SaveWork(file, label, allRecords, totalChunks)` to save stream

3. **DB Writer** (single task consuming save stream):
   - Receive complete `SaveWork` items (one per file, all records included)
   - Execute crash-safe sequence: `unmarkFileIndexed` → `removeEntries` → `insertBatch` → `markFileIndexed`
   - Record result

### Files Changed

| File | Change |
|------|--------|
| `Sources/VecKit/IndexingPipeline.swift` | **New** — `IndexingPipeline`, `IndexResult`, `SaveWork`, `EmbedSemaphore` |
| `Sources/vec/Commands/UpdateIndexCommand.swift` | Replace sequential loop with `IndexingPipeline.run()` |
| `Sources/vec/Commands/InsertCommand.swift` | Replace sequential loop with `IndexingPipeline.run()` for single-file case |

### Types

```swift
// Public
public enum IndexResult: Sendable {
    case indexed(wasUpdate: Bool)
    case skippedUnreadable
    case skippedEmbedFailure
}

public final class IndexingPipeline: Sendable {
    public var progressHandler: (@Sendable (String) -> Void)?
    public init(embedBatchSize: Int = 20, concurrency: Int = ...)
    public func run(
        workItems: [(file: FileInfo, label: String)],
        extractor: TextExtractor,
        database: VectorDatabase
    ) async throws -> [IndexResult]
}

// Internal
struct SaveWork: Sendable {
    let file: FileInfo
    let label: String
    let records: [ChunkRecord]
    let totalChunks: Int
}

actor EmbedSemaphore {
    init(limit: Int)
    func acquire() async
    func release()
}
```

### Crash Safety

Unchanged from current design. Each file goes through the full `unmark → delete → insert → mark` sequence atomically in the DB writer. If the process is interrupted:
- Mid-chunking/embedding: No DB changes yet. File will be re-indexed.
- Mid-DB-write (after unmark, before mark): Completion record is missing. File will be re-indexed.
- After mark: File is fully indexed. No rework needed.

### Memory Budget

- N EmbeddingService instances (semaphore-capped): N x 50MB
- N files' chunks in memory: varies, but each file's chunks are released after embedding
- Save stream buffer: at most N complete files' ChunkRecords waiting for DB write
- On an 8-core machine: ~400MB for embedders + chunk/record data

### Edge Cases

1. **Single-chunk file**: Inner TaskGroup has one task. Semaphore acquired and released quickly.
2. **Very large file (1000+ chunks)**: 50+ batches. Inner TaskGroup processes them M-at-a-time. Other file workers may stall waiting for semaphore permits, which is correct — it prevents memory explosion.
3. **Embed failure (vector returns nil)**: Chunk is skipped, not counted. If all chunks fail, file result is `.skippedEmbedFailure`.
4. **Non-English content**: Warning emitted once per file via `EmbeddingService.warnIfNonEnglish`. Since different batches may be embedded by different EmbeddingService instances, we track warned state per-file in the file worker (not per-embedder).

### Testing

- Existing `VecKitTests` and `IntegrationTests` verify end-to-end indexing behavior
- `CLITests` verify CLI output format
- No new test file needed if existing tests continue to pass
- Manual verification: run `vec update-index -v` on a real directory and check output/timing
