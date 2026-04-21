# vec — Plan

The rolling plan for the `vec` project. Covers what has shipped,
what's in progress, and what should happen next.

- **Reference** (stable): [`README.md`](./README.md) • [`indexing-profile.md`](./indexing-profile.md) • [`retrieval-rubric.md`](./retrieval-rubric.md)
- **Raw experiment data**: [`data/`](./data/)
- **Cited external research**: [`research/`](./research/)
- **Per-experiment plans + reports**: [`experiments/`](./experiments/)
- **Superseded snapshots**: [`archived/`](./archived/)

Last updated: 2026-04-21.

---

## Current state (as of 2026-04-21)

**Default embedder**: `bge-base@1200/240` (BGE-base-en-v1.5, 768-dim).

**Rubric score on markdown-memory**: 36/60, 9/10 top-10 hits
(scored with `.score-rubric.py` against the 10-query trademark
rubric). See [`retrieval-rubric.md`](./retrieval-rubric.md) for
the rubric definition.

**Wallclock on markdown-memory**: ~1028 s at N=10 workers,
batchSize=16 on a 10-core Apple Silicon machine. Per-model
comparison in [`data/wallclock-e4-per-model.md`](./data/wallclock-e4-per-model.md).

**Built-in embedders**: `bge-base` (default), `bge-small`, `bge-large`,
`nomic`, `nl-contextual`, `nl`. See
[`indexing-profile.md`](./indexing-profile.md) for the profile grammar
and [`README.md`](./README.md#built-in-embedders) for the comparison
table. `bge-small` and `bge-large` were added in E5.2/E5.3; their
default chunk geometries (1200/240) are provisional pending the E5.4
parameter sweep.

**Known issues**:
- Chunk-geometry defaults for `bge-small` and `bge-large` are seeded
  from `bge-base` for comparability rather than tuned for each
  model's architecture. The E5.4 sweep replaces these with measured
  peaks.
- The silent-failure observability gap (was open pre-E5) is now
  closed — `vec update-index` exits non-zero when every embed
  attempt failed. See E5.1 in the Done section.

---

## Done

All shipped on the current branch, in rough chronological order.

### Nomic migration (2026-04-17 → 2026-04-18)

Replaced Apple's `NLEmbedding.sentenceEmbedding` with
`nomic-embed-text-v1.5` (768-dim) via `swift-embeddings`. Raised
the rubric ceiling from **6/60 → 35/60** (5.8×) on markdown-memory.
Chunking tuned to `RecursiveCharacterSplitter` 1200/240 after a
12-iteration parameter sweep.

- Plan (executed, archived for shape reference): [`archived/2026-04/nomic-experiment-plan.md`](./archived/2026-04/nomic-experiment-plan.md)
- Raw sweep data: [`data/retrieval-nomic.md`](./data/retrieval-nomic.md)
- NL baseline it replaced: [`data/retrieval-nl.md`](./data/retrieval-nl.md)
- Historical status snapshot (pre-Phase-D): [`archived/2026-04/status.md`](./archived/2026-04/status.md)

### E1 — Multi-core embedding pool (2026-04-20)

Turned the single-instance `EmbedderPool` into an N-instance actor
pool so the 10 workers in the indexing pipeline stopped contending
on one mailbox. Shipped at N=10, wallclock 1310 s, pool util 98 %,
aggregate 2.5 chunks/sec on markdown-memory.

- Plan: [`experiments/E1-multicore/plan.md`](./experiments/E1-multicore/plan.md)

### Phase D — Embedder expansion (2026-04-19)

Added two new built-in embedders — `bge-base-en-v1.5` (MIT, 768-dim)
and `nl-contextual` (Apple, 512-dim, zero install) — alongside the
existing `nomic` and `nl`. Selected per-embedder default chunk
parameters by sweep against the rubric. **Default embedder flipped
from `nomic` to `bge-base`** after bge-base scored 36/60 vs nomic's
35/60 and delivered 9/10 top-10 vs nomic's 3/10.

- Plan + final comparison: [`experiments/PhaseD-embedder-expansion/plan.md`](./experiments/PhaseD-embedder-expansion/plan.md)
- Raw data: [`data/retrieval-bge-base.md`](./data/retrieval-bge-base.md) • [`data/retrieval-nl-contextual.md`](./data/retrieval-nl-contextual.md)
- External survey that seeded the picks: [`research/embedder-survey.md`](./research/embedder-survey.md)

### E4 — Batched embedding (2026-04-20)

Added `Embedder.embedDocuments([String])` with a BGE/Nomic batch
override using `swift-embeddings`' `batchEncode`. Rewired
`IndexingPipeline` through a length-bucketing batch-former with a
reduced-worker / batched-inference topology. **23.9 % wallclock cut**
(1310 s → 997 s) with bit-identical retrieval (36/60, cosine ≥
0.9999 vs single-embed). Peak RSS dropped 4.6 GiB → 1.5 GiB.

- Plan: [`experiments/E4-batched-embed/plan.md`](./experiments/E4-batched-embed/plan.md)
- Commits + sweep table: [`experiments/E4-batched-embed/commits.md`](./experiments/E4-batched-embed/commits.md)
- Lessons + what-happened: [`experiments/E4-batched-embed/report.md`](./experiments/E4-batched-embed/report.md)
- Per-model wallclock at E4 commit: [`data/wallclock-e4-per-model.md`](./data/wallclock-e4-per-model.md)

### E5.1-3 — Silent-failure guard + bge-small + bge-large (2026-04-21)

Three sub-deliverables closed on 2026-04-21:

**E5.1 — Silent-failure observability guard** (commit `8d63753`).
The indexing pipeline now exits non-zero with
`VecError.indexingProducedNoVectors` when every embed attempt fell
into `.skippedEmbedFailure` on a non-empty work list. The nomic
CoreML/ANE failure that hid for a release cycle is now a loud
failure. `SilentFailureGuardTests` covers the exit-code + summary
paths.

**E5.2 — `bge-small-en-v1.5` (384-dim, "fast tier")** registered as
a built-in alias. Single-point rubric at the seeded 1200/240 defaults:
**25/60, 7/10 top-10, wall 692 s** (1.49× bge-base per chunk). Raw
data in [`data/retrieval-bge-small.md`](./data/retrieval-bge-small.md).

**E5.3 — `bge-large-en-v1.5` (1024-dim, "max quality tier")**
registered as a built-in alias. Single-point rubric at the seeded
1200/240 defaults: **31/60, 8/10 top-10, wall 4891 s** (0.21×
bge-base per chunk). Raw data in
[`data/retrieval-bge-large.md`](./data/retrieval-bge-large.md).

**Policy reversal on drop gates.** The initial E5.2 and E5.3 plans
each defined a hard rubric floor ("≥32/60 to ship bge-small",
"≥40/60 to ship bge-large") and dropped both models after single
runs at 1200/240. That drop was reversed on 2026-04-21: a single
chunk-geometry measurement is not sufficient evidence to remove a
model from the registry. 1200/240 was picked for direct
comparability with bge-base, not because it is either model's
optimum. Both models are now retained in
`IndexingProfileFactory.builtIns`; finding each model's actual
rubric peak via a full chunk sweep is the first task in E5.4.

- Commits: `8d63753` (E5.1 silent-failure guard), `a145ade` (bge-small),
  `ca42af5` (bge-large), `356f4d3` (restore both after drop reversal).
- Raw data: [`data/retrieval-bge-small.md`](./data/retrieval-bge-small.md) •
  [`data/retrieval-bge-large.md`](./data/retrieval-bge-large.md)

---

## In progress

**E5.4 — Parameter sweeps + rubric-corpus expansion.** Active on
branch `agent/agent-26abd616`. See [Next — E5.4](#next--e54-parameter-sweeps--rubric-corpus-expansion) below.

---

## Next — E5.4: Parameter sweeps + rubric-corpus expansion

**The single-point rubric scores from E5.2/E5.3 don't justify a
ship/drop decision on their own.** Both bge-small and bge-large were
tested at 1200/240 (seeded from bge-base for comparability). 1200/240
is demonstrably bge-base's peak, but smaller and deeper models almost
certainly want different chunk geometries. E5.4 closes that gap.

### Why parameter sweeps now

1. **We bought an expensive data point and got a cheap answer.** E5.3
   cost ~82 min wallclock for a single measurement that ended in a
   drop → un-drop policy reversal. We need the shape of the parameter
   space, not one grid intersection. An honest grid (4 sizes × 3
   overlap percentages per model) also tells us where bge-base sits
   on its own curve — whether 1200/240 is a true peak or a lucky
   first guess.
2. **Default chunk parameters are registered per alias.** Today every
   alias other than `bge-base` has defaults seeded from another model.
   Updating `defaultChunkSize` / `defaultChunkOverlap` in
   `IndexingProfileFactory.builtIns` based on each model's rubric peak
   is a one-line registry change per alias, with outsized UX impact —
   `vec update-index --embedder bge-small` picks the right geometry
   without the user having to know it.
3. **Corpus-dependence is still an open question.** Carries over from
   E5's "open question" section: does the ranking generalize beyond
   markdown-memory? E5.4 pins this down by re-running the per-model
   winner against a second corpus.

### Concrete E5.4 recipe

1. **Build `vec sweep` subcommand.** Single Swift process, no
   external subprocesses: reset → reindex → 10 rubric queries →
   in-process scoring → JSON archive per point + summary.md row.
   Lives in `Sources/vec/Commands/SweepCommand.swift`. Matches the
   `scripts/score-rubric.py` algorithm byte-for-byte on totals (tested
   via `SweepCommandTests`). Writes under `benchmarks/<out-dir>/`
   following the existing archive convention so future rescores work.
2. **Sweep bge-small on markdown-memory.** Grid: sizes ∈ {400, 600,
   800, 1200, 1600}, overlap_pcts ∈ {0, 10, 20} = 15 points,
   ~12 min/point → ~3 hr wallclock. Record the peak (total, top10)
   and update `bge-small`'s defaults to the peak config.
3. **Sweep bge-large on markdown-memory.** Grid: sizes ∈ {800, 1200,
   1600, 2000}, overlap_pcts ∈ {0, 10, 20} = 12 points,
   ~82 min/point → ~16 hr wallclock. Same update.
4. **Bonus: sweep bge-base on markdown-memory.** 12 points,
   ~17 min/point → ~3 hr. Confirms whether 1200/240 is truly the
   peak or a local best. Might surface an un-tested geometry worth
   adopting as the new default.
5. **Corpus expansion.** Pick a second corpus — `vec`'s own source
   tree is the easiest candidate. Init a second DB
   (`markdown-memory-2` is taken; use something like `vec-source`).
   Re-run the per-model winners from steps 2-4 against the second
   corpus. Two outcomes:
   - **Same ranking**: publish with confidence that the defaults
     generalize. Move on to E5.5 doc updates.
   - **Different ranking**: document the corpus-dependence, flag
     `bge-base@1200/240` as the markdown-memory winner specifically,
     and defer per-corpus default selection to E6.

### What's deliberately out of scope for E5.4

- Other models beyond the three registered BGE variants. bge-base /
  bge-small / bge-large bracket the dim×depth curve cleanly; adding
  gte/e5/mxbai at the same dim doesn't learn anything new without
  the corpus-expansion data point first.
- N × batch_size concurrency sweeps — that's E6 optimization work.
- Retrieval-strategy changes (hybrid BM25, query expansion, re-ranker)
  — those are quality levers orthogonal to chunk geometry, pushed to
  post-E6.

---

## Backlog — E6 and beyond

Deferred until E5 resolves. From the E4 next-steps audit.

### Candidate models (after bge-small / bge-large)

| Candidate              | Size    | Dim  | MTEB  | Why it's interesting |
|------------------------|---------|------|-------|----------------------|
| `gte-base-en-v1.5`     | ~110 MB | 768  | 51.14 | Direct BGE-base peer; same dim lets us swap-test without changing index storage geometry |
| `e5-base-v2`           | ~110 MB | 768  | 50.3  | Query-prefix convention (`query:` / `passage:`) is different — validates prefix handling |
| `mxbai-embed-large-v1` | ~670 MB | 1024 | 54.7  | Current open-weights SOTA in the ~1 GB class; competitor to bge-large |

Per candidate, measure: rubric score vs bge-base 36/60,
wallclock at N=10 b=16, peak RSS + CPU%, chunks/sec at steady state.

### E6 — Parameter grid fill

Pure tuning; no code changes.

**Batch size toward the BNNS cap.** Phase C swept b=4/8/16 and saw
monotonic improvement. The BNNS fused-attention cap is 32. Untested:

- **b=24** — half-step past 16, cheap to run.
- **b=32** — the ceiling before BNNS falls back; wall-clock win is
  plausibly another 5-10 %, RSS impact unknown.

Guardrail: if pool utilization drops below 95 % as b grows, the
batch-former is starving on heterogeneous length buckets — revisit
bucket width below before pushing further. (95 % is the empirical
"fully-fed" mark from Phase C, where E4-3 and E4-4 both ran at
99 %; a step down to ~80-90 % indicates the batch former is being
held off chunks.)

**Length-bucket width tuning.** Current bucket key is
`chunk.text.count / 500`. Short corpora (code, chat) cluster in
buckets 0-1; long-form (transcripts, prose) cluster 2-5. Try
`/ 300` (finer, less padding waste, more small batches) and
`/ 700` (coarser, larger effective batches at the cost of more
pad tokens). Benchmark against at least two corpora — optimum is
corpus-dependent.

**Concurrency × batch grid.** Phase C tested 4 of 16 interesting
points:

| N \ b | 4 | 8 | 16 | 24 | 32 |
|-------|---|---|----|----|----|
| 2     |   |   | ✓  |    |    |
| 6     |   |   |    |    |    |
| 8     |   |   |    |    |    |
| 10    | ✓ | ✓ | ✓  |    |    |

Known gaps: N=6 / N=8 × b=16 (machine has 10 perf cores + efficiency
cores; N=10 may be past the efficient frontier), N=10 × b=24/32,
N=12/14 oversubscription probe.

**Bucket-width × batch-size mini-grid.** Bucket width and batch
size are coupled — wider buckets only pay off if batches fill:

| bucket \ batch | 16 | 24 | 32 |
|----------------|----|----|----|
| / 300          |    |    |    |
| / 500 (current)| ✓  |    |    |
| / 700          |    |    |    |

**Across corpora.** Everything in E4 ran against markdown-memory.
Optimal (N, b, bucket) is likely corpus-dependent. Before declaring
a new global default, re-run the winner against a code corpus
(shorter chunks, tighter length distribution) and a long-form
corpus (transcripts, books — wider distribution).

**Model × concurrency.** The N=10 default was tuned at bge-base
(768-d, 110 MB). Smaller models (bge-small at 33 MB) might tolerate
higher N before RSS pressure hits; larger models (bge-large at
670 MB) almost certainly want lower N. Each new model from E5 should
re-sweep N at b=16.

### E7 — DB-write parallelism

Only worthwhile once E5/E6 have pulled embed-time down far enough
that the writer is the next bottleneck. The accumulator is
currently the only serialization point after the embedder pool; a
cursory profile showed it's not the bottleneck today.

- WAL-checkpoint batching — commit every N chunks instead of per
  file.
- Separate writer task with its own AsyncStream — keeps the
  embedder pool fully utilized even during checkpoint flushes.

### Extractor parallelism

Extractor runs serially in front of the embedder pool. For
text-only corpora this is fine, but PDF / HTML extraction is
single-threaded and becomes the bottleneck the moment we add a
non-text format. Worth prototyping a small extractor pool (N=2-4)
behind the same backpressure semaphore.

nl-contextual already hit this ceiling: once the embedder got fast
enough, pool utilisation dropped from 98 % → 83 %, meaning extract
became the bottleneck. Making extract faster translates directly
into throughput gains for any fast embedder.

### MLTensor compute-policy experiments

CoreML's `MLComputePolicy` controls CPU / GPU / ANE placement.
Phase C ran with default (compiler-chosen). Worth probing:

- Force `.cpuAndNeuralEngine` — ANE may have headroom at
  batchSize ≤ 16.
- Force `.cpuAndGPU` — useful diagnostic even if not a win; tells
  us where the compiler is currently landing.

### MLX backend (passive watch)

E3 ruled out MLX because `swift-embeddings` didn't expose an MLX
path. If that changes upstream, MLX could unlock the GPU's
unified-memory bandwidth advantage. Track `swift-embeddings` issues
and releases — upstream-gated, not blocked on us.

### Other follow-up levers (carried over from original status)

From the pre-E4 status snapshot, still relevant:

1. **Hybrid retrieval (BM25 + vector)** — a lexical channel rewards
   exact phrase matches ("bean counter", "1.5 million") that pure
   vector smooths out. Expected 5-10 pts on this rubric. Biggest
   quality lever outside model swaps.
2. **Query expansion** — generate 2-3 paraphrases per query (LLM or
   local), aggregate results. Lift on topical queries.
3. **Multi-granularity indexing** — index each file at both
   1200/240 and a smaller size (e.g. 400/80), let the ranker see
   both.
4. **Per-file-type defaults** — `summary.md` files are short
   enough that `.whole` is always the interesting embedding;
   `transcript.txt` benefits from chunking. Branch at index time.
