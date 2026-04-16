# Indexing Pipeline Optimization Plan

## Problem

`vec update-index` is CPU-bound at ~800% (8 cores saturated) but only processes
**~11 chunks/sec**, which works out to ~1.4 chunks/sec/core. For a 512-dim
sentence embedding on-device, that's much slower than expected. In addition,
there is a ~15s cold-start window before the first batch completes, during
which workers are blocked and progress is effectively zero.

Observed baseline (929-file corpus, verbose mode):

| Wall time | Files | Chunks | c/s avg | c/s 30s |
|----------:|------:|-------:|--------:|--------:|
|   15.0s   |   0   |   20   |    1    |    0    |
|   33.6s   |   1   |  380   |   11    |   20    |
|   59.8s   |   2   |  594   |   10    |   13    |
|  131.4s   |   2   | 1378   |   10    |   10    |

Workers are almost always 10/10 busy, save queue is ~0, and memory usage is
high (10 × ~50 MB NLEmbedding instances + model weights duplicated).

## Goal

Raise sustained throughput (c/s avg) by at least 2× while keeping indexing
crash-free. Shrink first-batch latency to under ~5s. Reduce peak RSS from
~500 MB of duplicated embedder state.

Every change is gated on empirical measurement against the same corpus —
no optimization lands without a before/after throughput number from the
existing verbose stats.

## Hypotheses (ranked by expected payoff)

The list below is the full menu of ideas to investigate. Each item is a
**hypothesis** — we may disprove some of them. Each will become its own
worker-agent task with its own success/failure criteria.

### H1. `NLEmbedding` may actually be thread-safe now

**The claim in `EmbeddingService.swift:7`**: concurrent `vector(for:)` on a
single `NLEmbedding` instance segfaults in the underlying C++ runtime, so we
pre-create N instances.

**Why it's worth re-testing:**
- The crash may have been fixed in a recent macOS / Natural Language update.
- Each instance duplicates the sentence-embedding model (~50 MB), so 10
  workers = ~500 MB of redundant weights.
- `NLEmbedding` almost certainly does its own internal parallelism for the
  matmul. Running 10 copies concurrently means 10× that contention fighting
  for the same caches and cores — probably a net loss.

**Test plan:**
1. Write an isolated stress test (new file in `Tests/VecKitTests/`):
   - 1 shared `NLEmbedding.sentenceEmbedding(for: .english)` instance
   - 10 concurrent Swift tasks, each calling `.vector(for:)` in a tight loop
   - Varied input texts, 10k iterations total
   - Run under Swift's strict concurrency and with Thread Sanitizer
2. If it doesn't crash on our target macOS version(s), the 10-instance pool
   is unnecessary.

**Success criteria:**
- Stress test runs to completion 5× in a row without crash, hang, or TSan
  report.
- OR it does crash / hang — in which case we document the failure mode and
  move on to H2.

**If H1 succeeds, follow-up work (separate task):**
- Collapse `EmbedderPool` to a single shared `EmbeddingService`.
- Keep a concurrency limit (semaphore/actor) at `activeProcessorCount`
  so we don't oversubscribe the NLEmbedding-internal threading.
- Re-measure c/s avg and first-batch latency on the same corpus.

### Result: DISPROVEN (2026-04-16)

Stress test at `Tests/VecKitTests/NLEmbeddingThreadSafetyTests.swift`
(added in `915c7d9`): 1 shared `NLEmbedding`, 10 TaskGroup workers,
10,000 `vector(for:)` calls over ~230 distinct English strings.

- 5/5 runs crashed within the first second.
  - Runs 1–3: `SIGSEGV` / `EXC_BAD_ACCESS` (`KERN_INVALID_ADDRESS`).
  - Runs 4–5: `SIGTRAP` / `"BUG IN CLIENT OF LIBMALLOC: memory corruption
    of free block"`.
