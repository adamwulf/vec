# E5-base Peak-Refinement Sweep — E5.9a

9-point mini-sweep around `e5-base@1200/0` — the measured peak from
the E5.7 coarse grid (`data/retrieval-e5-base-sweep.md`). The coarse
grid had wide steps (size ∈ {400, 800, 1200, 1600}, overlap_pct ∈
{0%, 10%, 20%}); this refinement probes the immediate neighborhood
to answer "is 1200/0 truly the peak, or is a ±100-size / 5%-overlap
neighbor hiding a better configuration?"

Executed via `vec sweep` (E5.4a). Raw archives + summary live under
`benchmarks/sweep-e5-base-refine/`.

**Scope note** — This is a refinement, not a full characterization.
Grid:

  sizes: 1100, 1200, 1300
  overlap_pcts: 0%, 5%, 10%

Points `1200/0` and `1200/120` are in both the E5.7 coarse grid and
this refinement grid, providing a 2-point reproducibility anchor.

**Result: the peak stays at `e5-base@1200/0` (40/60, 9/10 top10_either,
6/10 top10_both).** No neighbor beats it on the primary metric.
Runner-up `1100/110` lands at 39/60 (−1 pt, +0 top10_either, −1
top10_both). The peak is a single-point peak, not a plateau — every
refined neighbor scores strictly lower on total_60.

**Scoring legend** — `total_60` is the rubric total out of 60.
`top10_either` counts queries where either T (transcript) or S
(summary) landed in top 10; `top10_both` counts queries where *both*
T and S landed in top 10 (stricter secondary tiebreaker).

**Scorer note** — `total_60`, `top10_either`, and `top10_both` below
are the values emitted by `vec sweep`'s in-process scorer, which is
byte-for-byte parity with `scripts/score-rubric.py` (see E5.4a plan
§"Scorer parity" and `SweepCommandTests.testScoreArchive_matchesReferenceData`).
Running the external scorer against the archived `q01.json` …
`q10.json` files would reproduce every row. The worker running this
sweep does not have `python3` on its Bash allowlist in this worktree
so the external cross-check was not re-run; the shared code path is
the trust anchor, as established for E5.6 and E5.7.

## 1. Summary table

Sorted by total_60 descending, then top10_both descending as the
tiebreaker.

| # | config | chunks | wall_s | chps_wall | total_60 | top10_either | top10_both | notes |
|---|--------|--------|--------|-----------|----------|--------------|------------|-------|
| 1 | e5-base@1200/0   | 7528 |  861.4 | 8.7 | **40** | 9 | **6** | **Peak.** Reproduces E5.7's 40/60. |
| 2 | e5-base@1100/110 | 8451 | 1167.0 | 7.2 | 39 | 9 | 5 | Strongest refinement-specific neighbor. |
| 3 | e5-base@1200/60  | 7598 |  987.6 | 7.7 | 38 | 9 | 5 | New point; 5% overlap never tested in coarse grid. |
| 3 | e5-base@1200/120 | 7734 |  984.1 | 7.9 | 38 | 9 | 5 | Reproduces E5.7's 38/60 exactly. |
| 5 | e5-base@1100/55  | 8274 | 1113.2 | 7.4 | 34 | 9 | 3 | — |
| 5 | e5-base@1300/0   | 6934 | 1084.8 | 6.4 | 34 | 8 | 3 | — |
| 7 | e5-base@1300/130 | 7378 | 1016.3 | 7.3 | 33 | 8 | 4 | — |
| 7 | e5-base@1100/0   | 8170 |  836.0 | 9.8 | 33 | 8 | 2 | — |
| 9 | e5-base@1300/65  | 7023 |  897.6 | 7.8 | 33 | 7 | 3 | Lowest point in the grid. |

Total sweep wallclock: 8 948 s ≈ 149 min ≈ 2 h 29 min. Per-chunk
throughput holds around 7–10 chps across the grid, consistent with
E5.7's measurements for e5-base at the same size band.

