# BGE-base Chunk-Geometry Sweep — E5.4d

12-point chunk_size × overlap_pct sweep against the markdown-memory
corpus at 768 dims via Apple/swift-embeddings' `Bert.loadModelBundle`
loader (CLS-pooled + explicit L2 normalization). Same 10 queries +
scoring rule as `retrieval-rubric.md`.

Executed via `vec sweep` (E5.4a). Raw archives + summary live under
`benchmarks/sweep-bge-base/`.

**Scope note** — E5.4d's job was to *confirm* whether the existing
bge-base default (1200/240, recorded as 36/60 in
`data/retrieval-rubric.md`) is still the rubric peak, given that
bge-small and bge-large both turned out to peak at 1200/0 rather
than 1200/240 (E5.4b, E5.4c). The explicit hypothesis: if
bge-base@1200/0 beats 1200/240, then "overlap hurts at size 1200"
is a BGE-family pattern. If 1200/240 beats 1200/0, the existing
default is right and the pattern is model-specific.

**Result: 1200/240 is correct for bge-base. Overlap HELPS at 1200
for this model — the opposite of bge-small and bge-large.**

**Scoring legend** — `total_60` is the rubric total out of 60.
`top10_either` counts queries where either T or S landed in top 10;
`top10_both` counts queries where *both* T and S landed in top 10
(stricter secondary tiebreaker).

## 1. Summary table

Sorted by total_60 descending, then by top10_both descending as the
tiebreaker (strictest secondary signal).

| # | config | chunks | wall_s | chps_wall | total_60 | top10_either | top10_both | notes |
|---|--------|--------|--------|-----------|----------|--------------|------------|-------|
| 1 | bge-base@800/80    | 11496 | 1049.6 | 11.0 | **36** | 9 | **5** | Tied peak on total, WINS on top10_both. |
| 1 | bge-base@1200/240  |  8170 | 1003.2 |  8.1 | **36** | 9 | 3 | Tied peak on total; matches historical E4 rubric. Kept as default (see §3). |
| 3 | bge-base@800/0     | 11190 |  969.6 | 11.5 | 34 | 9 | 4 | — |
| 4 | bge-base@1200/0    |  7528 |  850.2 |  8.9 | 33 | 9 | 3 | If bge-small/large pattern had held, this would've peaked. It didn't. |
| 5 | bge-base@1600/0    |  5760 |  856.8 |  6.7 | 32 | 9 | 0 | — |
| 6 | bge-base@1600/160  |  5954 |  843.4 |  7.1 | 31 | 9 | 1 | — |
| 6 | bge-base@1600/320  |  6307 |  982.1 |  6.4 | 31 | 9 | 1 | — |
| 6 | bge-base@2000/400  |  5141 |  852.1 |  6.0 | 31 | 9 | 1 | — |
| 9 | bge-base@2000/200  |  4828 |  868.8 |  5.6 | 30 | 7 | 3 | — |
|10 | bge-base@800/160   | 12055 | 1051.5 | 11.5 | 29 | 8 | 1 | — |
|10 | bge-base@1200/120  |  7734 |  871.6 |  8.9 | 29 | 9 | 1 | — |
|12 | bge-base@2000/0    |  4679 |  797.6 |  5.9 | 28 | 8 | 0 | No 2000/0 cliff for bge-base (unlike bge-large's 17/60). 768-dim absorbs the cross-topic averaging better. |

Total sweep wallclock: 10 996 s ≈ 183 min ≈ 3 h 3 min.

## 2. Observations

**1200/240 and 800/80 are tied for peak at 36/60.** Same total,
same top10_either (9/10). They diverge on `top10_both`: 1200/240
gets 3/10, 800/80 gets 5/10 — meaning 800/80 lands *both* targets
in top 10 more often. That's a stricter retrieval signal and
arguably "better" by the rubric's own logic, but the primary score
is a tie.

**bge-base WANTS overlap at size 1200. bge-small and bge-large
DON'T.** This is the most interesting cross-model result of the
whole sweep:

| embedder | 1200/0 | 1200/120 | 1200/240 | overlap verdict |
|----------|--------|----------|----------|-----------------|
| bge-small (384d)  | **30** | 21 | 25 | hurts |
| bge-base  (768d)  |   33   | 29 | **36** | **helps** |
| bge-large (1024d) | **34** | 26 | 31 | hurts |

The pattern is not monotone in embedding dimension. bge-base is
the middle tier and the only one that benefits from overlap at
size 1200. Possible reasons:
- bge-base is distilled (teacher-student training against a larger
  checkpoint), which may make its embedding space smoother and more
  tolerant of near-duplicate neighbors at the top-K boundary.
- bge-small and bge-large have less training-data overlap with the
  distillation objective and so behave differently.
- Or: the three models were trained on different corpus mixes and
  this is just noise on one specific evaluation.

The retrieval community will have stronger priors on this than we
do from 10 queries. For now, the empirical result holds: bge-base's
optimal chunk geometry is 1200/240, *different* from its siblings'
1200/0. The existing default stands.

**No 2000/0 cliff for bge-base.** bge-large@2000/0 was a dramatic
17/60, 3/10 top-10 cliff. bge-base@2000/0 is 28/60, 8/10 — a
modest drop from peak but no cliff. The 768-dim embedding apparently
handles cross-topic averaging (what we hypothesised was behind
bge-large's cliff) better than the 1024-dim space does. This is
counter-intuitive (more capacity should handle more diluted content
*better*, not worse), but it's what the data says.

**At size 800, bge-base wants 10% overlap (800/80, 36/60) and 0%
is a close second (800/0, 34/60); 20% is a sharp drop (800/160,
29/60).** Overlap is welcome but a little goes a long way.

## 3. Decision

**Default unchanged: bge-base@1200/240.**

The sweep produced a two-way tie at the primary rubric metric
(total_60=36, top10_either=9/10). 800/80 is arguably a better
config by the stricter `top10_both=5/10` tiebreaker, but:

1. Primary metric is tied — changing a documented, historical
   default on a softer secondary signal creates churn for no clear
   user win.
2. `benchmarks/bge-base-1200-240/` and every prior rubric doc in
   `data/` assume 1200/240 is the bge-base default. Changing it
   would require doc updates that the evidence doesn't support.
3. Throughput is a near-wash (11.0 vs 8.1 chps — 800/80 is ~35%
   faster, which is mildly in 800/80's favor, but again on a
   tie-primary-metric basis the simpler choice is "don't churn").

800/80 is documented here as a co-peak finding for future reference.
If a subsequent corpus sweep (E5.4e) demonstrates a clear 800/80
advantage, the default can revisit then.

**Sources/VecKit/IndexingProfile.swift**: no change. The comment
for bge-base already references 1200/240 and mentions the E4 rubric
(where 36/60 was first established); no additional edits needed.

## 4. Follow-up

- E5.4e (corpus expansion): rerun **both** candidates
  (`bge-base@1200/240` and `bge-base@800/80`) against vec's own
  Swift source tree. If 800/80 clearly outperforms 1200/240 on a
  second corpus, revisit the default. If they tie again, primary
  remains 1200/240.
- The "bge-base uniquely benefits from overlap at 1200" finding
  is worth flagging in `plan.md` as a Phase E lesson — it's
  non-obvious and contradicts the otherwise-clean bge-small/large
  pattern.
