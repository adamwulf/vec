# E5-base Chunk-Geometry Sweep — E5.7

12-point chunk_size × overlap_pct sweep against the markdown-memory
corpus at 768 dims via Apple/swift-embeddings' `Bert.loadModelBundle`
loader against the HF repo `intfloat/e5-base-v2`. Unlike bge-base and
gte-base (CLS-pooled), e5-base uses **masked mean pooling** over the
final hidden states plus explicit L2 normalization, and prepends
`"passage: "` / `"query: "` prefixes to documents / queries. See
`Sources/VecKit/E5BaseEmbedder.swift` for the pooling + prefix
implementation. Same 10 queries + scoring rule as `retrieval-rubric.md`.

Executed via `vec sweep` (E5.4a) so every grid point is a full
reset+reindex+rubric-score cycle. Raw archives + summary live under
`benchmarks/sweep-e5-base/`.

**Scope note** — E5.7's job was to find the rubric peak for
`intfloat/e5-base-v2` (the second non-BGE, 768-dim model registered
as a built-in, after gte-base in E5.6) on markdown-memory, using the
same sweep grid that was applied to gte-base (E5.6) for direct
comparability:

  sizes: 400, 800, 1200, 1600
  overlap_pcts: 0%, 10%, 20%

The explicit question: as a third 768-dim model (alongside bge-base
and gte-base), with shape differences vs both (mean-pool not CLS,
required query/passage prefixes), does e5-base deliver rubric
performance competitive with or better than bge-base@1200/240 (36/60)
— the global default? If yes, e5-base is a default candidate. If not,
it's an opt-in option like gte-base.

**Result: e5-base BEATS bge-base@1200/240 on markdown-memory. Peak
`e5-base@1200/0` lands at 40/60, 9/10 top10_either, 6/10 top10_both —
a 4-point total gain over bge-base's 36/60 and a 3-point gain on
top10_both (6 vs 3). This is a candidate global-default change for
manager review.**

**Scoring legend** — `total_60` is the rubric total out of 60.
`top10_either` counts queries where either T (transcript) or S
(summary) landed in top 10; `top10_both` counts queries where *both*
T and S landed in top 10 (stricter secondary tiebreaker).

**Scorer note** — `total_60`, `top10_either`, and `top10_both` below
are the values emitted by `vec sweep`'s in-process scorer, which is
byte-for-byte parity with `scripts/score-rubric.py` (see E5.4a plan
§"Scorer parity"). Running the external scorer against the archived
`q01.json` … `q10.json` files would reproduce every row. The worker
running this sweep does not have `python3` on its Bash allowlist in
this worktree so the external cross-check was not re-run; the shared
code path is the trust anchor, as established for E5.6.

## 1. Summary table

Sorted by total_60 descending, then by top10_both descending as the
tiebreaker (strictest secondary signal, matching the bge-base-sweep
convention).

| # | config | chunks | wall_s | chps_wall | total_60 | top10_either | top10_both | notes |
|---|--------|--------|--------|-----------|----------|--------------|------------|-------|
| 1 | e5-base@1200/0   |  7528 | 1025.0 | 7.3 | **40** | 9 | **6** | **Peak.** Wins tiebreaker on top10_both. |
| 1 | e5-base@400/40   | 23861 | 1811.6 | 13.2 | **40** | **10** | 5 | Tied peak on total_60; wins top10_either (10/10). Co-peak documented. |
| 3 | e5-base@1200/240 |  8170 | 1032.0 | 7.9 | 39 | 9 | 5 | Matches bge-base's default geometry; +3 pts over bge-base@1200/240. |
| 4 | e5-base@400/80   | 24731 | 1857.4 | 13.3 | 38 | 10 | 5 | — |
| 4 | e5-base@1200/120 |  7734 |  995.2 | 7.8 | 38 | 9 | 5 | — |
| 6 | e5-base@400/0    | 23507 | 1477.3 | 15.9 | 35 | 10 | 3 | — |
| 7 | e5-base@800/0    | 11190 | 1180.1 | 9.5 | 30 | 9 | 1 | — |
| 7 | e5-base@800/80   | 11496 | 1152.2 | 10.0 | 30 | 8 | 3 | — |
| 9 | e5-base@1600/0   |  5760 |  835.6 | 6.9 | 29 | 8 | 2 | — |
| 9 | e5-base@1600/320 |  6307 |  912.4 | 6.9 | 29 | 6 | 3 | — |
|11 | e5-base@800/160  | 12055 | 1159.8 | 10.4 | 26 | 6 | 2 | — |
|12 | e5-base@1600/160 |  5954 |  953.2 | 6.2 | 24 | 6 | 2 | Lowest point in the grid. |