- Crash stack in every report:
  `NLEmbedding.vector(for:)` → `-[NLEmbedding vectorForString:]` →
  `CoreNLP::SentenceEmbedding::fillStringVector` →
  `CoreNLP::AbstractEmbedding::fillWordVectorsWithShape`. Concurrent-write
  corruption inside Apple's C++ runtime.
- TSan could not run: macOS 26 platform policy rejects
  `libclang_rt.tsan_osx_dynamic.dylib` at dyld load. Environment
  limitation, not a test gap — the 5 hard crashes answer it.

**Conclusion:** the `EmbeddingService.swift:7` comment is still correct
on macOS 26.3.1. **Do NOT collapse `EmbedderPool` to a single shared
instance.** The stress test stays in the suite as a regression canary
— if Apple ever fixes this, the test will start passing and we'll know
to revisit.

**Follow-up question, now shaped like H2:** the ~500 MB of duplicated
weights is still a real cost. Sizing the pool to `activeProcessorCount`
instead of a hardcoded 10 is now part of H2.

---

### H2. Worker count should match cores, not exceed them

`IndexingPipeline.swift:114` defaults concurrency to
`max(activeProcessorCount, 2)`, which on this machine is 10 — but `top`
shows only 8 cores saturated. The extra 2 workers are probably just
context-switch overhead.

**Test plan:**
- Parameterize and benchmark concurrency ∈ {4, 6, 8, 10, 12} on the same
  corpus.
- Record c/s avg, first-batch latency, and peak RSS for each.

**Success criteria:**
- We pick the concurrency value that maximizes c/s avg. If the best value
  is < 10, we update the default and document why.
- If H1 succeeded (shared embedder), the sweep should be re-run — the
  shape of the curve likely changes.

### Result: KEEP CURRENT DEFAULT (2026-04-16)

Measurement test at `Tests/VecKitTests/ConcurrencySweepTests.swift`
(added in `ffe768c`): 70-file synthetic log-shaped corpus (~480 chunks),
2 runs per concurrency value, one warm-up run discarded.

Machine: Apple Silicon, `physical_cpu == logical_cpu == 10` (no SMT, so
the "logical vs physical" distinction this test was built to settle
doesn't apply here — it would matter on x86 with hyperthreading).

| concurrency | run1 c/s | run2 c/s | avg c/s | avg wall |
|:-----------:|:--------:|:--------:|:-------:|:--------:|
|      4      |   15.4   |   15.4   |  15.4   |  31.1s   |
|      6      |   18.8   |   18.8   |  18.8   |  25.6s   |
|     10      |   20.8   |   21.4   |  21.1   |  22.8s   |
|     12      |   21.2   |   22.0   |  21.6   |  22.2s   |

- 4→6: +22% throughput
- 6→10: +12%
- 10→12: +2.4% (inside noise)

**Conclusion:** keep the default at `activeProcessorCount` (10 on this
machine). Going above the plateau costs ~100 MB of NLEmbedding weights
per extra worker for essentially no throughput. Going below it costs
measurable throughput.

**Caveat re: original observation.** The user saw `top` showing 800% CPU
(not 1000%) with 10 workers, which seemed to suggest the extra 2 workers
were wasted. But on Apple Silicon with mixed Performance + Efficiency
cores, `top`'s single-core-percent view can understate total capacity —
E-cores run NLEmbedding slower than P-cores, so even at full saturation
the sum-of-cores number can look like ~800% of a P-core baseline. The
sweep numbers say 10 workers fully extract the machine's throughput;
don't reduce it on the strength of a `top` reading alone.

**Memory-pressure lever.** If RSS becomes the constraint, drop to 8
workers: costs ~5% throughput in exchange for 2 fewer embedder instances
(~100 MB). That's a deliberate memory/throughput trade, not a general
improvement — only pull that lever if memory pressure is actually biting.

---

### H3. Larger chunks reduce per-embed overhead

Current defaults (`TextExtractor.swift:11-13`): `chunkSize: 30` lines,
`overlap: 8`. Typical 30-line chunks are maybe 1–3 KB, but
`EmbeddingService` truncates at 10,000 chars (`EmbeddingService.swift:21`).
Each `vector(for:)` call has fixed overhead (tokenization, model setup)
that's wasted when the chunk is small.

**Test plan:**
- Benchmark `{chunkSize, overlap}` ∈
  `{(30,8), (60,15), (100,25), (150,30)}` on the same corpus.
- For each, record c/s avg AND spot-check search quality on 5 known
  queries (no point going faster if recall tanks).

**Success criteria:**
- A config that improves c/s avg without noticeably degrading search results
  on the spot-check queries. If none qualifies, we stay at (30, 8) and move on.

**Risk:** Larger chunks dilute per-chunk semantic specificity. We need the
quality spot-check — this is NOT a pure throughput optimization.

---

### H4. Skip the whole-document embedding for large files

`TextExtractor.swift:48` unconditionally adds a whole-document chunk. For
files larger than the 10k-char embed limit, this chunk is truncated and
becomes a near-duplicate of chunk #1 (which covers the first ~30 lines /
top of the file). We pay the embed cost for almost no new information.

