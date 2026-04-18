# Nomic Experiment — Parameter sweep results

Bean-test corpus (markdown-memory DB) scored against nomic-embed-text-v1.5
at 768 dims. Same 10 queries + scoring rule as `bean-test.md`.

## 1. Summary table

| # | timestamp | config | total | top10 | notes |
|---|-----------|--------|-------|-------|-------|
| 1 | 2026-04-17 | recursive 2000/200 | 23/60 | 0/10 | baseline nomic, wall-clock 1923s (~32 min) |
| 2 | 2026-04-17 | recursive 1200/240 | 35/60 | 3/10 | wall-clock 2940s (~49 min) |
| 3 | 2026-04-17 | recursive 800/160 | 32/60 | 4/10 | wall-clock 4344s (~72 min) |
| 4 | 2026-04-17 | recursive 1500/300 | 23/60 | 2/10 | wall-clock 2477s (~41 min) |
| 5 | 2026-04-17 | recursive 1400/280 | 26/60 | 1/10 | wall-clock 2901s (~48 min) |
| 6 | 2026-04-17 | recursive 1000/200 | 28/60 | 2/10 | wall-clock 3726s (~62 min) |

## 2. Per-iteration details

### Iteration 1 — recursive 2000/200, nomic-embed-text-v1.5 768 dims
Reindex wall-clock: 1923.49s (674 files, 4774 chunks, 10 workers; embed=7349s CPU / 1923s wall; p50 embed 8.86s, p95 20.07s).
Dim sanity: `SELECT DISTINCT length(embedding) FROM chunks` → 3072 (single row). PASS.

| # | query | T rank | S rank | T score | S score | subtotal |
|---|-------|--------|--------|---------|---------|----------|
| 1 | trademark price negotiation | absent | 11 | 0 | 1 | 1 |
| 2 | where did I negotiate the price for the trademark | 6 | 18 | 2 | 1 | 3 |
| 3 | muse trademark pricing discussion | absent | 3 | 0 | 3 | 3 |
| 4 | counter offer for trademark assets | 8 | 17 | 2 | 1 | 3 |
| 5 | how much did we ask for the trademark | 4 | absent | 2 | 0 | 2 |
| 6 | trademark assignment agreement meeting | absent | absent | 0 | 0 | 0 |
| 7 | right of first refusal trademark | 4 | 14 | 2 | 1 | 3 |
| 8 | bean counter mode trademark | absent | absent | 0 | 0 | 0 |
| 9 | 1.5 million trademark deal | 13 | 11 | 1 | 1 | 2 |
| 10 | trademark deal move quickly quick execution | 15 | 5 | 1 | 2 | 3 |

TOTAL: 23/60, QUERIES_HIT_TOP10 (both T and S in top 10): 0/10

**Observations:**
- T (transcript.txt) reaches top 10 on 4/10 queries (Q2, Q4, Q5, Q7) but is absent entirely on 4/10 (Q1, Q3, Q6, Q8).
- S (summary.md) hits top 10 on only 2/10 (Q3, Q10); S is "whole" embed-only (~900 chars), so its retrieval depends on how a single 768-dim vector covers the whole summary.
- Phrase-leaning queries (Q8 "bean counter", Q9 "1.5 million") weaker than expected — likely the dense 2000-char chunks dilute the phrase signal, which was the original NLEmbedding diagnosis.
- Strong competitors: `muse-trademark/research/015-zoom-contract-justia.md` and `granola/2026-03-10-20-59-8e7b43c9/*` repeatedly rank above the target on trademark queries — these are the actual trademark contract documents, so high similarity is semantically fair.

### Iteration 2 — recursive 1200/240, nomic-embed-text-v1.5 768 dims
Reindex wall-clock: 2940.40s (674 files, 8116 chunks, 10 workers; embed=7818.74s CPU / 2940s wall; p50 embed 8.09s, p95 26.52s).