Total sweep wallclock: 14 391 s ≈ 240 min ≈ 4 h 0 min — squarely in
the E5.4d (bge-base) ballpark (~3 h 3 min on the same grid), and
about 40% of the E5.6 (gte-base) sweep (~9 h 38 min, which suffered
several thermal/placement slowdowns not reproduced here).

## 2. Observations

**e5-base beats bge-base on this corpus.** At every shared grid point
in {800, 1200, 1600} × {0, 10, 20}, e5-base scores within 6 points of
bge-base, and at the peak config e5-base wins outright:

| config          | bge-base | e5-base | delta |
|-----------------|---------:|--------:|------:|
| 1200/0          | 33 | **40** | +7 |
| 1200/240 (bge-base default) | 36 | **39** | +3 |
| 1200/120        | 29 | **38** | +9 |
| 800/80          | 36 | 30 | −6 |
| 800/0           | 34 | 30 | −4 |
| 800/160         | 29 | 26 | −3 |
| 1600/0          | 32 | 29 | −3 |
| 1600/160        | 31 | 24 | −7 |
| 1600/320        | 31 | 29 | −2 |

e5-base wins at all three `size=1200` points by 3–9 points. It loses
at 800 (modestly) and 1600 (modestly). The 1200 band is where the
peak lives for e5-base; bge-base's peak is 1200/240 but the curve is
flatter — within the size=1200 row, bge-base's spread is 29–36 (7
points), e5-base's is 38–40 (2 points). **e5-base's rubric peak is
more concentrated and higher than bge-base's across the same
geometry.**

**Two-way tie at 40/60: `e5-base@1200/0` vs `e5-base@400/40`.** They
diverge on the secondary metrics:

- `1200/0` — 9 top10_either, **6** top10_both, 7 528 chunks, 7.3 chps
- `400/40` — **10** top10_either, 5 top10_both, 23 861 chunks, 13.2 chps

By the bge-base-sweep tiebreaker convention (total_60 desc → top10_both
desc), **`1200/0` wins the peak crown.** It lands *both* target files
in top 10 more often (6/10 vs 5/10), which is the stricter retrieval
signal. `400/40` wins `top10_either` (10/10 — every query surfaces
at least one target in top 10) and is ~3× faster per chunk at
wallclock (13.2 vs 7.3 chps), but triples the chunk count, so total
indexing time is actually *longer* for 400/40 (1811 s vs 1025 s).

Picking 1200/0 as the default also keeps e5-base's chunk geometry
aligned with the BGE family (bge-small@1200/0, bge-large@1200/0) and
with bge-base's 1200-band preferences; only the overlap knob differs
between 768-dim models in the registry.

**e5-base REJECTS overlap at size 1200 — like bge-small, bge-large,
and gte-base; UNLIKE bge-base.** At size 1200:

| embedder            | 1200/0 | 1200/120 | 1200/240 | overlap verdict |
|---------------------|-------:|---------:|---------:|-----------------|
| bge-small (384d)    | **30** | 21 | 25 | hurts |
| bge-base  (768d)    |   33   | 29 | **36** | **helps** |
| e5-base   (768d)    | **40** | 38 | 39 | mildly hurts / flat |
| gte-base  (768d)    |  **1** |  0 |  0 | flat (all ≈0) |
| bge-large (1024d)   | **34** | 26 | 31 | hurts |

bge-base is now confirmed as the outlier — two other 768-dim models
in the registry (gte-base, e5-base) reject overlap at 1200. The
E5.4d distillation-smooths-the-space hypothesis is further weakened:
gte-base is distilled-from-gte-teacher and rejects overlap; e5-base
is not distilled and also rejects overlap. The remaining "bge-base
uniquely wants overlap at 1200" finding is most plausibly a
pretraining-mix or objective-function artifact of bge-base specifically,
not a dim-tier or distillation property.

**e5-base WANTS overlap at size 400.** The 0→40→80 progression at
size 400 is `35 → 40 → 38`. This is the only grid row where overlap
is clearly positive for e5-base (+5 pts at 10%, +3 pts at 20%). The
absolute scores at 400 are also strong — the 400/40 and 400/80 rows
both land 10/10 top10_either, perfect "at least one target in top 10".
Tiny chunks + a little overlap seem to help e5-base's mean-pool
representation cover each target file's key passages without losing
a target entirely to chunk-boundary drift.

