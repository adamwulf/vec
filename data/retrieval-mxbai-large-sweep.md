# Mxbai-large Chunk-Geometry Sweep — E5.8

12-point chunk_size × overlap_pct sweep against the markdown-memory
corpus at 1024 dims via Apple/swift-embeddings' `Bert.loadModelBundle`
loader against the HF repo `mixedbread-ai/mxbai-embed-large-v1`. CLS-
pooled with explicit L2 normalization (same pathway as bge-large) plus
an **asymmetric, query-only prefix** —
`"Represent this sentence for searching relevant passages: "` — applied
inside `MxbaiEmbedLargeEmbedder.embedQuery` per the model card. Documents
take no prefix. Same 10 queries + scoring rule as `retrieval-rubric.md`.

Executed via `vec sweep` (E5.4a) so every grid point is a full
reset+reindex+rubric-score cycle. Raw archives + summary live under
`benchmarks/sweep-mxbai-large/`.

**Scope note** — E5.8's job was to find the rubric peak for
`mixedbread-ai/mxbai-embed-large-v1` on markdown-memory using the same
12-point grid that was applied to bge-large in E5.4c, for direct
1024-dim head-to-head comparability:

  sizes: 800, 1200, 1600, 2000
  overlap_pcts: 0%, 10%, 20%

The explicit question: as a 1024-dim BERT-large peer of bge-large with
~1.5 MTEB retrieval points of headroom over bge-large in the published
benchmarks (54.7 vs 54.3), does mxbai-large deliver a rubric improvement
on markdown-memory? And does it threaten the current global default
(bge-base@1200/240, 36/60) or the new candidate default (e5-base@1200/0,
40/60)?

**Result: peak `mxbai-large@800/80` lands at 31/60, 8/10 top10_either,
4/10 top10_both. mxbai-large does NOT beat bge-large@1200/0 (34/60)
on this corpus, does NOT beat bge-base@1200/240 (36/60), and is well
behind e5-base@1200/0 (40/60). The MTEB-leaderboard headroom over
bge-large does not transfer to markdown-memory rubric performance.**

**Scoring legend** — `total_60` is the rubric total out of 60.
`top10_either` counts queries where either T (transcript) or S (summary)
landed in top 10; `top10_both` counts queries where *both* T and S
landed in top 10 (stricter secondary tiebreaker).

