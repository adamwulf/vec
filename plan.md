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

**Built-in embedders**: `bge-base` (default), `nomic`, `nl-contextual`,
`nl`. See [`indexing-profile.md`](./indexing-profile.md) for the
profile grammar and [`README.md`](./README.md#built-in-embedders)
for the comparison table.

**Known issues**:
- The silent-failure observability gap is still open: the indexing
  pipeline exits 0 with "Update complete" even when zero chunks
  land in the DB. This is what hid nomic's load failure for a
  release cycle. Fix in the E5 list below. The underlying nomic
  load failure was resolved by commit `7182920` (pin
  `computePolicy: .cpuOnly` in `NomicEmbedder.batchEncode`) —
  nomic now indexes the markdown-memory corpus end-to-end at
  ~1417 s (CPU-only). Detail in [`data/wallclock-e4-per-model.md`](./data/wallclock-e4-per-model.md#nomic-load-failure--diagnosed-and-fixed-historical).

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

---

## In progress

Nothing actively running.

---

## Next — E5: model expansion

**Run model expansion before further bge-base optimization.**
Optimization work on bge-base returns less per hour right now, and
the model-expansion work also tells us *whether* further
optimization is worth doing.

### Why model expansion first

Three reasons, in declining order of weight:

**1. E4 already harvested the cheap wallclock wins.** E4 took
bge-base from 1310 s → 1028 s (the fresh 2026-04-21 number — the
report's 997 s headline is within run-to-run variance). The
backlog optimizations below (batch=24/32, bucket-width, parallel
DB writes) are each plausibly worth 5-15 % on top of the current
1028 s. Even stacked optimistically that's ~700-800 s — a
meaningful but bounded win, and bounded only because on this
corpus the embed step is now 98 % of wallclock and BNNS is already
pegged at b=16. Pushing past the BNNS cap (32) needs a model
swap anyway.

**2. Quality has more headroom than speed on the rubric.** bge-base
scores 36/60 today. The rubric ceiling is 60. Even a modest-quality
model (bge-large) typically lifts MTEB by 2-3 points versus
bge-base, which on markdown-memory could realistically translate
to +4-8 rubric points. Optimization wins are pure speed — they
cannot move the 36/60 number. Retrieval quality is the user-visible
story ("did it find the right doc"); speed is the index-time story
("how long does ingestion take"). Index time is paid once per
re-ingestion; quality wins compound on every single search.

**3. Smaller models inform whether optimization is worth doing.**
`bge-small-en-v1.5` is ~33 MB vs bge-base's ~110 MB and ~3-4×
faster per chunk in benchmarks. If bge-small lands within 2-3
rubric points of bge-base, the right next move is making it the
default for users who care about speed — a much bigger speedup
than any optimization could deliver. If bge-small loses badly
(under 30/60), model size matters here and the optimization budget
should go to bge-base.

### Concrete E5 recipe

Priority order, each item independent:

1. **`bge-small-en-v1.5`** — add the alias to `IndexingProfileFactory`,
   wire it through `swift-embeddings` (same loader as bge-base,
   different model id), run the rubric at 1200/240. Expected:
   ~270 s wallclock (extrapolated from per-chunk speed), ~30-34/60.
   Decision criterion: if rubric ≥ 32/60, ship as
   `bge-small@1200/240` and document as the "small / fast" option.

2. **`bge-large-en-v1.5`** — same pattern, ~670 MB model. Expected:
   ~3000-3500 s wallclock (3× bge-base inference cost), ~38-42/60.
   Decision criterion: if rubric ≥ 40/60, ship as
   `bge-large@1200/240` and document as "max quality" (default
   stays bge-base).

3. ~~**Fix nomic load failure**~~ — **resolved 2026-04-21** (commit
   `7182920`). `NomicEmbedder.batchEncode` now forces
   `computePolicy: .cpuOnly`, sidestepping the macOS 26.3.1+ ANE
   compile error on FP32 weights. Post-fix wallclock on
   markdown-memory: 1417 s / 8170 chunks, pool util 98 %. See
   [`data/wallclock-e4-per-model.md`](./data/wallclock-e4-per-model.md#nomic-load-failure--diagnosed-and-fixed-historical).

4. **Fix the silent-failure observability gap** — the pipeline
   reported "Update complete: 674 added, 0 updated" with exit 0
   despite zero chunks landing in the DB. Phase-2 review NB4 had
   already flagged this as a gap; the nomic failure is the first
   time it's hidden a real bug. Suggested assertion: if
   `chunks_extracted > 0` and `chunks_saved == 0`, exit non-zero
   with the underlying error.

### What to skip / deprioritize for E5

- `gte-base`, `e5-base`, `mxbai-embed-large` — all same dim/size
  class as bge-base or bge-large; if bge-small + bge-large bracket
  the curve, the middle is well-explored. Revisit only if a
  specific corpus class (multilingual, code-heavy) calls for one.
- Further `nl-contextual` chunk sweeps — Phase D already concluded
  the model is wrong for this corpus (3/60 and 2/60 at 1200/240 and
  800/160). Keep it as the "no-install" tier and stop trying to
  make it competitive.
- MLX backend revisit — upstream-gated on `swift-embeddings`;
  adding it to active work now just delays model expansion.

### Open question worth answering before starting

Should the rubric corpus be expanded? Today every quality decision
hinges on 10 queries × 2 target files in markdown-memory. A model
that wins by +5 there might lose elsewhere. Recommendation: before
shipping bge-small or bge-large as defaults, run the rubric against
one additional corpus (vec's own source tree is the easiest
candidate). If both rank the same winner, ship with confidence. If
they disagree, we've discovered the corpus-dependence we suspected
and should pause to build per-corpus default selection before
locking in a new global default. One-time investment (~half a day)
that pays back on every subsequent embedder decision.

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
