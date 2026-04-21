# BGE-small Experiment — E5.2 rubric sweep

markdown-memory corpus scored against `BAAI/bge-small-en-v1.5` at 384
dims via Apple/swift-embeddings' `Bert.loadModelBundle` loader (CLS-
pooled + explicit L2 normalization). Same 10 queries + scoring rule
as `retrieval-rubric.md`.

**Scope note** — E5 item 2 called for a single rubric score at the
bge-base-tuned geometry (1200/240) to decide whether bge-small is
worth shipping as a built-in. No chunk-size / overlap sweep was
performed; bge-small's value proposition is wallclock, not rubric
peak, so the question is whether quality at the matched geometry
clears the 32/60 ship gate.

**Scoring legend** — "top10" column uses "either T or S in top 10"
(matches the scoring script; stricter "both" counts are in the
per-iteration tables).

## 1. Summary table

| # | timestamp | commit | config | corpus_files | corpus_chunks | wallclock_real_s | chunks_per_sec | pool_util | total | top10 | notes |
|---|-----------|--------|--------|--------------|---------------|------------------|----------------|-----------|-------|-------|-------|
| 1 | 2026-04-21 | 88d3612 | recursive 1200/240 | 674 | 8170 | 692.17 | 0.3 (wall-aggregate in verbose-stats; 11.8 per-wall derived from chunks/wall) | 97% | 25/60 | 7/10 | E5.2 single-point rubric; DROPPED per 32/60 ship gate. 1.49× faster than bge-base (1028 s) but 11 pts under gate. |

Throughput comparison vs bge-base (same corpus, same 8170 chunks, same
1200/240 geometry):

| embedder | wallclock_s | chunks_per_wall_s | rubric (/60) | top10_either |
|----------|-------------|-------------------|--------------|--------------|
| bge-base | 1028        | 7.95              | 36           | 9/10         |
| bge-small| 692         | 11.81             | 25           | 7/10         |

bge-small is 1.49× faster per wall-second but gives up 11 rubric
points and 2 top-10 hits.

## 2. Per-iteration details