**Scorer note** — `total_60`, `top10_either`, and `top10_both` below are
the values emitted by `vec sweep`'s in-process scorer, which is byte-
for-byte parity with `scripts/score-rubric.py` (see E5.4a plan §"Scorer
parity"). Running the external scorer against the archived `q01.json`
… `q10.json` files would reproduce every row. The worker running this
sweep does not have `python3` on its Bash allowlist in this worktree
so the external cross-check was not re-run; the shared code path is
the trust anchor, as established for E5.6 and E5.7.

## 1. Summary table

Sorted by total_60 descending, then by top10_both descending as the
tiebreaker (strictest secondary signal).

| # | config | chunks | wall_s | chps_wall | total_60 | top10_either | top10_both | notes |
|---|--------|--------|--------|-----------|----------|--------------|------------|-------|
| 1 | mxbai-large@800/80   | 11496 |  3637.9 | 3.2 | **31** | 8 | **4** | **Peak.** Wins tiebreaker on top10_both. |
| 1 | mxbai-large@800/160  | 12055 |  3946.5 | 3.1 | **31** | 8 | 3 | Co-peak on total_60; loses tiebreaker. |
| 3 | mxbai-large@800/0    | 11190 |  3577.9 | 3.1 | 29 | 7 | 1 | Without overlap, loses 2 pts to 800/80. |
| 4 | mxbai-large@1200/0   |  7528 |  2948.5 | 2.6 | 28 | 8 | 1 | Smoke-sweep config (28/60 reproduced exactly). |
| 4 | mxbai-large@2000/200 |  4828 |  5001.7 | 1.0 | 28 | 7 | 2 | Thermal slowdown (1.0 chps vs ~2 chps neighbours); rubric unaffected. |
| 6 | mxbai-large@1600/320 |  6307 |  2944.6 | 2.1 | 27 | 7 | 2 | — |
| 6 | mxbai-large@2000/400 |  5141 |  2847.5 | 1.8 | 27 | 6 | 2 | — |
| 8 | mxbai-large@1200/240 |  8170 |  2979.2 | 2.7 | 26 | 8 | 1 | bge-base default geometry; mxbai-large loses 10 pts vs bge-base@1200/240 (36/60). |
| 9 | mxbai-large@1200/120 |  7734 |  2872.7 | 2.7 | 25 | 8 | 1 | Mid-overlap dip at size 1200, mirroring bge-large's pattern. |
|10 | mxbai-large@1600/160 |  5954 | 13051.6 | 0.5 | 24 | 7 | 0 | Severe thermal/placement slowdown (4.4× normal wall); rubric unaffected. |
|11 | mxbai-large@1600/0   |  5760 |  2592.4 | 2.2 | 23 | 6 | 0 | — |
|12 | mxbai-large@2000/0   |  4679 |  3734.7 | 1.3 | 18 | 4 | 0 | **Cliff** — same 2000/0 collapse seen in bge-large (17/60) and bge-base (28/60). |

Total sweep wallclock: 50 133 s ≈ 836 min ≈ 13 h 56 min on the same
macOS / M-series host used for every other rubric run in this tree —
~4 h longer than bge-large's E5.4c sweep (9 h 42 min) primarily due
to two thermal/placement slowdowns at 1600/160 (13 052 s, ~4.4× normal)
and 2000/200 (5 002 s, ~1.7× normal). The rubric scores at the slowed
points are unaffected by wallclock — `vec sweep` is deterministic at
the score level.

Throughput at the peak: ~3.2 chps. mxbai-large at peak runs slightly
*faster* per chunk than bge-large at peak (2.3 chps for bge-large@1200/0)
because peak geometry is at size 800 — the encoder spends less time on
each chunk. At apples-to-apples geometry (1200/0), throughput is also
slightly above bge-large (2.6 vs 2.3 chps). Both 1024-dim models are
~3-4× slower per chunk than bge-base (~8.9 chps at 1200/0).

## 2. Observations

**mxbai-large does NOT beat bge-large on markdown-memory.** Direct
1024-dim peer comparison at each model's measured peak:

| model     | peak config | total_60 | top10_either | top10_both | wall_s |
|-----------|-------------|---------:|-------------:|-----------:|-------:|
| bge-large | `1200/0`    | **34** | **9** | 3 | 3220 |
| mxbai-large | `800/80`  |   31   |   8   | **4** | 3638 |

bge-large wins 3 points on total_60 and 1 point on top10_either. mxbai
wins 1 point on top10_both. Net read: **bge-large is the better 1024-dim
default on this corpus**, primarily because it lands more queries with
*at least one* target in top 10 (9/10 vs 8/10) and scores higher on the
primary rubric. mxbai's modest top10_both edge means *when* it lands a
query it's slightly more likely to land both target files, but it
misses queries that bge-large catches. The 8/10 top10_either ceiling
is the structural problem — two queries simply do not surface a target
in top 10 at any geometry mxbai swept, where bge-large hits 9/10.

**The MTEB headroom doesn't transfer.** mxbai-large's published MTEB
retrieval is 54.7 vs bge-large's 54.3 (~0.4 pts), so a small bump is
plausible from leaderboard data, not a regression. On markdown-memory
at the rubric, mxbai loses by 3 pts (-9% relative). MTEB is a
multi-corpus average; markdown-memory is a single conversational-notes
corpus with sibling-file disambiguation as the failure mode. The two
benchmarks measure different things, and that's clearly visible here.

**Peak shifts to size 800 — different from bge-large (peak at 1200) and
bge-base (peak at 1200, co-peak at 800/80).** This is the most striking
qualitative difference between mxbai and the two BGE 1024/768-dim peers:

| size band | bge-large peak in band | bge-base peak in band | mxbai peak in band |
|-----------|-----------------------:|----------------------:|-------------------:|
| 800       | 30 (`800/160`) | **36** (`800/80`) | **31** (`800/80`) |
| 1200      | **34** (`1200/0`) | **36** (`1200/240`) | 28 (`1200/0`) |
| 1600      | 28 (`1600/0`)  | 32 (`1600/0`) | 27 (`1600/320`) |
| 2000      | 28 (`2000/400`) | 31 (`2000/400`) | 28 (`2000/200`) |

mxbai peaks in the 800 band, BGE peaks in the 1200 band. Mxbai's 1200
band tops out at 28/60 — *below* its 800 band peak by 3 pts and far
below bge-base's 1200 band (which peaks at 36 at the same size).
Hypothesis: the query-prefix injection eats more of the 512-token budget
than the prefix-free BGE pathway, so mxbai effectively sees a smaller
context window per chunk, and that pushes its peak chunk size down.
The query prefix (`"Represent this sentence for searching relevant
passages: "`) tokenizes to ~10 BERT WordPiece tokens — a meaningful
fraction of the budget on short queries.

**mxbai WANTS overlap at every chunk size.** A rare model in this
registry where overlap helps across the entire grid:

| size | 0% | 10% | 20% | overlap verdict |
|------|---:|----:|----:|-----------------|
| 800  | 29 | **31** | **31** | helps |
| 1200 | **28** | 25 | 26 | mid-overlap dip then partial recovery — like bge-large |
| 1600 | 23 | 24 | **27** | helps (monotonic) |
| 2000 | 18 | **28** | 27 | helps dramatically (10 pts at 10%) |

In the 1200 band only, the pattern matches bge-large: 0% > 10% then
20% recovers most of the gap. Outside the 1200 band, overlap is a
clean win — including the 2000 band where overlap rescues the 0%
cliff (18 → 28 → 27). Compare to bge-large which also has the same
2000/0 cliff (17/60) but recovers similarly with overlap. Compare to
bge-base which mostly likes overlap at 1200/240 only.

**The 2000/0 cliff is reproduced.** mxbai-large@2000/0 = 18/60, only
4/10 top10_either. Same pathology bge-large showed at 2000/0 (17/60,
3/10) and bge-base showed at 2000/0 (28/60, 8/10). At 2000-char
chunks with no overlap, conversational-notes content spans multiple
unrelated topics per chunk and the embedding averages across them.
The cliff is consistent across both 1024-dim models and milder but
visible in the 768-dim model — likely a corpus property of
markdown-memory's conversational granularity, not a model property.

**Score distribution is mildly anisotropic — tighter cone than e5-base
or bge-base, but wider than gte-base.** Per-query similarity scores at
the peak config (`mxbai-large@800/80`) cluster in the 0.55–0.70 range
across top 10 hits (a ~0.15 spread on the wider queries, ~0.05 on the
tighter ones). For comparison: e5-base at peak spans ~0.77–0.87 (~0.10
spread), bge-base at peak spans ~0.50–0.70 (~0.20 spread), gte-base at
peak collapses to ~0.95-0.99 with no usable discrimination (the failure
mode in E5.6). mxbai sits between bge-base and gte-base on cone width
— enough discrimination to rank, but the top-K is more crowded than
bge-base's. This shows up at the rubric as the 8/10 top10_either
ceiling: there are queries where the target file is *close enough* in
embedding space to its non-target siblings that the wrong file ranks
higher.

**Sibling-file content discrimination is mxbai's failure mode (mild
gte-base pattern).** On the literal-match probe (`"bean counter mode
trademark"`) at the smoke config (1200/0): the right *meeting* surfaces
in top 5 (granola/2026-02-26-22-30-164bf8dc), but mxbai ranks
`notes.md` at #3, `meta.md` at #12, target `summary.md` at #14, and
target `transcript.txt` outside top 20. Compare e5-base which puts
transcript.txt at #1 and summary.md at #5 on the same probe. mxbai gets
the topic right but the file-within-topic wrong — the same content-
discrimination weakness gte-base showed in E5.6, but much milder
(mxbai still produces useful rubric scores; gte-base collapsed to 8/60).

