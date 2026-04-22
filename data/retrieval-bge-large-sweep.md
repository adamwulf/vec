# BGE-large Chunk-Geometry Sweep — E5.4c

12-point chunk_size × overlap_pct sweep against the markdown-memory
corpus at 1024 dims via Apple/swift-embeddings' `Bert.loadModelBundle`
loader (CLS-pooled + explicit L2 normalization). Same 10 queries +
scoring rule as `retrieval-rubric.md`.

Executed via `vec sweep` (E5.4a) so every grid point is a full
reset+reindex+rubric-score cycle. Raw archives + summary live under
`benchmarks/sweep-bge-large/`.

**Scope note** — E5.4c's job was to replace the seeded-from-bge-base
default (1200/240, 31/60) with a real per-model peak. Prior E5.3
single-point result is preserved in `data/retrieval-bge-large.md`
as a data point, not a verdict.

**Scoring legend** — `total_60` is the rubric total out of 60.
`top10_either` counts queries where either T or S landed in the
top 10 results (matches the scoring script).

## 1. Summary table

Sorted by total_60 descending, then by chunks_per_wall_s descending
as a throughput tiebreaker.

| # | config | chunks | wall_s | chps_wall | total_60 | top10_either | top10_both | notes |
|---|--------|--------|--------|-----------|----------|--------------|------------|-------|
| 1 | bge-large@1200/0   |  7528 | 3220.0 | 2.3 | **34** | 9 | 3 | **Peak.** Closes most of the gap to bge-base (36/60). |
| 2 | bge-large@1200/240 |  8170 | 3101.0 | 2.6 | 31 | 8 | 2 | Single-point E5.3 baseline reproduced within ±0 (31/60). |
| 3 | bge-large@800/160  | 12055 | 3521.4 | 3.4 | 30 | 8 | 3 | Same top10_both as the peak. |
| 4 | bge-large@800/0    | 11190 | 3093.1 | 3.6 | 28 | 8 | 1 | Fastest point in the top tier. |
| 4 | bge-large@800/80   | 11496 | 3183.8 | 3.6 | 28 | 8 | 2 | — |
| 4 | bge-large@1600/0   |  5760 | 2549.0 | 2.3 | 28 | 8 | 0 | — |
| 4 | bge-large@2000/400 |  5141 | 2732.3 | 1.9 | 28 | 8 | 1 | — |
| 8 | bge-large@1200/120 |  7734 | 2750.0 | 2.8 | 26 | 8 | 1 | Mid-overlap is an anti-peak at size 1200. |
| 9 | bge-large@1600/160 |  5954 | 2738.8 | 2.2 | 25 | 8 | 0 | — |
| 9 | bge-large@2000/200 |  4828 | 2627.2 | 1.8 | 24 | 6 | 1 | — |
|11 | bge-large@1600/320 |  6307 | 3020.0 | 2.1 | 24 | 7 | 0 | — |
|12 | bge-large@2000/0   |  4679 | 2355.6 | 2.0 | 17 | 3 | 0 | **Cliff.** Biggest chunks with no overlap collapse; top10_either drops to 3/10. |

Total sweep wallclock: 34 891 s ≈ 582 min ≈ 9 h 42 min on the same
macOS / M-series host used for every other rubric run in this tree.
Faster than the 16 h E5.3 estimate because bge-large throughput is
more stable than the 1200/240 baseline suggested — the sweep
averaged ~2.5 chps over ~82 k chunks (vs 1.67 chps at E5.3 on the
same single config).

## 2. Observations

**1200 chars is the size sweet spot — same as bge-small and bge-base.**
All three BGE tiers agree on this: 1200-character context windows
hit a universal rubric peak on markdown-memory, even though the
three models have 2.67× capacity differences (384 / 768 / 1024).
This is worth noting as a likely corpus-artifact: markdown-memory's
conversational notes have a natural ~1 KB paragraph granularity,
and 1200 chars roughly aligns with that.

**Overlap is still harmful at size 1200 for this corpus, even at
1024 dims.** 1200/0 → 34, 1200/120 → 26, 1200/240 → 31. The dip
at 10% (1200/120) then partial recovery at 20% (1200/240) mirrors
bge-small's behavior at the same size. A full 120-char overlap
adds duplicate near-neighbors that crowd the top-K; pushing to
240 chars of overlap creates enough distinct-but-related chunks
that *some* rubric hits come back, but the 0-overlap baseline is
still better.

**The 2000/0 cliff is the most interesting finding.** 2000/0 scores
17/60 with only 3/10 top-10 coverage — an outlier drop of 11 points
vs all other 2000/* points. Reading the per-query archive: at
2000/0, both targets go absent on 6 of 10 queries. My best guess
is that 2000-char chunks with no overlap span multiple
conversational turns in markdown-memory's transcripts and average
across unrelated topics, diluting the embedding. Once 200+ chars
of overlap is added, the duplicated context near each chunk
boundary gives the encoder enough local signal to recover.

**Overlap helps at size 800.** 800/0 → 28, 800/80 → 28, 800/160 → 30.
Same pattern as bge-small (small chunks need overlap to preserve
cross-boundary phrases); the pattern inverts at size 1200 where
overlap hurts.

**bge-large's peak closes most of the gap to bge-base.** At peak
geometry each, bge-large@1200/0 (34/60) is 2 points below
bge-base@1200/240 (36/60) and at the same top10_either (9/10).
bge-large trades 3.5× lower throughput (2.3 vs 7.95 chps) for
~94% of the rubric points of bge-base. That's a worse efficiency
curve than bge-base, but it's meaningfully less damning than the
single-point E5.3 result (31/60, 86% of bge-base) suggested.

**Throughput is ~2.5× slower than bge-small, ~3.5× slower than
bge-base.** At peak: bge-large 2.3 chps, bge-base ~7.95 chps,
bge-small 12.3 chps. Per-chunk cost is dominated by the 24-layer
encoder; batch size doesn't amortize enough.

## 3. Decision

**New default: `bge-large@1200/0`.** Updates
`Sources/VecKit/IndexingProfile.swift` (~line 185) to set
`defaultChunkOverlap: 0` (was 240).

bge-large remains registered as a built-in alias. It now ships with
a sweep-tuned default, not a seeded-from-bge-base placeholder.

**Single-point baseline preserved.** `data/retrieval-bge-large.md`
keeps the 31/60 @ 1200/240 measurement as historical data — useful
for readers tracking the E5.3 → E5.4c evolution, and as a
cross-check that the new sweep reproduces it (grid point #2, 31/60).

## 4. Follow-up

- E5.4e (corpus expansion): rerun `bge-large@1200/0` against a
  second corpus (vec's own Swift source) to see whether "1200 is
  the size sweet spot for all BGE tiers" generalises beyond
  markdown-memory, or whether it's a corpus artifact of the
  ~1 KB paragraph granularity in conversational notes.
- The 2000/0 cliff is worth re-examining on any future corpus
  that has longer topical runs (research papers, long-form prose).
  The behavior may reverse there — an embedding that averages
  across multiple paragraphs might be a feature, not a bug, for
  that corpus class.
- No size push past 2000. If a future sweep explores {2400, 2800,
  3200} against a long-form corpus, we'll know whether 1200 is a
  true peak or a markdown-memory artifact. Low priority.