## 2. Consistency check vs E5.7 coarse sweep

Two points appear in both grids. Reproducibility:

| config     | E5.7 coarse                  | E5.9a refine                 | delta on total_60 |
|------------|------------------------------|------------------------------|------------------:|
| 1200/0     | 40/60, 9 either, 6 both      | 40/60, 9 either, 6 both      | **0** |
| 1200/120   | 38/60, 9 either, 5 both      | 38/60, 9 either, 5 both      | **0** |

Bit-exact reproduction on both total_60 and the secondary metrics,
and chunk counts (7528 / 7734) match exactly. The only drift is in
wallclock (e.g. 1025 s → 861 s for 1200/0, ~16% faster on the
refinement run) — which is expected variance from CoreML/ANE
placement and thermal state, and has no bearing on rubric scores
since the scorer is deterministic given the index contents. **No
reproducibility concern; peak is genuine, not grid-noise.**

## 3. Refinement-grid cross-reference with E5.7

Side-by-side where the grids overlap or are directly adjacent. E5.7
coarse values in parens where a matching point exists in that grid;
refinement values outside parens. 5% overlap is a refinement-only
band (not present in the coarse 0/10/20% spacing).

| size / overlap_pct | E5.7 coarse | E5.9a refine |
|--------------------|------------:|-------------:|
| 1100 / 0           | —           | 33 |
| 1100 / 5           | —           | 34 |
| 1100 / 10          | —           | 39 |
| 1200 / 0           | **40**      | **40** (match) |
| 1200 / 5           | —           | 38 |
| 1200 / 10          | 38          | 38 (match) |
| 1200 / 20          | 39 (`/240`) | — |
| 1300 / 0           | —           | 34 |
| 1300 / 5           | —           | 33 |
| 1300 / 10          | —           | 33 |

## 4. Observations

**Peak stays at 1200/0 — confirmed.** No refinement-grid point beats
40/60 on total_60. The runner-up (`1100/110` at 39) is one point
short on total_60 and one short on top10_both (5 vs 6). The coarse
grid's finding is validated rather than moved.

**The peak is a single-point peak, not a plateau.** Every one of the
8 refinement-only neighbors scores strictly below 1200/0. If the
peak were a plateau, we'd expect at least one neighbor to tie within
the 0-pt noise band established by the reproducibility check;
instead the second-best neighbor drops 1 pt and the rest drop by
2-7 pts. The rubric surface around 1200/0 is shaped rather than
flat.

**Sensitivity to size: asymmetric around the peak.** Moving ±100 in
chunk size costs different amounts depending on direction and
overlap:

| size row        | peak in row | chunks row peak | size delta vs 1200/0 cost |
|-----------------|------------:|-----------------|---------------------------|
| 1100            | `1100/110` = 39 | 8451           | −1 pt (10% overlap recovers most of the loss) |
| 1200            | `1200/0` = 40   | 7528           | 0 (the peak) |
| 1300            | `1300/0` = 34   | 6934           | −6 pts (no overlap setting recovers it) |

The 1100 band is only 1 pt off peak (with overlap); the 1300 band
is 6 pts off peak and overlap doesn't help. **Going smaller than
1200 costs less than going larger.** This is consistent with the
E5.7 observation that e5-base's 400/40 co-peak at 40/60 exists on
the small end of the spectrum — the small-chunk regime is friendlier
to this model than the large-chunk regime.

**Overlap behavior is size-dependent — not a single rule.**

| size row | overlap 0 → 5 → 10 progression | verdict |
|----------|------------------------------:|---------|
| 1100     | 33 → 34 → 39                  | **overlap helps** (+6 pts at 10%) |
| 1200     | 40 → 38 → 38                  | overlap mildly hurts (−2 pts at 5%+) |
| 1300     | 34 → 33 → 33                  | flat / mildly hurts |