| # | query | T rank | S rank | T score | S score | subtotal |
|---|-------|--------|--------|---------|---------|----------|
| 1 | trademark price negotiation | absent | 5 | 0 | 2 | 2 |
| 2 | where did I negotiate the price for the trademark | 9 | 19 | 2 | 1 | 3 |
| 3 | muse trademark pricing discussion | absent | 4 | 0 | 2 | 2 |
| 4 | counter offer for trademark assets | 14 | 1 | 1 | 3 | 4 |
| 5 | how much did we ask for the trademark | 3 | 10 | 3 | 2 | 5 |
| 6 | trademark assignment agreement meeting | 20 | absent | 1 | 0 | 1 |
| 7 | right of first refusal trademark | 3 | 14 | 3 | 1 | 4 |
| 8 | bean counter mode trademark | 2 | 1 | 3 | 3 | 6 |
| 9 | 1.5 million trademark deal | 16 | 9 | 1 | 2 | 3 |
| 10 | trademark deal move quickly quick execution | 1 | 9 | 3 | 2 | 5 |

TOTAL: 35/60, QUERIES_HIT_TOP10 (both T and S in top 10): 3/10

**Observations:**
- Clear improvement over iter-1 (+12 points, +3 top10 hits). Smaller chunks (1200 vs 2000) lift phrase-heavy queries substantially: Q8 "bean counter" jumped from 0/6 to 6/6 (both target files ranked top 2), Q4 from 3 to 4, Q10 from 3 to 5.
- T (transcript.txt) now in top 10 on 5/10 (Q2, Q5, Q7, Q8, Q10) vs 4/10 in iter-1, no longer absent on Q6 (rank 20, +1). Still absent on Q1 and Q3.
- S (summary.md) top 10 on 5/10 (Q1, Q3, Q4, Q5, Q8, Q9, Q10 = 7/10 actually) — big lift from 2/10. Still S is single-vector since ~900 chars, but evidently nomic's whole-doc vector clusters tightly around the summary's topics.
- Reindex was ~1.5× slower (2940s vs 1923s) due to ~70% more chunks (8116 vs 4774) from smaller chunk size.

### Iteration 3 — recursive 800/160, nomic-embed-text-v1.5 768 dims
Reindex wall-clock: 4344.11s (674 files, 12001 chunks, 10 workers; embed=9266.14s CPU / 4344s wall; p50 embed 8.52s, p95 36.42s).

| # | query | T rank | S rank | T score | S score | subtotal |
|---|-------|--------|--------|---------|---------|----------|
| 1 | trademark price negotiation | absent | 6 | 0 | 2 | 2 |
| 2 | where did I negotiate the price for the trademark | 16 | absent | 1 | 0 | 1 |
| 3 | muse trademark pricing discussion | absent | 3 | 0 | 3 | 3 |
| 4 | counter offer for trademark assets | 5 | 1 | 2 | 3 | 5 |
| 5 | how much did we ask for the trademark | 14 | 10 | 1 | 2 | 3 |
| 6 | trademark assignment agreement meeting | 13 | absent | 1 | 0 | 1 |
| 7 | right of first refusal trademark | 6 | 2 | 2 | 3 | 5 |
| 8 | bean counter mode trademark | 1 | 2 | 3 | 3 | 6 |
| 9 | 1.5 million trademark deal | absent | 10 | 0 | 2 | 2 |
| 10 | trademark deal move quickly quick execution | 9 | 5 | 2 | 2 | 4 |

TOTAL: 32/60, QUERIES_HIT_TOP10 (both T and S in top 10): 4/10

**Observations:**
- Slight regression from iter-2 in total (-3) but +1 top10 hit (4 vs 3). Trend of "smaller chunks win" is NOT continuing linearly — 800/160 is slightly worse than 1200/240 on aggregate.
- T (transcript.txt) top 10 on 4/10 (Q4, Q7, Q8, Q10) — dropped from iter-2's 5/10; regressions on Q2 (9→16), Q5 (3→14), Q6 (20→13→better here actually). New absences: Q1 (was absent in iter-1 too), Q9 (was rank 16 in iter-2, now absent).
- S (summary.md) top 10 on 7/10 (Q1, Q3, Q4, Q5, Q7, Q8, Q10) vs iter-2's 7/10 — summary retrieval holds steady. Q9 dropped from 9 to 10 (still top10 boundary).
- Reindex ~1.5× slower than iter-2 (4344s vs 2940s) due to ~48% more chunks (12001 vs 8116). Total CPU embed time climbs proportionally.
- Conclusion: 1200/240 remains the high-water mark. Small chunks beat large, but extremely small dilutes topic context for transcripts — smaller is not monotonically better.

