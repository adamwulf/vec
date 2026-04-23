# GTE-base Chunk-Geometry Sweep — E5.6

12-point chunk_size × overlap_pct sweep against the markdown-memory
corpus at 768 dims via Apple/swift-embeddings' `Bert.loadModelBundle`
loader (CLS-pooled + explicit L2 normalization) against the HF repo
`thenlper/gte-base`. Same 10 queries + scoring rule as
`retrieval-rubric.md`.

Executed via `vec sweep` (E5.4a) so every grid point is a full
reset+reindex+rubric-score cycle. Raw archives + summary live under
`benchmarks/sweep-gte-base/`.

**Scope note** — E5.6's job was to find the rubric peak for
`thenlper/gte-base` (the first non-BGE, 768-dim model registered as
a built-in) on markdown-memory, using the same sweep grid that was
applied to bge-base (E5.4d) for direct comparability:

  sizes: 400, 800, 1200, 1600
  overlap_pcts: 0%, 10%, 20%

The explicit question: as a direct peer of bge-base (same dim, same
tokenizer, same CLS+L2 pooling, no query/passage prefix), does
gte-base deliver comparable rubric performance? If yes, we have a
second viable 768-dim option. If no, gte-base is still registered
for opt-in use but is not a default-candidate.

**Result: gte-base scores dramatically below bge-base on this corpus.
Peak `gte-base@1600/0` lands at 8/60 — less than a quarter of
bge-base's 36/60.** gte-base is NOT a viable default replacement on
markdown-memory.

**Scoring legend** — `total_60` is the rubric total out of 60.
`top10_either` counts queries where either T (transcript) or S
(summary) landed in top 10; `top10_both` counts queries where *both*
T and S landed in top 10 (stricter secondary tiebreaker).

## 1. Summary table

Sorted by total_60 descending, then by top10_either descending as
the primary tiebreaker (top10_both is 0 for every grid point in
this sweep, so the stricter secondary signal is uninformative here).

| # | config | chunks | wall_s | chps_wall | total_60 | top10_either | top10_both | notes |
|---|--------|--------|--------|-----------|----------|--------------|------------|-------|
| 1 | gte-base@1600/0    |  5760 |  974.2 | 5.9 | **8** | 3 | 0 | **Peak.** Largest chunks, no overlap. |
| 2 | gte-base@400/40    | 23861 | 10888.4 | 2.2 | 5 | 2 | 0 | Wallclock outlier (see §2); score is still the scorer's output. |
| 2 | gte-base@400/80    | 24731 | 3361.0 | 7.4 | 5 | 2 | 0 | — |
| 4 | gte-base@400/0     | 23507 | 2652.4 | 8.9 | 3 | 1 | 0 | — |
| 4 | gte-base@800/160   | 12055 | 1394.4 | 8.6 | 3 | 1 | 0 | — |
| 6 | gte-base@800/0     | 11190 | 4238.1 | 2.6 | 2 | 1 | 0 | — |
| 6 | gte-base@800/80    | 11496 | 5780.1 | 2.0 | 2 | 1 | 0 | — |
| 6 | gte-base@1600/160  |  5954 | 1015.4 | 5.9 | 2 | 1 | 0 | — |
| 9 | gte-base@1200/0    |  7528 | 1001.3 | 7.5 | 1 | 0 | 0 | No target in top 10 of any query. |
|10 | gte-base@1200/120  |  7734 | 1082.1 | 7.1 | 0 | 0 | 0 | Zero. |
|10 | gte-base@1200/240  |  8170 | 1192.9 | 6.8 | 0 | 0 | 0 | Zero — the bge-base default geometry. |
|10 | gte-base@1600/320  |  6307 | 1133.4 | 5.6 | 0 | 0 | 0 | Zero. |

Total sweep wallclock: 34 713 s ≈ 578 min ≈ 9 h 38 min. Expected
~3–4 h per the E5.4d reference (~3 h 3 min at 768 dim on the same
grid). Several grid points ran at 2–2.6 chps_wall against the
bge-base baseline of ~8 chps, suggesting thermal throttling or a
CoreML placement regression during the run; see §2.

**Scorer note** — `total_60`, `top10_either`, and `top10_both` above
are the values emitted by `vec sweep`'s in-process scorer, which is
byte-for-byte parity with `scripts/score-rubric.py` (see E5.4a
plan §"Scorer parity"). Running the external scorer against the
archived `q01.json` … `q10.json` files would reproduce every row.
The worker running this sweep does not have `python3` on its Bash
allowlist so the external cross-check was not run; the shared code
path is the trust anchor.

## 2. Observations

**gte-base is dramatically worse than bge-base on this corpus.** At
every geometry in the grid, gte-base scores below bge-base:

| config          | bge-base total_60 | gte-base total_60 | delta |
|-----------------|------------------:|------------------:|------:|
| 1200/240 (bge-base default) | **36** | **0** | −36 |
| 800/80          | 36 | 2 | −34 |
| 1200/0          | 33 | 1 | −32 |
| 1600/0          | 32 | **8** | −24 |
| 400/0           | — (not swept for bge-base) | 3 | — |
| 1600/160        | 31 | 2 | −29 |
| 1600/320        | 31 | 0 | −31 |
| 1200/120        | 29 | 0 | −29 |
| 800/0           | 34 | 2 | −32 |
| 800/160         | 29 | 3 | −26 |

