# Nomic Experiment — Parameter sweep results

Bean-test corpus (markdown-memory DB) scored against nomic-embed-text-v1.5
at 768 dims. Same 10 queries + scoring rule as `bean-test.md`.

## 1. Summary table

| # | timestamp | config | total | top10 | notes |
|---|-----------|--------|-------|-------|-------|
| 1 | 2026-04-17 | recursive 2000/200 | 23/60 | 0/10 | baseline nomic, wall-clock 1923s (~32 min) |
| 2 | 2026-04-17 | recursive 1200/240 | 35/60 | 3/10 | wall-clock 2940s (~49 min) |
| 3 | 2026-04-17 | recursive 800/160 | 32/60 | 4/10 | wall-clock 4344s (~72 min) |

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