## 3. Cross-model comparison at 1024 dim

Direct 1024-dim head-to-head: bge-large vs mxbai-large at every grid
point in the shared 12-point sweep. Same dim, same Bert-large
architecture, same sweep grid, same corpus, same rubric. The only
independent variable is the model identity (and mxbai's required query
prefix).

Scores are `total_60`. Bold marks each model's peak in-table.

| size / overlap | bge-large | mxbai-large | delta (mxbai − bge-large) |
|----------------|----------:|------------:|--------------------------:|
| 800 / 0        | 28 | 29 | +1 |
| 800 / 80       | 28 | **31** | +3 |
| 800 / 160      | 30 | **31** | +1 |
| 1200 / 0       | **34** | 28 | −6 |
| 1200 / 120     | 26 | 25 | −1 |
| 1200 / 240     | 31 | 26 | −5 |
| 1600 / 0       | 28 | 23 | −5 |
| 1600 / 160     | 25 | 24 | −1 |
| 1600 / 320     | 24 | 27 | +3 |
| 2000 / 0       | 17 | 18 | +1 |
| 2000 / 200     | 24 | 28 | +4 |
| 2000 / 400     | 28 | 27 | −1 |

**Geometry-shift readout.** mxbai is *competitive or slightly better*
than bge-large at small chunks (size 800: +1 to +3) and at large chunks
with overlap (2000/200: +4). It loses badly at the 1200 band (−5 to −6
across all three overlap levels) and at 1600/0 (−5). The bge-large peak
config (1200/0) is close to the worst geometry for mxbai (−6). And the
mxbai peak config (800/80) is competitive but not transformative for
bge-large (+3). No grid point gives mxbai a meaningful win over
bge-large.

