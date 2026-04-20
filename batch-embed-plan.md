# Batch-Embedding Experiment — Plan (E4)

Successor to E1 (N-instance pool, shipped at 1310s wall / 98% util / 2.5 c/s
aggregate) and E3 (ruled out — no compoundable win on CoreML stack).

## Hypothesis

External research reports single-call batch=1 BERT on M-series ≈ 8ms,
batch=32 ≈ 70ms — 3.6× per-item speedup. MLTensor BERT is bandwidth-bound
at batch=1; amortizing graph dispatch + memory traffic across a batch is
the last unexploited axis on this pipeline. Target: ≥30% wall-clock cut
vs E1 on the 674-file / 8170-chunk markdown-memory reindex.

## Design constraints (recap)

1. **Back-compat**: not every embedder has a native batch path. NLEmbedder
   (Apple `NLEmbedding`) is single-string-only. `NLContextualEmbedding`
   operates on one string per call. `NomicEmbedder` + `BGEBaseEmbedder`
   sit on `swift-embeddings`' Bert bundle which *does* expose
   `batchEncode([String], padTokenId, maxLength) -> MLTensor[batch, dim]`.
2. **Determinism**: the DB writer sorts by `ordinal`; batching must
   preserve the chunk ↔ ordinal mapping exactly.
3. **Padding cost**: `batchEncode` pads to the longest input. Mixing a
   2000-char chunk with 200-char chunks wastes ~90% of the batch FLOPs.
4. **Throwaway-friendly**: gate the rewrite behind a pass threshold; if
   <30% win, revert. Do not bake the batched shape into public API until
   measurements clear the bar.
