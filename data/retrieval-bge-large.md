# BGE-large Experiment — E5.3 rubric sweep

markdown-memory corpus scored against `BAAI/bge-large-en-v1.5` at
1024 dims via Apple/swift-embeddings' `Bert.loadModelBundle` loader
(CLS-pooled + explicit L2 normalization). Same 10 queries + scoring
rule as `retrieval-rubric.md`.

**Scope note** — E5 item 3 called for a single rubric score at the
bge-base-tuned geometry (1200/240) to decide whether bge-large ships
as the "max quality" tier. Ship gate: ≥40/60. Borderline band: 36-39
(ship if beats bge-base by any margin). Below 36: drop. No chunk
sweep — quality-per-size decision, not a hyperparameter sweep.

**Scoring legend** — "top10" column uses "either T or S in top 10"
(matches the scoring script; stricter "both" counts are in the
per-iteration tables).

## 1. Summary table

| # | timestamp | commit | config | corpus_files | corpus_chunks | wallclock_real_s | chunks_per_sec | pool_util | total | top10 | notes |
|---|-----------|--------|--------|--------------|---------------|------------------|----------------|-----------|-------|-------|-------|
| 1 | 2026-04-21 | 802950e | recursive 1200/240 | 674 | 8170 | 4891.02 | 1.67 (wall-derived; `chps=0.0` in verbose-stats is a rounding artefact at 1024-dim throughput) | 98% | 31/60 | 8/10 | E5.3 single-point rubric; DROPPED per 40/60 ship gate (5 pts below) and 36/60 bge-base bar (5 pts below). 4.76× slower than bge-base for worse quality. |

Throughput + quality comparison vs bge-base (same corpus, same 8170
chunks, same 1200/240 geometry):

| embedder | dim | wallclock_s | chunks_per_wall_s | rubric (/60) | top10_either |
|----------|-----|-------------|-------------------|--------------|--------------|
| bge-base | 768 | 1028        | 7.95              | 36           | 9/10         |
| bge-large| 1024| 4891        | 1.67              | 31           | 8/10         |

bge-large is 4.76× slower per wall-second and loses 5 rubric points
and 1 top-10 hit. This is the opposite of the hoped-for tradeoff.

## 2. Per-iteration details

### Iteration 1 — recursive 1200/240, bge-large-en-v1.5 1024 dims

Reindex: 674 files, 8170 chunks (identical chunk count to bge-base
and bge-small at 1200/240, as expected — same splitter + identical
input corpus). Scored via `python3 scripts/score-rubric.py
benchmarks/bge-large-1200-240/` against the committed JSON archive.

| # | query | T rank | S rank | T score | S score | subtotal |
|---|-------|--------|--------|---------|---------|----------|
| 1 | trademark price negotiation | 2 | 12 | 3 | 1 | 4 |
| 2 | where did I negotiate the price for the trademark | 1 | absent | 3 | 0 | 3 |
| 3 | muse trademark pricing discussion | absent | 8 | 0 | 2 | 2 |
| 4 | counter offer for trademark assets | 3 | 9 | 3 | 2 | 5 |
| 5 | how much did we ask for the trademark | 1 | absent | 3 | 0 | 3 |
| 6 | trademark assignment agreement meeting | 14 | 20 | 1 | 1 | 2 |
| 7 | right of first refusal trademark | 3 | absent | 3 | 0 | 3 |
| 8 | bean counter mode trademark | 15 | absent | 1 | 0 | 1 |
| 9 | 1.5 million trademark deal | 12 | 8 | 1 | 2 | 3 |
| 10 | trademark deal move quickly quick execution | 9 | 2 | 2 | 3 | 5 |

TOTAL: 31/60, TOP10_EITHER: 8/10, TOP10_BOTH: 2/10

Verbatim `[verbose-stats]` line (grep-friendly, copy-paste):

```
[verbose-stats] files=674 workers=10 chunks=8170 wall=4891.02s extract=57.93s embed=192803.64s db=2.72s chps=0.0 fps=0.14 util=98% p50_embed=197.647s p95_embed=543.192s
```