### Iteration 4 — recursive 1500/300, nomic-embed-text-v1.5 768 dims
Reindex wall-clock: 2477.14s (674 files, 6607 chunks, 10 workers; embed=7567.55s CPU / 2477s wall; p50 embed 8.32s, p95 22.46s).

| # | query | T rank | S rank | T score | S score | subtotal |
|---|-------|--------|--------|---------|---------|----------|
| 1 | trademark price negotiation | absent | 12 | 0 | 1 | 1 |
| 2 | where did I negotiate the price for the trademark | 9 | absent | 2 | 0 | 2 |
| 3 | muse trademark pricing discussion | absent | 4 | 0 | 3 | 3 |
| 4 | counter offer for trademark assets | 7 | 19 | 2 | 1 | 3 |
| 5 | how much did we ask for the trademark | 3 | absent | 3 | 0 | 3 |
| 6 | trademark assignment agreement meeting | absent | absent | 0 | 0 | 0 |
| 7 | right of first refusal trademark | 7 | 6 | 2 | 2 | 4 |
| 8 | bean counter mode trademark | 15 | absent | 1 | 0 | 1 |
| 9 | 1.5 million trademark deal | 17 | 13 | 1 | 1 | 2 |
| 10 | trademark deal move quickly quick execution | 5 | 10 | 2 | 2 | 4 |

TOTAL: 23/60, QUERIES_HIT_TOP10 (both T and S in top 10): 2/10

**Observations:**
- Significant regression from iter-2 peak (35/60) and iter-3 (32/60) — 23/60 matches iter-1's baseline (2000/200). Bracketing the 1200/240 peak from the high side confirms 1500/300 is too coarse: we've re-entered iter-1-like territory.
- T (transcript.txt) top 10 on 4/10 (Q2, Q4, Q5, Q7, Q10) — respectable for T but two absences (Q1, Q3, Q6) and lower-rank hits for Q8 (15) and Q9 (17) drag the total.
- S (summary.md) top 10 on 3/10 (Q3, Q7, Q10) — major drop vs iter-2 and iter-3 which both landed 7/10 top-10 S hits. Suggests the "whole" embed for the ~900-char summary is drowned out when competing against 1500-char document chunks that contain more noise — similar mechanism to iter-1.
- Wall-clock 2477s sits between iter-2 (2940s) and iter-1 (1923s); chunk count 6607 also intermediate between iter-1 (4774) and iter-2 (8116).
- Trend: peak remains at 1200/240. The 1500/300 bracket on the high side is clearly worse, confirming the peak is in the 800–1200 chunk-char range. Next probe logically: smaller offsets around 1200/240 (e.g. 1000/200, 1400/280) or re-confirm by sliding overlap fraction independently.

### Iteration 5 — recursive 1400/280, nomic-embed-text-v1.5 768 dims
Reindex wall-clock: 2900.97s (674 files, 7044 chunks, 10 workers; embed=8425.07s CPU / 2901s wall; p50 embed 9.13s, p95 25.43s).

| # | query | T rank | S rank | T score | S score | subtotal |
|---|-------|--------|--------|---------|---------|----------|
| 1 | trademark price negotiation | 19 | 13 | 1 | 1 | 2 |
| 2 | where did I negotiate the price for the trademark | 10 | absent | 2 | 0 | 2 |
| 3 | muse trademark pricing discussion | absent | 2 | 0 | 3 | 3 |
| 4 | counter offer for trademark assets | 10 | 14 | 2 | 1 | 3 |
| 5 | how much did we ask for the trademark | 4 | absent | 2 | 0 | 2 |
| 6 | trademark assignment agreement meeting | 18 | absent | 1 | 0 | 1 |
| 7 | right of first refusal trademark | 3 | 8 | 3 | 2 | 5 |
| 8 | bean counter mode trademark | 2 | absent | 3 | 0 | 3 |
| 9 | 1.5 million trademark deal | absent | 12 | 0 | 1 | 1 |
| 10 | trademark deal move quickly quick execution | 1 | 11 | 3 | 1 | 4 |

TOTAL: 26/60, QUERIES_HIT_TOP10 (both T and S in top 10): 1/10

