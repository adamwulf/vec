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

---

### H6. Extract and embed in parallel per-file (streaming batches)

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