**Test plan:**
- Change `extract(from:)` to skip the whole-doc chunk when the file produces
  ≥ 2 line-chunks (i.e. it's already chunked).
- Re-run the search spot-check queries to confirm recall doesn't regress on
  "summarize whole file"-style queries.

**Success criteria:**
- Measurable drop in total chunks embedded (and thus wall-clock) with no
  regression on spot-check queries.

---

### H5. Eager embedder-model warmup to shrink cold-start

First-batch latency is ~15s. A chunk of that is 10 parallel `NLEmbedding`
model loads contending for memory bandwidth. If we do one synchronous
warmup `embed("warmup")` call before starting workers, subsequent loads
should hit warm caches.

**Test plan:**
- At pipeline start, call `.embed("warmup")` on every pooled embedder
  *serially* before starting the worker task group.
- Compare first-batch-latency stat to baseline.

**Success criteria:**
- First-batch latency drops by ≥ 5s.
- No regression in sustained c/s avg.

**Note:** If H1 succeeds and we go down to one shared embedder, this item
becomes a one-liner (warm up the single instance) and most of the
cold-start should disappear anyway.

### Result: KEEP WARMUP ON, BUT IT'S NEUTRAL IN THIS HARNESS (2026-04-16)

Implementation: `EmbedderPool.warmAll()` calls `.embed("warmup text")`
serially on every pooled embedder before the worker task group starts.
Wired through `IndexingPipeline.run()` behind an internal `warmup: Bool`
init seam (default `true`). Emits `.poolWarmed(seconds:)` progress event.

Measurement at `Tests/VecKitTests/PoolWarmupTests.swift`: same 70-file
synthetic corpus as H2, default concurrency (10), 4 timed runs (no
discarded warm-up — the whole point is to keep cold-start cost in trial
1). Order: off-1, on-1, off-2, on-2.

| condition  | trial1 first_batch | trial2 first_batch | trial1 wall | trial2 wall |
|:-----------|:------------------:|:------------------:|:-----------:|:-----------:|
| warmup off |       0.35s        |       0.29s        |   24.38s    |   24.76s    |
| warmup on  |       0.27s        |       0.27s        |   24.52s    |   24.61s    |

- First-batch latency improvement: ~0.05s (within noise).
- Wall-clock impact: also within noise (off avg 24.57s, on avg 24.57s).
- Did NOT reproduce the user's reported ~15s cold-start. The XCTest
  process loads NLEmbedding once at framework load time before any test
  body runs; trial 1 here pays a much smaller cost than `vec
  update-index` does at process startup. The synthetic 480-chunk corpus
  is also smaller than the 929-file production case.

**Conclusion:** keep warmup on by default. Even though this harness
can't measure the production cold-start, the production-side argument
is unchanged: 10 parallel `NLEmbedding.vector(for:)` first-calls hit
memory bandwidth at the same time, and serializing the cold loads costs
nothing in steady-state (this test confirms ≤ noise impact). On a real
`vec update-index` invocation the user reports ~15s cold-start that
this should help with — needs a manual production-corpus check to
confirm magnitude, but the change is safe to ship as a default since
it's neutral in the controlled measurement.

**Caveats / follow-ups:**
- A more honest reproduction would launch a fresh process per trial
  (one `swift run vec update-index --verbose` per trial, not one XCTest
  process) so model load is not amortized across trials. Out of scope
  for this measurement.
- If the user confirms first-batch latency still ≥ 5s in production
  with warmup enabled, the next step is to look at extract-bound
  startup (the one-document-and-then-line-chunks pattern in
  `TextExtractor`) rather than embedder cold-load.

---

### H7. Three-stage pipeline: extract / embed / save, one task per chunk

**The problem with the current architecture.** `IndexingPipeline.run()`
uses a nested TaskGroup pattern: an outer group of N file-workers, and
each worker *itself* opens a TaskGroup inside `processFile` that spawns
one embed task per batch. All those inner groups share the single
`EmbedderPool` of N instances.

Consequences:
- A worker holds a file "hostage" from extract through full embed
  before releasing — it can't pull the next file off the queue until
  every chunk of the current file is embedded and collected.
- The pool is over-subscribed under contention: while worker A's
  batches acquire embedders, workers B–J's batches queue on
  `pool.acquire()`.
- Per-file batching (`embedBatchSize = 20`) wastes pool capacity on
  small files: a 30-chunk file produces 2 batches → 2 embedders busy,
  8 idle. See the conversation context: user pointed out this wastes
  available parallelism on files with < `batchSize × poolSize`
  chunks.

**Evidence from production run (post-H5):**
At 86s of indexing, the verbose line shows `0/925 files | 860 chunks |
workers 10/10 | bn embed`. The user confirmed this is because the FIRST
file in the corpus is very large — all 860 embedded chunks belong to
that one file. So the workers aren't deadlocked on a medium-file
contention pattern; instead, 9 of the 10 workers are holding *smaller*
files hostage through their embed phases while one huge file monopolizes
pool capacity. Either way, the nested-TaskGroup design means workers
can't hand chunks off to a shared embed stage — which is what H7 fixes.

**Secondary evidence:** H5's warmup dropped first-batch latency from
15.0s → 12.7s in the production run — a real ~15% cold-start win, but
steady-state c/s avg is unchanged at ~10 c/s. So embed throughput, not
startup, is the wall.

**Proposed new architecture — three stages connected by streams:**

```
  File workers (N_extract) → chunk stream
                                ↓
  Embed workers (N_embed, one per pooled embedder, pool-gated)
                                ↓
  Per-file accumulator (groups chunks back by file, signals when done)
                                ↓
  DB writer (1, serial)
```

Key properties:
- One task per chunk at the embed stage — no more batching layer,
  pool is the natural gate.
- Extract workers hand chunks off immediately and pick up the next
  file — no "hostage" behavior.
- Per-file accumulator holds partial results until a file's chunk
  count is reached, then emits `SaveWork` to the DB writer.
- Extract concurrency and embed concurrency are decoupled. On Apple
  Silicon we might want `N_extract < N_embed` because extract is
  cheap and embed is the bottleneck.

**This subsumes three earlier hypotheses:**
- **H3** (larger chunks): no longer the right lever — per-chunk
  overhead is dominated by the embed call, not batching.
- **H6** (intra-file streaming): falls out automatically.
- Plus the "batching wastes pool on small files" observation that
  triggered this hypothesis.

**Risk & complexity:**
- Largest refactor in the plan. Touches `IndexingPipeline.run`,
  `processFile`, and the stream topology.
- Chunks can arrive out of order at the accumulator; `ChunkRecord`
  already carries `lineStart`/`lineEnd`, but the per-file array
  reassembled for `database.replaceEntries` may need sort-by-order
  to preserve display grouping.
- Progress events need rework. `.batchEmbedded(seconds, chunks)`
  becomes `.chunkEmbedded(seconds)` (or we emit every K chunks to
  keep renderer lock traffic manageable — needs measurement).

**Test plan:**
1. Add a new integration test
   `Tests/VecKitTests/ThreeStagePipelineTests.swift` that runs the
   same synthetic log corpus as H2/H5 and records:
   - chunks/sec (should improve)
   - first-file-completion wall-clock (should drop dramatically —
     no more "0/N files done at 86s")
   - total wall-clock
   - `workers busy` utilization over time
2. Keep the existing `ConcurrencySweepTests` / `PoolWarmupTests`
   passing unchanged.
3. All existing unit + integration tests pass.
4. Do a manual production run on the user's 929-file log corpus
   with `vec update-index --verbose` and compare the
   `[verbose-stats]` line against the pre-H7 baseline in this
   document.

**Success criteria:**
- First file completes in < 30s on the production corpus (currently
  > 86s).
- Sustained c/s avg improves by ≥ 50% on the production corpus.
- No correctness regression — same chunks embedded, same search
  results on spot-check queries.

**Execution notes:**
- Keep the refactor behind the existing public API if possible.
  `IndexingPipeline.run(workItems:extractor:database:progress:)`
  is the contract; its internals can change.
- The `EmbedderPool` design is reusable as-is. We just stop nesting
  TaskGroups inside each worker.
- Keep an `embedBatchSize` field for now but mark it ignored by H7's
  path and remove after the refactor lands.

---

### H6 (SUPERSEDED by H7). Extract and embed in parallel per-file (streaming batches)

Current per-file flow in `IndexingPipeline.swift:252`:
`extract all chunks → batch → embed batches concurrently`. For a large
file, the extract step blocks the worker entirely before any embed begins.

A streaming variant: extract yields chunks incrementally, and we start
embedding batches as soon as the first batch's worth of chunks is ready.

**Status:** Speculative, hard to implement without refactoring
`TextExtractor`. Deferred unless H1–H5 leave us short of the 2× target.

---

## Method

For every hypothesis:

1. Record baseline numbers (c/s avg, first-batch latency, peak RSS) on the
   reference corpus with `vec update-index --verbose`.
2. Apply ONE change.
3. Drop and rebuild the index from scratch, re-run, record new numbers.
4. Commit with the delta in the commit message.
5. Update this file with a `### Result` section under the hypothesis.

Keep the corpus and flags identical across runs. Don't mix two changes in
one benchmark run.

## Execution order

1. **H1** first — if it works, it reshapes every other test because the
   concurrency knob changes meaning.
2. **H2** second — cheap, independent of chunk shape.
3. **H5** third — also cheap, mostly independent.
4. **H3 + H4** — these touch chunking and affect search quality, so they
   need the spot-check query set. Do H4 before H3 (smaller, lower-risk).
5. **H6** only if we still aren't at 2× after the above.

## Non-goals

- Changing the embedding model. `NLEmbedding.sentenceEmbedding(.english)`
  is the only on-device option we're committing to for now.
- GPU/ANE-backed embedding. Out of scope for this round.
- Changing the DB write path — save queue is at ~0, so it's not the
  bottleneck.

## Open questions

- What's the actual per-`vector(for:)` wall-clock on this machine for a
  typical chunk? The current stats report per-batch, not per-chunk. If
  H1–H5 don't add up, we may need finer-grained timing inside `embed()`.
- Is there a meaningful variance between cold-disk and warm-disk runs?
  If yes, extract time may be a hidden contributor and all benchmarks
  should warm the FS cache first.