**Observations:**
- 26/60 sits between iter-4 (23/60, 1500/300) and iter-3 (32/60, 800/160), confirming the cliff on the high side of the 1200/240 peak. The 1400/280 config is 200 chars wider than the peak and loses ~9 points — not a tight bracket; the drop-off is meaningful within a narrow window.
- Compared to iter-2 peak (35/60, 1200/240), this iter is -9: S regresses heavily (3/10 summary top-10 vs 7/10 in iter-2), T hold slightly worse (4/10 top-10 vs 5/10). The summary (~900 chars, whole-embed) is the main casualty when chunks grow from 1200 → 1400.
- Strong T performance on Q7 (3), Q8 (2), Q10 (1), Q5 (4) — phrase-heavy and topic-specific queries still pick the transcript. T absent on Q3 and Q9, which hurts total.
- Wall-clock 2901s sits close to iter-2 (2940s) at 7044 chunks vs 8116 — throughput scales as expected with chunk count.
- Peak remains at iter-2's 1200/240 (35/60, 3/10). The high-side cliff runs between 1200 and 1400: 1400/280 already re-enters sub-30 territory. Next probes that best bracket the peak would be downward (e.g. 1000/200, 1100/220) or checking overlap ratio independently (e.g. 1200/120, 1200/360).

### Iteration 6 — recursive 1000/200, nomic-embed-text-v1.5 768 dims
Reindex wall-clock: 3726.02s (674 files, 9649 chunks, 10 workers; embed=8950.70s CPU / 3726s wall; p50 embed 8.78s, p95 32.28s).

| # | query | T rank | S rank | T score | S score | subtotal |
|---|-------|--------|--------|---------|---------|----------|
| 1 | trademark price negotiation | absent | 6 | 0 | 2 | 2 |
| 2 | where did I negotiate the price for the trademark | absent | 20 | 0 | 1 | 1 |
| 3 | muse trademark pricing discussion | absent | 4 | 0 | 2 | 2 |
| 4 | counter offer for trademark assets | 16 | 1 | 1 | 3 | 4 |
| 5 | how much did we ask for the trademark | 5 | 14 | 2 | 1 | 3 |
| 6 | trademark assignment agreement meeting | 13 | absent | 1 | 0 | 1 |
| 7 | right of first refusal trademark | 8 | 16 | 2 | 1 | 3 |
| 8 | bean counter mode trademark | 2 | 1 | 3 | 3 | 6 |
| 9 | 1.5 million trademark deal | absent | 9 | 0 | 2 | 2 |
| 10 | trademark deal move quickly quick execution | 5 | 10 | 2 | 2 | 4 |

TOTAL: 28/60, QUERIES_HIT_TOP10 (both T and S in top 10): 2/10

**Observations:**
- 28/60 on the low-side bracket between iter-3 (32/60, 800/160) and iter-2 peak (35/60, 1200/240). This narrows the peak to somewhere in the 800–1200 chunk-char window with 1000/200 itself sitting closer to the 800/160 point than the peak — a slightly surprising dip given the earlier assumption of monotonic rise into 1200/240.
- T (transcript.txt) in top 10 on 4/10 (Q5, Q7, Q8, Q10) — consistent with iter-3 and iter-2 counts (both 4–5/10). T is absent on Q1, Q2, Q3, Q9 — same cold-corner queries as iter-1 keep resisting T retrieval.
- S (summary.md) in top 10 on 5/10 (Q1 rank 6, Q3 rank 4, Q4 rank 1, Q8 rank 1, Q9 rank 9, Q10 rank 10 = 6/10 actually; counting Q1 6, Q3 4, Q4 1, Q8 1, Q9 9, Q10 10 → 6 hits). Between iter-3 (7/10) and iter-4 (3/10); summary retrieval weakened vs the 800–1200 peak.
- Both-top10 count only 2/10 (Q8, Q10) — T is the binding constraint: T often in top-20 but below the top-10 cut on exactly the queries where S is strong.
- Wall-clock 3726s at 9649 chunks fits the expected throughput curve (iter-3 4344s at 12001 chunks = 2.76 ch/s, iter-2 2940s at 8116 chunks = 2.76 ch/s — this iter 2.59 ch/s, slightly slower but consistent).
- Peak still sits at iter-2's 1200/240 (35/60, 3/10). 1000/200 under-performs both the 1200/240 peak AND the 800/160 iter-3 result. This is mildly non-monotonic inside the 800-1200 window — possibly noise-level variance rather than a real shape. Not hitting the SHIP gate (need ≥ 45/60 AND ≥ 7/10).