**Aggregate over all 12 points.** Sum of `total_60`: bge-large = 323,
mxbai-large = 317. Net delta −6 in mxbai's favour-against (bge-large
totals 6 pts more across the grid). That's a small but consistent
preference for bge-large across the geometry space, not just at the
peak.

## 4. Cross-model comparison vs current defaults

Where mxbai-large@peak sits against the registry's defaults on
markdown-memory:

| model | alias default | total_60 | top10_either | top10_both | dim | wall_s @ peak |
|-------|---------------|---------:|-------------:|-----------:|----:|--------------:|
| e5-base   | `1200/0`     | **40** | 9 | **6** |  768 | 1025 |
| bge-base  | `1200/240`   |   36   | 9 | 3 |  768 | 1003 |
| bge-large | `1200/0`     |   34   | 9 | 3 | 1024 | 3220 |
| **mxbai-large** | **`800/80`** | **31** | 8 | 4 | **1024** | **3638** |
| bge-small | `1200/0`     |   30   | 9 | 4 |  384 |  ~692 (single-point) |
| nomic     | `1200/240`   |   35   | 3 | — |  768 | — |

**mxbai-large is the worst-scoring sweep-tuned default in the 1024/768-dim
tier.** It's beaten by every other 1024-dim or 768-dim sweep-tuned alias
on this corpus, and barely edges out bge-small (the 384-dim "fast tier"
option) by 1 point on total_60. Per-rubric-point cost is the worst in
the registry: 117 s/point at peak (3638 / 31), vs bge-large 95 s/point
(3220 / 34), bge-base 28 s/point (1003 / 36), e5-base 26 s/point
(1025 / 40), bge-small ~23 s/point.