5. **BNNS crash (jkrukowski/swift-embeddings #17)**: stay at batch ≤ 32.

## Phase A — Protocol extension

Add one new method to `Embedder` with a default implementation so every
existing conformer keeps working untouched.

```swift
public protocol Embedder: Sendable {
    // existing …
    func embedDocuments(_ texts: [String]) async throws -> [[Float]]
}
public extension Embedder {
    func embedDocuments(_ texts: [String]) async throws -> [[Float]] {
        var out: [[Float]] = []
        out.reserveCapacity(texts.count)
        for t in texts { out.append(try await embedDocument(t)) }
        return out
    }
}
```

**Semantics of the default**: preserves input order, propagates the
first throw. A batched override must match: output `[i]` ↔ input `[i]`,
whole-batch failure throws. An override may catch internally and return
`[]` at an index — the pipeline already treats `isEmpty` as "failed".

**Native overrides**:
- `BGEBaseEmbedder.embedDocuments`: trim/cap each input (reuse 2000-char
  cap), drop empty strings pre-batch (substitute `[]` at their index),
  call `bundle.batchEncode(inputs, padTokenId: <pad>, maxLength: 512)`,
  cast `MLTensor` to `Float`, slice into N rows, L2-normalize each row.
  Read pad-token id from the tokenizer (`[PAD]` = 0 for BGE) — don't
  hardcode.
- `NomicEmbedder.embedDocuments`: prefix each input with
  `"search_document: "`, call the Nomic bundle's `batchEncode` with
  `postProcess: .meanPoolAndNormalize` if available; else mean-pool +
  normalize in Swift. Don't double-normalize.

NLEmbedder + NLContextualEmbedder inherit the for-loop default — their
frameworks give no parallelism from a manual batch.

**Tensor slicing**: `scalars.count == batch * dim` (assert). Row `i` is
`scalars[i*dim ..< (i+1)*dim]`. Normalize in Float32 post-cast — never
inside the tensor graph (fp16).

## Phase B — Pipeline rewire

Pick **B1 (bounded-capacity collector)** + **B3 length-bucketing inside
it**. Reject B2 (time-window batcher inside the pool — smuggles latency
into the pool, makes tests flaky) and B3-standalone (doesn't change
one-chunk-per-acquire).

**Collector shape**:

```
extract (1 task) → embedStream → batch-former (1 task) → batchStream
                                                            ↓
                                               embed-spawner (TaskGroup)
                                                            ↓
                                                  accumStream (unchanged)
```

The batch-former drains `embedStream`, buffers incoming `EmbedWork`s into
**length buckets** (rounded chunk char-count / 500 → bucket id), and
flushes a batch when either:
- a bucket reaches `batchSize` (default 16, cap 32 per #17), OR
- the extract stream finishes (flush all partial buckets).

A flushed batch is a `BatchWork` = `[EmbedWork]` with stable per-item
`ordinal`. The batch-former does *not* reorder — it just groups by
length. Order within a batch is insertion order; ordinals are carried
through.

**Pool + workers**: reduce worker count. At batch=16 × 3 workers = 48
in-flight chunks, well under the E1 peak-memory budget. Expose
`concurrency` and `batchSize` on `IndexingPipeline.init` — default
`concurrency = 2` for batched path (override stays 10 for legacy).

`EmbedderPool.acquire/release` unchanged. The pool is still
one-worker-per-instance; the worker just does more work per acquisition.

**Embed-spawner task body** (replacing lines 352–422):

```swift
for await batch in batchStream {
    embedGroup.addTask {
        let embedder = await pool.acquire()
        progress?(.poolAcquired)
        let start = DispatchTime.now()
        let vectors: [[Float]]
        do {
            vectors = try await embedder.embedDocuments(batch.map { $0.chunk.text })
        } catch {
            vectors = Array(repeating: [], count: batch.count)
        }
        let secs = elapsed(since: start)
        await pool.release(embedder)
        progress?(.poolReleased)

        // Per-chunk event preserved for UI compat. Seconds = batch-wall / N
        // (amortized) — document this in the ProgressEvent doc.
        let per = secs / Double(max(batch.count, 1))
        for (work, vec) in zip(batch, vectors) {
            progress?(.chunkEmbedded(seconds: per))
            await statsCollector.recordChunkEmbed(seconds: per)
            let record = vec.isEmpty ? nil : ChunkRecord(/* … as before … */)
            await extractGate.release()
            accumContinuation.yield(EmbeddedChunk(
                filePath: work.file.relativePath,
                ordinal: work.ordinal,
                record: record))
        }
    }
}
```

**Pool-util accounting**: `totalEmbedCallSeconds` now sums *batch* wall
divided across chunks (as above). Util math (`Σ / (wall × workerCount)`)
remains meaningful — with fewer workers the denominator shrinks, so a
batched 3-worker run at 80% util is not comparable in absolute terms to
a 10-worker run at 98%. Reporter must print `workerCount` alongside util
so the operator can read the ratio correctly.

**Back-pressure**: `ExtractBackpressure.capacity` stays at `workerCount
* 2` but in chunk-units — so with 3 workers × batch 16 we should size
the gate generously (e.g. `workerCount * batchSize * 2`) or extract
stalls immediately. Make the gate capacity `concurrency * batchSize * 2`
in the batched pipeline.

**Error paths**: if `embedDocuments` throws, mark *every* chunk in the
batch as failed (empty vector). The accumulator already handles
`record == nil`. Do not retry the batch with single calls — that's a
behavior change (per-item failure isolation) worth its own experiment.

## Phase C — Measurement

Reuse the E1 verification protocol (`multicore-embed-plan.md`).

1. Idle cool-down ≥2 min.
2. `vec reset markdown-memory --force`.
3. `time vec update-index --verbose 2>&1 | tee .reindex-E4-<iter>.log`.
4. Capture `top -l 4 -s 1 -pid $(pgrep -n vec)` windows as before.
5. Parse `[verbose-stats]`: wall, embed, util, p50_embed, p95_embed.
6. **Rubric replay**: 10 bean-counter queries; score unchanged vs E1
   (regression guard — batching must not change vectors).

Record one row in `multicore-embed-plan.md` results table:
`E4 | concurrency=<N> | batchSize=<B> | wall | util | p50 | p95 | top-CPU`.

**Pass gates** (all must hold):
- Wall ≤ 917s (≥30% cut from 1310s).
- Rubric score ≥ prior E1 score (no retrieval regression).
- Peak RSS within 2× of E1.
- No BNNS crash in two back-to-back runs.

**Fail handling**:
- Wall regresses or batch flakes → revert the merge commit; leave the
  Phase A protocol addition in place (pure addition, no callers
  affected).
- BNNS crash (#17) → drop `batchSize` to 8, rerun once. If it still
  crashes, disable batched path for BGE and leave Nomic on batched.

## Phase D — Review cycle + ship

Invoke `/review-cycle` with two reviewers per the skill:

- **Reviewer 1 — protocol/API correctness**: Sendable conformance on
  new protocol method, fallback-default semantics (order, error
  propagation), tensor slicing correctness, L2-norm row-by-row,
  pad-token id lookup, empty-input short-circuit, no fp16-normalize.
- **Reviewer 2 — pipeline correctness**: ordinal determinism across the
  new batch-former task, back-pressure sizing (`concurrency * batchSize
  * 2`), `.chunkEmbedded` per-chunk emission preserved, error path
  (whole-batch failure → every ordinal marked failed), `extractGate`
  releases on every path including exception, worker-sizing override
  surface, `totalEmbedCallSeconds` accounting stays bounded by
  `wallSeconds * workerCount`.

Both reviewers must approve before merge. After merge, re-run the full
E1 row in the results table to confirm no post-merge regression.

## File-by-file diff checklist

- `Sources/VecKit/Embedder.swift` — add `embedDocuments` + default impl.
- `Sources/VecKit/BGEBaseEmbedder.swift` — override with `batchEncode`.
- `Sources/VecKit/NomicEmbedder.swift` — override with `batchEncode`.
- `Sources/VecKit/NLEmbedder.swift` — no change (inherits default).
- `Sources/VecKit/NLContextualEmbedder.swift` — no change (inherits).
- `Sources/VecKit/IndexingPipeline.swift` — new `BatchWork` payload,
  new batch-former task, rewired embed-spawner, back-pressure sizing,
  `init` gains `batchSize` param (default 16).
- `Sources/VecKit/IndexingProfile.swift` — no change.
- `multicore-embed-plan.md` — append E4 row to results table.

## Critical files to read before starting

- `Sources/VecKit/IndexingPipeline.swift` (current pipeline shape).
- `Sources/VecKit/BGEBaseEmbedder.swift`, `NomicEmbedder.swift`
  (bundle API).
- `swift-embeddings` package source for `Bert.ModelBundle.batchEncode`
  signature + pad-token handling. Confirm return shape `[batch, dim]`.
- `multicore-embed-plan.md` for verification protocol + prior rows.

## Risks and invariants

- **Determinism**: ordinals must survive the batch-former. Invariant:
  `zip(batch, vectors).map { ($0.ordinal, $1) }` is a bijection with the
  input. Covered by Reviewer 2.
- **Padding waste on mixed lengths**: length bucketing reduces this;
  observe p50 vs p95 per-chunk wall to confirm it's not regressing.
- **L2-norm × padding interaction**: padding tokens should not influence
  the CLS output (BERT attention masks handle this inside the model),
  but if the bundle's `batchEncode` does NOT emit an attention mask, the
  pad tokens contaminate the CLS vector. **Action**: verify bundle
  applies attention masking internally before trusting batched vectors;
  run a sanity check where `embedDocument(x)` and `embedDocuments([x,
  pad_filler])[0]` are cosine-identical to within 1e-4.
- **fp16 overflow**: normalize in Float32 post-cast.
- **BNNS #17**: cap batch at 32, drop to 8 on crash.
- **Worker-count × batch-size surface**: doubling either doubles in-flight
  memory. Start conservative (2 × 16 = 32 chunks) and only raise if E4
  passes comfortably.
- **Util % compare-across-configs**: util is per-worker occupancy, not
  throughput. Always pair with wall-clock.