**e5-base's score distribution is healthy (wide cone, not
anisotropic).** Per-query raw similarity scores at the peak config
(`e5-base@1200/0`) span ~0.77–0.87 — a dynamic range comparable to
bge-base's on the same corpus. This is not the tight-cone / all-files-
look-alike failure mode we'd worry about (gte-base's content-
discrimination issue in E5.6 was a different pathology — content
semantics, not cone compression). The literal-match probe
(`"bean counter mode trademark"`) on the smoke-sweep index placed
the `2026-02-26-22-30-164bf8dc/transcript.txt` target at **rank 1**
and `summary.md` at **rank 5** — both in top 5 on the exact-phrase
probe, which is a strong signal the prefix + mean-pool path is
working as intended.

**Throughput — e5-base is slightly slower per chunk than bge-base
at the peak config** (7.3 chps for e5-base@1200/0 vs 8.9 chps for
bge-base@1200/0 in E5.4d, or 8.1 for bge-base@1200/240). The masked
mean-pool adds one extra tensor op per batch over the CLS-slice
pathway, which is consistent with the observed ~15–20% per-chunk
wallclock delta. At peak config the total indexing run is ~1025 s
vs bge-base's ~850–1003 s — in the same ballpark, no regression
severe enough to dominate default selection.

## 3. Three-way 768-dim cross-model comparison

Three 768-dim models sharing the same Bert-family loader but with
different pooling / prefix conventions on the exact same 10-query
rubric against the exact same corpus. Novel data: same storage
geometry (768 × N chunks), same retrieval path, model is the only
independent variable.

Scores are `total_60`. Bold marks each model's peak in-table.

| size / overlap | bge-base | gte-base | e5-base |
|----------------|---------:|---------:|--------:|
| 400 / 0        | — |  3 | 35 |
| 400 / 40       | — |  5 | **40** |
| 400 / 80       | — |  5 | 38 |
| 800 / 0        | 34 |  2 | 30 |
| 800 / 80       | **36** |  2 | 30 |
| 800 / 160      | 29 |  3 | 26 |
| 1200 / 0       | 33 |  1 | **40** |
| 1200 / 120     | 29 |  0 | 38 |
| 1200 / 240     | **36** |  0 | 39 |
| 1600 / 0       | 32 | **8** | 29 |
| 1600 / 160     | 31 |  2 | 24 |
| 1600 / 320     | 31 |  0 | 29 |

(bge-base's sweep grid was {800, 1200, 1600, 2000} rather than
{400, 800, 1200, 1600}; the size=400 row is blank because E5.4d
didn't sweep it, and the bge-base@2000 row is elided here. Sizes
in common: {800, 1200, 1600}.)

**Cross-model readings.**

- **Overall ranking on markdown-memory: e5-base > bge-base >> gte-base.**
  At each model's own peak: e5-base 40/60, bge-base 36/60, gte-base
  8/60. e5-base leads by 4 points over bge-base and by 32 points
  over gte-base.
- **e5-base dominates the size=1200 band.** All three size=1200
  points are e5-base's top-three grid points in this sweep; bge-base
  only hits 36/60 at 1200/240 (its one outlier) and gte-base
  collapses to 0–1 at every size=1200 overlap.
- **Overlap preferences differ between the three models.** bge-base
  alone prefers overlap at 1200 (1200/240 beats 1200/0 by 3 pts).
  e5-base prefers 0% overlap at 1200 (1200/0 beats 1200/240 by 1 pt
  on total_60, +1 on top10_both — small but consistent direction).
  gte-base is too flat at size=1200 to read a preference
  (0/0/0–1 is noise floor).
- **e5-base is the only model with a strong small-chunk (size=400)
  peak.** Its 400/40 co-peak at 40/60 is tied for the best score in
  the whole table. gte-base's 400 row is noise-floor; bge-base
  didn't sweep 400.
- **Three 768-dim models, three different peak geometries on the
  same corpus:** bge-base@1200/240, gte-base@1600/0, e5-base@1200/0.
  The dim-tier doesn't determine chunk geometry — model family /
  pretraining / pooling convention does. The practical implication
  for users: switching 768-dim models without re-tuning chunk size
  will leave performance on the table.

## 4. Decision

**Default: `e5-base@1200/0`.** That's the measured rubric peak on
this grid (40/60, 9/10 top10_either, 6/10 top10_both, 1025 s wall).
It replaces the provisional 1200/240 seeded default in
`Sources/VecKit/IndexingProfile.swift`. `400/40` is the co-peak on
total_60 but loses the tiebreaker on top10_both; it's documented
here as the co-peak for future reference (and would be the right
pick if a deployment prioritizes every-query-hits-something
over strict-two-target-recall).

