# BGE-small Chunk-Geometry Sweep — E5.4b

15-point chunk_size × overlap_pct sweep against the markdown-memory
corpus at 384 dims via Apple/swift-embeddings' `Bert.loadModelBundle`
loader (CLS-pooled + explicit L2 normalization). Same 10 queries +
scoring rule as `retrieval-rubric.md`.

Executed via `vec sweep` (E5.4a) so every grid point is a full
reset+reindex+rubric-score cycle. Raw archives + summary live under
`benchmarks/sweep-bge-small/`.

**Scope note** — E5.4b's job was to replace the seeded-from-bge-base
default (1200/240, 25/60) with a real per-model peak. Prior E5.2
single-point result is preserved in `data/retrieval-bge-small.md`
as a data point, not a verdict.

**Scoring legend** — `total_60` is the rubric total out of 60.
`top10_either` counts queries where either T or S landed in the
top 10 results (matches the scoring script).

## 1. Summary table

Sorted by total_60 descending, then by chunks_per_wall_s descending
as a throughput tiebreaker.

| # | config | chunks | wall_s | chps_wall | total_60 | top10_either | top10_both | notes |
|---|--------|--------|--------|-----------|----------|--------------|------------|-------|
| 1 | bge-small@1200/0   |  7528 |  609.8 | 12.3 | **30** | 9 | 2 | **Peak.** 20% overlap (1200/240) scores 25/60; 10% (1200/120) scores 21/60. Overlap is a pure loss here. |
| 2 | bge-small@800/80   | 11496 |  695.3 | 16.5 | 28 | 8 | 3 | Best "both targets in top 10" rate of any grid point. |
| 3 | bge-small@400/40   | 23861 | 1202.4 | 19.8 | 27 | 8 | 2 | Fastest chunks/s of any point above 25/60. |
| 4 | bge-small@400/80   | 24731 | 1212.4 | 20.4 | 26 | 8 | 2 | — |
| 5 | bge-small@1200/240 |  8170 |  689.0 | 11.9 | 25 | 7 | 2 | Single-point E5.2 baseline reproduced (25/60). |
| 5 | bge-small@600/0    | 15186 |  823.2 | 18.4 | 25 | 8 | 1 | — |
| 5 | bge-small@600/60   | 15545 |  827.8 | 18.8 | 25 | 7 | 2 | — |
| 5 | bge-small@400/0    | 23507 | 1307.2 | 18.0 | 25 | 7 | 1 | — |
| 9 | bge-small@600/120  | 16253 |  830.2 | 19.6 | 24 | 7 | 1 | — |
|10 | bge-small@800/0    | 11190 |  830.6 | 13.5 | 22 | 7 | 1 | — |
|10 | bge-small@800/160  | 12055 |  771.3 | 15.6 | 22 | 7 | 2 | — |
|12 | bge-small@1200/120 |  7734 |  606.6 | 12.7 | 21 | 7 | 1 | — |
|12 | bge-small@1600/160 |  5954 |  560.4 | 10.6 | 21 | 7 | 0 | — |
|14 | bge-small@1600/0   |  5760 |  517.8 | 11.1 | 20 | 6 | 0 | Fastest per chunk, but weakest top-10 coverage. |
|15 | bge-small@1600/320 |  6307 |  590.6 | 10.7 | 18 | 7 | 0 | Worst total of any point. |

Total sweep wallclock: 13 244 s ≈ 220 min ≈ 3 h 40 min on the same
macOS / M-series host used for every other rubric run in this tree.

## 2. Observations

**Overlap is actively harmful at chunk_size ≥ 1200.** At size 1200,
overlap 0 → 30/60, overlap 120 → 21/60, overlap 240 → 25/60. At size
1600 the same pattern holds (20 / 21 / 18). The 384-dim embedding
space apparently has too little capacity to absorb the redundancy
introduced by overlapping windows — duplicate embeddings crowd the
top-K results with near-identical near-neighbors and push the actual
target out of top 10.

**At small chunk sizes (≤ 800) some overlap helps.** 400/40 → 27/60
vs 400/0 → 25/60; 800/80 → 28/60 vs 800/0 → 22/60. Smaller chunks
have less context per vector, so a little overlap ensures target
phrases aren't split across chunk boundaries.

**The size sweet spot is 1200 chars.** This aligns with bge-base's
tuned defaults (1200/240), but bge-small wants *no* overlap at that
size. Plausible reading: both models want ~1200 chars of context per
vector, but bge-small's 384-dim space can't efficiently encode the
overlapping half-duplicates that bge-base's 768 dims apparently
tolerates.

**Throughput vs quality is not monotone.** The fastest config
(1600/0, 11.1 chps) scores 20/60 — worst of the grid. The peak
(1200/0) runs at 12.3 chps, only ~10% slower but 10 points better.
Among the "fast tier" use cases, 800/80 (16.5 chps, 28/60) is a
reasonable tradeoff: 1.3× faster than peak at 2-point quality cost.

**Compared to bge-base peak (36/60 at 1200/240):** bge-small peaks
at 30/60, or 6 points below. The gap persists; bge-small remains a
"cheap but weaker" tier, not a replacement. It's now at 83% of
bge-base's rubric quality and ~1.7× the throughput (12.3 vs ~7.95
chps at peak).

## 3. Decision

**New default: `bge-small@1200/0`.** Updates
`Sources/VecKit/IndexingProfile.swift` line ~175 to set
`defaultChunkOverlap: 0` (was 240).

bge-small remains registered as a built-in alias. Users selecting
`--embedder bge-small` now get the sweep-tuned geometry without
needing to specify `--chunk-chars` / `--chunk-overlap` manually.

**Single-point baseline preserved.** `data/retrieval-bge-small.md`
keeps the 25/60 @ 1200/240 measurement as historical data — useful
for readers tracking the E5.2 → E5.4b evolution, and as a
cross-check that the new sweep reproduces it (grid point #5).

## 4. Follow-up

- E5.4e (corpus expansion): rerun `bge-small@1200/0` against a
  second corpus (vec's own Swift source) to see whether "overlap is
  harmful at 384 dim" generalises beyond markdown-memory.
- The size axis wasn't pushed past 1600. If a future sweep explores
  {2000, 2400, 2800}, we'll know whether 1200 is a true peak or just
  a local maximum. Low priority — each additional size adds ~1.5-3h
  of wallclock.