At size 1100, 10% overlap recovers most of the loss from shrinking
the chunk — the model benefits from overlap there. At size 1200,
the peak is at 0% overlap and adding any overlap is a small net
loss (consistent with E5.7's finding that "e5-base rejects overlap
at size 1200" — this refinement confirms the 5% data point, which
the coarse grid skipped). At size 1300, overlap is flat.

**5% overlap is not a hidden sweet spot at any size.** This was the
main "new regime" the refinement could reveal — the coarse grid
skipped 5%, so if the overlap curve had a bump between 0 and 10%,
it'd surface here. It doesn't. At 1200 it's 38 (worse than 0%). At
1100 it's 34 (barely better than 0, worse than 10%). At 1300 it's
33 (tied with 0 and 10%). 5% behaves as interpolation between 0%
and 10% — no hidden regime.

**The 1100/110 runner-up is the interesting secondary signal.**
39/60 at the same overlap *fraction* (10%) where bge-base peaks
(1200/240 is 20% overlap, 1200/120 is 10% overlap) and only 1 pt
behind the e5-base peak. If a future experiment needs a "slightly
smaller chunks + mild overlap" variant of e5-base (e.g. for a
corpus with shorter documents), 1100/110 is the empirically-tested
second-best geometry and is comfortably above bge-base's 36/60 peak.
Not a default candidate (1200/0 is strictly better on markdown-memory),
but a documented fallback.

## 5. Decision

**Default unchanged: `e5-base@1200/0`.**

The refinement sweep confirms the E5.7 peak at the same geometry
with the same score (40/60) and the same secondary metrics (9/6).
No refinement-grid neighbor beats it. No reason to update
`Sources/VecKit/IndexingProfile.swift` — the e5-base alias already
stamps `defaultChunkSize: 1200, defaultChunkOverlap: 0` per the
E5.7 commit (`4792953`).

**The global-default question (e5-base vs bge-base) is now
sharper.** The primary uncertainty that the E5.7 decision section
flagged — "is the measured 40/60 a coarse-grid artifact or the real
peak?" — is resolved. The peak is real, sits at a single point
(not a plateau), and nothing adjacent beats it. This strengthens
the case for the candidate global-default flip without forcing the
decision:

- E5.7 evidence: e5-base@1200/0 = 40/60 vs bge-base@1200/240 = 36/60, +4 pts, +3 top10_both.
- E5.9a evidence: the 40/60 is robust under refinement. The nearest neighbor (1100/110 = 39) is still above bge-base's peak.

The remaining open question before flipping the global default is
corpus-generalization (E5.9b/c will refine bge-base and nomic
peaks, and a second-corpus run remains pending per E5.4e). This
refinement is one sub-deliverable of E5.9 and does not itself
resolve the global-default call.

**Sources/VecKit/IndexingProfile.swift**: no change.
**indexing-profile.md**: no change (the e5-base row already shows
`1200/0 → 40/60`).
**data/retrieval-e5-base-sweep.md**: no change to the E5.7 Decision
section. This refinement corroborates it; updating the prior
document to reference this one is optional and kept lightweight
(the reference lives here and in `plan.md`).

## 6. Follow-up

- **E5.9b — bge-base peak refinement.** Next sub-deliverable. The
  E5.4d coarse sweep landed a two-way tie at 36/60 (1200/240 and
  800/80); a refinement around either or both peaks would either
  break the tie or confirm the plateau.
- **E5.9c — nomic peak refinement.** The nomic 12-point sweep
  (1200/240 → 35) is the third 768-dim candidate in the E5.9
  advance set.
- **Corpus-generalization (E5.4e, still deferred).** If a
  second-corpus rubric materializes, rerunning `e5-base@1200/0`
  there is the primary validation. `e5-base@1100/110` as a
  documented second-best is a cheap extra data point to include
  in that second-corpus run if budget allows.