(`chps=0.0` here is the per-worker-second figure rounded to one
decimal — at p50 ~198s per embed call for a 1024-dim 24-layer model,
per-worker throughput legitimately rounds to zero. Per-wall-second
is 8170 / 4891.02 = 1.67 chunks/s, which is what the summary table
cites. `p50_embed=197.647s` vs bge-base's 28s at 768-dim is the
dominant cost: the larger model takes ~7× longer per chunk.)

**Observations:**
- Strong top-1 performance on transcript: Q2 (rank 1), Q5 (rank 1),
  Q1 (rank 2) — bge-large genuinely pulls T closer to the top than
  bge-base does on those queries. So the "deeper model finds the
  exact-match needle" intuition is real.
- But summary retrieval collapses on the mid-ranks: S is absent from
  top 20 on Q2, Q5, Q7, Q8 (four queries) and lands at 12, 20, 8,
  and 8 on the others — bge-base gets S at 3, 13, 1, 1, and 1 on
  those same queries. bge-large's 1024-dim embedding is apparently
  *less* effective at matching the ~900-char summary document to
  question-form queries than bge-base's 768-dim is.
- TOP10_BOTH is 2/10 vs bge-base's 3/10 in the bge-base data file
  (the scorer rescored bge-base's original JSON at 3 top10_both;
  see bge-base data file footnote). Either way, bge-large doesn't
  pull both targets into top 10 more reliably than bge-base does.
- Q6 remains a miss for T; Q3 flips from bge-base's "T present"
  to "T absent" at bge-large. Q8 loses a bge-base summary hit
  entirely (S at rank 1 on bge-base; S absent on bge-large).
- The throughput regression is the other side of the story: 4891s
  wall (~82 min) vs bge-base's 1028s (~17 min) on an identical
  corpus. Larger batches don't amortise; the per-chunk inference
  cost is dominating, not pipeline overhead.

**Single-grid-point verdict (superseded):**
An earlier version of this doc drew a DROP verdict from the
31/60 result at 1200/240 alone. That was reversed on 2026-04-21
after a policy change: a single chunk-geometry measurement is
not sufficient evidence to remove a model from the registry.
bge-large's 24-layer, 1024-dim architecture has a meaningfully
larger receptive field than bge-base and may well prefer a
different chunk geometry — the 1200/240 defaults were seeded
from bge-base for comparability, not because they are optimal.

**Current verdict: RETAINED (pending parameter sweep).**
bge-large stays registered as a built-in alias. Its 1200/240
score is kept here as a data point, not as a go/no-go decision.
The real decision is deferred to a proper chunk sweep (E5.4) —
varying `chunk-chars` across e.g. 800 / 1200 / 1600 / 2000 and
`chunk-overlap` across 0-25% of chunk size to establish the
shape of bge-large's parameter space.

**Rubric at default geometry (1200/240): 31/60, 8/10 top-10.**
**Throughput at 1200/240: 0.21× bge-base** (1.67 vs 7.95
chunks/s per wall-second). The throughput cost is real and
model-intrinsic — bge-large is always going to be ~5× slower
than bge-base on like-for-like hardware. Whether the quality
payoff is also there depends on the parameter sweep's outcome.

## 3. Final summary

**Tested config:** `bge-large@1200/240` — 31/60. Seeded defaults
match bge-base for comparability; not claimed to be optimal.

**Registry status:** RETAINED. See
`Sources/VecKit/IndexingProfile.swift` — bge-large is a built-in
alias with defaults 1200/240 (provisional). Default chunk
parameters will be revised when the E5.4 parameter sweep
identifies bge-large's actual optimum.

**Follow-up work:**
- E5.4: parameter sweep for bge-large on markdown-memory,
  varying chunk_size ∈ {800, 1200, 1600, 2000} and
  chunk_overlap ∈ {0%, 10%, 20%} of size. Goal: find the
  rubric peak for bge-large and update its `defaultChunkSize`
  / `defaultChunkOverlap` in `IndexingProfileFactory.builtIns`.
  Each sweep point is ~82 min at 1200/240; a 12-point sweep is
  a ~16-hour background run.
- E5.4 (corpus): after the in-corpus sweep, rerun the winning
  config against a second corpus class. bge-large's training
  distribution is benchmark-style prose, which may or may not
  match markdown-memory's conversational notes.