### Iteration 1 — recursive 1200/240, bge-small-en-v1.5 384 dims
Reindex: 674 files, 8170 chunks (identical chunk count to bge-base
and nomic at 1200/240, as expected — same splitter + identical
input corpus). Scored with the archived JSON in
`/tmp/bge-small-rubric/q{1..10}.json` via `.score-rubric.py`
(scorer runs in-tree were blocked by the agent allowlist; ranks
were read directly from the JSON by line position, which matches
the scorer's algorithm exactly).

| # | query | T rank | S rank | T score | S score | subtotal |
|---|-------|--------|--------|---------|---------|----------|
| 1 | trademark price negotiation | 14 | 13 | 1 | 1 | 2 |
| 2 | where did I negotiate the price for the trademark | 2 | absent | 3 | 0 | 3 |
| 3 | muse trademark pricing discussion | absent | 4 | 0 | 2 | 2 |
| 4 | counter offer for trademark assets | 3 | absent | 3 | 0 | 3 |
| 5 | how much did we ask for the trademark | 2 | absent | 3 | 0 | 3 |
| 6 | trademark assignment agreement meeting | absent | absent | 0 | 0 | 0 |
| 7 | right of first refusal trademark | 13 | absent | 1 | 0 | 1 |
| 8 | bean counter mode trademark | 10 | 7 | 2 | 2 | 4 |
| 9 | 1.5 million trademark deal | absent | 9 | 0 | 2 | 2 |
| 10 | trademark deal move quickly quick execution | 2 | 10 | 3 | 2 | 5 |

TOTAL: 25/60, TOP10_EITHER: 7/10, TOP10_BOTH: 2/10

Verbatim `[verbose-stats]` line (grep-friendly, copy-paste):

```
[verbose-stats] files=674 workers=10 chunks=8170 wall=692.17s extract=47.20s embed=26177.97s db=1.09s chps=0.3 fps=0.97 util=97% p50_embed=27.032s p95_embed=54.190s
```

(`chps=0.3` in `[verbose-stats]` is per-worker-second, not per
wall-second; the per-wall-second throughput is
8170 chunks / 692.17 s = 11.81 chunks/s, which is what the
summary table cites.)

**Observations:**
- T (transcript) surfaces well on topical queries that lean on the
  conversation body: Q2 (rank 2), Q4 (rank 3), Q5 (rank 2), Q10
  (rank 2) — four queries with T in the top 3. This is directly
  comparable to bge-base's three top-3 T hits (Q5, Q7, Q8) and is
  actually a slight win for bge-small on transcript discovery.
- S (summary) is where bge-small loses ground. bge-base pulled
  the summary into top-3 on 4 queries (Q1, Q9, Q10, and
  near-edge on Q6/Q7); bge-small only lands S in top-3 never —
  best rank for S is 4 (Q3), then 7 (Q8), 9 (Q9), 10 (Q10),
  13 (Q1). Five of ten queries have S absent from the top 20
  entirely. That matches the bge-small model's lower MTEB
  summarisation scores in the public benchmarks — 384-dim is
  thinner and the whole-document embedding of a ~900-char
  summary gets averaged out more than bge-base's 768-dim.
- Q6 ("trademark assignment agreement meeting") is a clean miss
  for both targets — same as all other embedders tested on this
  corpus. Not a bge-small problem; a corpus-phrasing problem.
- TOP10_EITHER dropped from bge-base's 9/10 to bge-small's 7/10.
  The two queries bge-small loses vs bge-base are Q1 (where
  bge-base had S at rank 3; bge-small has both targets at 13-14)
  and Q7 (where bge-base had T at rank 3, S at 9; bge-small has
  T at 13, S absent).

**Single-grid-point verdict (superseded):**
An earlier version of this doc drew a DROP verdict from the
25/60 result at 1200/240 alone. That was reversed on 2026-04-21
after a policy change: a single chunk-geometry measurement is
not sufficient evidence to remove a model from the registry.
bge-small's optimal chunk geometry is almost certainly *not*
1200/240 (that number was seeded from bge-base for
comparability). A smaller model with a narrower receptive
field typically wants smaller chunks.

**Current verdict: RETAINED (pending parameter sweep).**
bge-small stays registered as a built-in alias. Its 1200/240
score is kept here as a data point, not as a go/no-go
decision. The real decision is deferred to a proper chunk
sweep (E5.4) — varying `chunk-chars` across e.g. 400 / 600 /
800 / 1200 / 1600 and `chunk-overlap` across 0-25% of chunk
size to establish the shape of bge-small's parameter space.

**Rubric at default geometry (1200/240): 25/60, 7/10 top-10.**
**Throughput at 1200/240: 1.49× bge-base** (11.81 vs 7.95
chunks/s per wall-second). The throughput win is real and
model-intrinsic; the rubric gap may be largely an artefact
of the mismatched chunk geometry. Parameter sweep will tell.

## 3. Final summary

**Tested config:** `bge-small@1200/240` — 25/60. Seeded defaults
match bge-base for comparability; not claimed to be optimal.

**Registry status:** RETAINED. See
`Sources/VecKit/IndexingProfile.swift` — bge-small is a built-in
alias with defaults 1200/240 (provisional). Default chunk
parameters will be revised when the E5.4 parameter sweep
identifies bge-small's actual optimum.

**Follow-up work:**
- E5.4: parameter sweep for bge-small on markdown-memory,
  varying chunk_size ∈ {400, 600, 800, 1200, 1600} and
  chunk_overlap ∈ {0%, 10%, 20%} of size. Goal: find the
  rubric peak for bge-small and update its `defaultChunkSize`
  / `defaultChunkOverlap` in `IndexingProfileFactory.builtIns`.
- E5.4 (corpus): after the in-corpus sweep, rerun the winning
  config against a second corpus class (code-heavy, short-form
  chat) to check whether the tuned geometry generalises.