## 5. Decision

**Default: `mxbai-large@800/80`.** That's the measured rubric peak on
this grid (31/60, 8/10 top10_either, 4/10 top10_both, 3638 s wall). It
replaces the provisional `1200/0` seeded default in
`Sources/VecKit/IndexingProfile.swift`. `800/160` is the co-peak on
total_60 but loses the tiebreaker on top10_both (3 vs 4); it's documented
here as the co-peak for future reference.

**No global-default change.** mxbai-large does not beat the current
global default (bge-base@1200/240, 36/60) and does not beat the
candidate global default (e5-base@1200/0, 40/60). The model is retained
as an opt-in "max quality, slow tier" alongside bge-large but is *not*
a default candidate on markdown-memory. If the candidate global-default
flip from bge-base to e5-base is approved, mxbai-large remains a
secondary option for users who explicitly want a different 1024-dim
model than bge-large; the geometry default (800/80) and the peak score
(31/60) are now stamped as honest measurements rather than the
provisional 1200/0 seed.

### Comparison against the report criteria

The E5.8 plan asked for explicit Y/N on each comparison:

- **Beats bge-base@1200/240 (36/60)?** — **NO.** −5 on total_60 (31 vs
  36). +1 on top10_both (4 vs 3) is an interesting but small offset.
- **Beats e5-base@1200/0 (40/60)?** — **NO.** −9 on total_60 (31 vs
  40). −2 on top10_both (4 vs 6).
- **Beats bge-large@1200/0 (34/60)?** — **NO.** −3 on total_60 (31 vs
  34). +1 on top10_both (4 vs 3) — same secondary-metric offset as
  vs bge-base.

**Nothing flagged for global-default review.** The "candidate global-
default" question that E5.7 raised (e5-base over bge-base) remains
open and is unaffected by this experiment. mxbai is the wrong-shaped
default for this corpus.

## 6. Follow-up

- **No further chunk-geometry sweeping for mxbai-large is warranted on
  markdown-memory.** The 12-point grid covers {800,1200,1600,2000} ×
  {0,10,20%}, the same shape as bge-large's E5.4c. The peak is in the
  800 band with overlap, well-characterized; nothing in the grid
  suggests a hidden config outside the swept range.
- **Corpus-generalization (E5.4e, deferred).** When the second-corpus
  rubric materializes, rerun mxbai-large@800/80 alongside the BGE
  winners. The MTEB-leaderboard headroom over bge-large might transfer
  on a different corpus (e.g. one without sibling-file disambiguation
  as the dominant retrieval challenge); markdown-memory's conversational-
  notes structure may be a worst-case for this model.
- **The query-prefix budget hypothesis is testable.** If a future
  experiment ablates mxbai with the prefix omitted from queries (against
  the model card's recommendation), the predicted outcome is *worse*
  retrieval on most queries with maybe a small win on already-formal
  queries that look like passages. That experiment would distinguish
  "prefix is the right call but eats budget" from "prefix is misaligned
  for this corpus."
- **The 2000/0 cliff is now reproduced across three Bert-family models**
  (bge-base 28/60, bge-large 17/60, mxbai 18/60). It is a corpus
  property of markdown-memory's ~1 KB conversational-turn granularity,
  not a model artifact. Worth carrying forward to any future corpus
  rubric as an expected behaviour to verify whether it generalizes
  (long-form prose corpora may invert the pattern).
- **Asymmetric prefix is the only registry case to date.** mxbai joins
  the registry as the first embedder with a query-only prefix (BGE/GTE
  apply none, e5-base applies both sides, mxbai applies query-only).
  The `Embedder` protocol surface accommodates this without changes;
  documented in `MxbaiEmbedLargeEmbedder.swift` for future readers.