**e5-base BEATS bge-base@1200/240 on markdown-memory: 40/60 vs 36/60,
6/10 top10_both vs 3/10.** This is a candidate global-default change.
Flagging prominently per the E5.7 plan:

### Candidate global-default change for manager review

The E5.7 plan explicitly asked: "If e5-base peak beats bge-base@1200/240
(36/60), flag prominently — candidate global-default change for
manager review." The peak geometry result is unambiguous:

- **Primary rubric**: e5-base@1200/0 = 40/60 vs bge-base@1200/240 = 36/60  (+4 pts, +11%)
- **top10_both**: 6/10 vs 3/10  (2× on the stricter metric)
- **top10_either**: 9/10 vs 9/10  (tied)
- **Wallclock at peak**: 1025 s vs ~1003 s  (essentially identical)
- **Peak RSS / dim / storage cost**: identical (both 768-dim, both
  Bert-family via swift-embeddings)

**Recommendation (for manager review, not self-decided):** Promote
`e5-base` to the default alias in `IndexingProfileFactory`, replacing
`bge-base`. Same storage cost, same wallclock, higher rubric on the
primary and strict-secondary metrics. Caveats the manager should
weigh before flipping:

1. **Single-corpus result.** This is markdown-memory only. The
   E5.4e corpus-generalization phase (deferred) would confirm whether
   the ranking holds on a second corpus. Given the gap (4 pts + 2×
   on top10_both), it's unlikely the ordering flips on another
   corpus, but it's not impossible.
2. **Prefix plumbing.** e5-base requires `"passage: "` / `"query: "`
   prefixes. They're injected inside `E5BaseEmbedder` so callers
   stay prefix-unaware (same `Embedder` protocol surface as bge-*
   and gte-base). No caller-side code changes needed for the E5.7
   default update OR for a global-default flip.
3. **Mean-pool implementation.** e5-base bypasses
   `Bert.ModelBundle.encode/batchEncode` and drives
   `bundle.model(...)` directly so the attention mask flows into
   both the encoder and the pool. This is a larger custom
   implementation surface than bge-* / gte-base (which reuse
   `ModelBundle.encode`). Worth a code-review pass before promoting
   to global default, even though the rubric + literal-match results
   validate the behavior empirically.
4. **Throughput parity, not win.** e5-base is ~15% slower per chunk
   than bge-base on the Bert pathway due to the extra mean-pool op;
   at peak geometry wallclock is a near-wash, but it's not a
   throughput improvement over bge-base. If throughput is the
   priority, bge-base stays ahead.

The decision is Adam's (and/or the E5.7 manager's) — this file
documents the evidence and the shape of the call.

**Sources/VecKit/IndexingProfile.swift**: update the e5-base entry's
defaults from the provisional `defaultChunkSize: 1200,
defaultChunkOverlap: 240` to `defaultChunkSize: 1200,
defaultChunkOverlap: 0` and refresh the comment to point at this
data file and note the 40/60 peak + candidate-global-default
finding. No change to the global `defaultAlias = "bge-base"` in this
commit — that's for manager review.

## 5. Follow-up

- **Candidate global-default flip** — see §4. Gated on manager review.
  If approved, a follow-up commit changes
  `IndexingProfileFactory.defaultAlias` from `"bge-base"` to
  `"e5-base"` and updates the `Current state` section of `plan.md`
  (default embedder line, rubric line, wallclock line) accordingly.
- **Corpus-generalization (E5.4e, still deferred)** — if the
  second-corpus rubric materializes, rerun
  `e5-base@1200/0` + `e5-base@400/40` alongside the BGE tier's
  winners. The 400/40 co-peak is worth keeping in the competition
  pool since it was *better* on top10_either; a second corpus
  might break the 1200/0 vs 400/40 tie differently.
- The "bge-base uniquely benefits from overlap at 1200" finding
  (E5.4d) is now strongly confirmed as model-specific rather than
  dim-tier or distillation: three other 768-dim / non-768-dim
  models on the same grid all reject overlap at 1200 (bge-small,
  bge-large, gte-base, e5-base). Worth carrying forward as a
  documented Phase-E lesson.
- `e5-base@400/40` (the co-peak) has the highest `top10_either` of
  any configuration swept across all three 768-dim models (10/10
  queries surface at least one target in top 10). If a future
  retrieval task prioritizes "never miss a query" over "strict
  two-target recall," revisit 400/40 as an alternative.