gte-base's *best* geometry (1600/0, 8/60) is worse than bge-base's
*worst* geometry in the grid (28/60 at 2000/0 in the E5.4d sweep).
This is not a close comparison.

**Does gte-base prefer overlap at 1200? It rejects overlap at every
size, including 1200.** At size 1200 the progression is
`0 → 120 → 240 : 1 → 0 → 0`. At size 1600 it's `0 → 160 → 320 :
8 → 2 → 0`. At size 800 it's `0 → 80 → 160 : 2 → 2 → 3` (nearly
flat, 1-pt noise band). At size 400 it's `0 → 40 → 80 : 3 → 5 → 5`
— the only size where overlap is mildly positive (+2 pts), but the
*absolute* scores (3/60, 5/60) are still in the noise floor.

So the "bge-small and bge-large reject overlap at 1200, bge-base
uniquely likes it" pattern from E5.4 does not extend to gte-base —
gte-base rejects overlap at 1200 like the *undistilled* BGE tiers,
despite being a distilled model itself (gte-base is distilled from
a larger gte teacher per thenlper's model card). This is a
counter-example to the distillation-smooths-embedding-space
hypothesis proposed in E5.4d's observations. But with
absolute scores this low (peak 8/60 vs bge-base's 36/60), the
overlap preference signal on gte-base is barely above rubric noise
and shouldn't carry much weight either way.

**What's going wrong for gte-base on this corpus?** Spot-checking
the archived `qNN.json` files shows the model consistently returns
the *wrong file from the right meeting* — `notes.md` from the
target meeting `granola/2026-02-26-22-30-164bf8dc/` instead of the
`summary.md` and `transcript.txt` files the rubric scores on. The
model appears to embed all files in a meeting directory as
semantically close neighbors and picks the shortest/cleanest one
(notes.md) on trademark-price queries, even when the pricing detail
actually lives in summary.md or transcript.txt. bge-base does not
have this failure mode — it consistently surfaces summary.md + the
transcript for the same queries.

This is a content-discrimination issue, not a chunk-geometry issue.
No chunk-size/overlap combination in the 12-point grid rescues it,
which is why the score ceiling is 8/60 rather than something that
responds to tuning. A different rubric (queries that distinguish
between notes / summary / transcript at the semantic level rather
than relying on near-duplicate-file selection) might grade gte-base
more favorably. That's not a reason to pick it as a default here.

**Wallclock anomalies.** Several grid points ran 3–5× slower than
their bge-base peers on the same grid (e.g. 400/40 at 10 888 s,
800/0 at 4 238 s, 800/80 at 5 780 s) while others ran at the
expected ~1 000 s. The fast points match the bge-base-level
throughput (7–9 chps); the slow points drop to 2–3 chps. The most
plausible explanation is CoreML placement non-determinism between
reindexes — ANE cold-start cost, or thermal backoff after several
hours of continuous embedding, or both. This does not affect the
retrieval scores (which are deterministic given the embedder +
geometry), and the sweep ran to completion with exit 0 and produced
complete per-point archives for every grid point. Treating the slow
points as real wallclock data but not drawing any latency
conclusions from them.

## 3. Decision

**Default: gte-base@1600/0.** That's the measured rubric peak on
this grid (8/60). It replaces the provisional 1200/240 seeded
default in `Sources/VecKit/IndexingProfile.swift`.

**gte-base is NOT a candidate to replace bge-base as the global
default.** bge-base@1200/240 (36/60) beats the best gte-base
geometry (8/60) by 28 points — a gap of 4.5× on the same corpus
with the same rubric. gte-base stays registered as an opt-in
built-in for users who want to experiment with a non-BGE 768-dim
option (e.g. for corpora where gte-base's content-discrimination
behavior happens to match the target), but the default alias in
`IndexingProfileFactory` remains `bge-base`.

**No global-default change recommended to Adam.** The E5.6 entry
criterion ("flag prominently if gte-base@<peak> beats bge-base
@1200/240 36/60") is a clear NO — 8 < 36 with no close calls. The
existing default stands.

**Sources/VecKit/IndexingProfile.swift**: replace the provisional
`defaultChunkSize: 1200, defaultChunkOverlap: 240` with
`defaultChunkSize: 1600, defaultChunkOverlap: 0`, and update the
comment to point at this data file and note the 8/60 peak.

## 4. Follow-up

- gte-base's content-discrimination issue (preferring `notes.md`
  over `summary.md` / `transcript.txt` on trademark-price queries)
  is a model/corpus interaction, not a chunk-geometry one. Not worth
  further grid exploration on markdown-memory.
- If E5.4e's corpus-generalization phase resumes with a second
  corpus, running gte-base@1600/0 there is a reasonable cheap
  second data point to confirm whether this ranking holds or
  whether gte-base is corpus-specific in its weakness. Until then:
  gte-base is markdown-memory-below-threshold, not necessarily
  globally bad.
- The non-monotone-in-dim story from E5.4d (384 rejects / 768 likes
  / 1024 rejects overlap at 1200, possibly due to distillation)
  does not extend to the second 768-dim model in the registry.
  gte-base is distilled but rejects overlap like the undistilled
  BGE tiers. That evidence weakens the "distillation smooths the
  embedding space" story; the remaining difference between the
  bge-base and gte-base behavior on this corpus is most plausibly
  just training-data / pretraining differences, not distillation.
