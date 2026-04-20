# BGE-base Experiment — Parameter sweep results

markdown-memory corpus scored against `BAAI/bge-base-en-v1.5` at 768
dims via Apple/swift-embeddings' `Bert.loadModelBundle` loader (CLS-
pooled + explicit L2 normalization). Same 10 queries + scoring rule
as `retrieval-rubric.md`.

**Scope note** — Phase D ran a reduced sweep against bge-base. The
nomic sweep (`retrieval-results-nomic.md`) established the shape of
the response curve on this corpus: a peak near 1200/240 with sharp
degradation outside the 800-1500 range and an inverted-U on overlap
centered at 20%. Rather than re-deriving that shape for bge-base from
scratch, we seed at the nomic peak (1200/240) and probe the
neighborhood only if the seed is competitive.

**Scoring legend** — "top10" column uses "either T or S in top 10"
(matches the scoring script; stricter "both" counts are in the
per-iteration tables).

## 1. Summary table

| # | timestamp | config | total | top10 | notes |
|---|-----------|--------|-------|-------|-------|
| 1 | 2026-04-19 | recursive 1200/240 | 39/60 | 9/10 | seed at nomic peak; 674 files, 8170 chunks, ~42 min wall-clock |
| 2 | 2026-04-19 | recursive 800/160 | 28/60 | 8/10 | probe below seed; ~44 min wall-clock; 11 pts worse than seed |
| 3 | 2026-04-19 | recursive 1500/300 | 36/60 | 9/10 | probe above seed; 2495s wall; 3 pts worse than seed |
| 4 | 2026-04-19 | recursive 1000/200 | 32/60 | 9/10 | intermediate below seed; 2729s wall; 7 pts worse than seed |
| 5 | 2026-04-20 | recursive 1200/120 | 31/60 | 9/10 | low overlap probe; 2511s wall; 8 pts worse — less overlap hurts T rank |
| 6 | 2026-04-20 | recursive 1200/360 | 35/60 | 9/10 | high overlap probe; 2828s wall; 4 pts worse than seed |

## 2. Per-iteration details

### Iteration 1 — recursive 1200/240, bge-base-en-v1.5 768 dims
Reindex: 674 files, 8170 chunks (nearly identical chunk count to
nomic 1200/240's 8116). Scoring done manually from
`.rubric-bge-base-1200-240/q{1..10}.json` (Python scorer blocked by
local tool policy; ranks counted by enumerating `"file"` entries).

| # | query | T rank | S rank | T score | S score | subtotal |
|---|-------|--------|--------|---------|---------|----------|
| 1 | trademark price negotiation | 17 | 3 | 1 | 3 | 4 |
| 2 | where did I negotiate the price for the trademark | 4 | 5 | 2 | 2 | 4 |
| 3 | muse trademark pricing discussion | 14 | 5 | 1 | 2 | 3 |
| 4 | counter offer for trademark assets | 10 | 8 | 2 | 2 | 4 |
| 5 | how much did we ask for the trademark | 1 | 17 | 3 | 1 | 4 |
| 6 | trademark assignment agreement meeting | 16 | 20 | 1 | 1 | 2 |
| 7 | right of first refusal trademark | 3 | 1 | 3 | 3 | 6 |
| 8 | bean counter mode trademark | 1 | 15 | 3 | 1 | 4 |
| 9 | 1.5 million trademark deal | 16 | 3 | 1 | 3 | 4 |
| 10 | trademark deal move quickly quick execution | 15 | 1 | 1 | 3 | 4 |

TOTAL: 39/60, TOP10_EITHER: 9/10, TOP10_BOTH: 3/10

**Observations:**
- bge-base beats nomic's best (35/60 @ 1200/240) by 4 points. This
  is a genuinely strong seed — bge-base is the leader so far.
- T (transcript) hits top 3 on 3/10 queries (Q5, Q7, Q8), top 10 on
  4/10 — the Q8 "bean counter" phrase ranks T at #1, suggesting
  bge-base captures phrase-level signal better than nomic (which had
  T absent on Q8).
- S (summary) is the stronger target on this corpus: top 3 on 5/10
  queries (Q1, Q3, Q7, Q9, Q10), top 10 on 7/10. The whole-document
  embed pattern (S is ~900 chars) works well for bge-base.
- Weakest query: Q6 "trademark assignment agreement meeting"
  (subtotal 2). Same query was also nomic's weakest (0-1 pts);
  likely the corpus lacks a strong chunk for this specific phrase.
- 9/10 top10_either is a notable jump over nomic's best 3/10 —
  bge-base is pulling something into top-10 for nearly every query.

**Decision on probes:** seed score 39/60 is > nomic's best by 4 pts
and 9/10 top10_either is well clear of nomic's 3/10. Following user
directive to optimize per-model, running full sweep.

### Iteration 2 — recursive 800/160, bge-base-en-v1.5 768 dims
Reindex: 2650s wall (~44 min).

| # | query | T rank | S rank | T score | S score | subtotal |
|---|-------|--------|--------|---------|---------|----------|
| 1 | trademark price negotiation | 16 | 3 | 1 | 3 | 4 |
| 2 | where did I negotiate the price for the trademark | 18 | 5 | 1 | 2 | 3 |
| 3 | muse trademark pricing discussion | absent | 5 | 0 | 2 | 2 |
| 4 | counter offer for trademark assets | 16 | 6 | 1 | 2 | 3 |
| 5 | how much did we ask for the trademark | 11 | 18 | 1 | 1 | 2 |
| 6 | trademark assignment agreement meeting | absent | 19 | 0 | 1 | 1 |
| 7 | right of first refusal trademark | 11 | 1 | 1 | 3 | 4 |
| 8 | bean counter mode trademark | 9 | absent | 2 | 0 | 2 |
| 9 | 1.5 million trademark deal | absent | 2 | 0 | 3 | 3 |
| 10 | trademark deal move quickly quick execution | 12 | 1 | 1 | 3 | 4 |

TOTAL: 28/60, TOP10_EITHER: 8/10, TOP10_BOTH: 0/10

**Observations:**
- 11 points worse than 1200/240 seed. Smaller chunks spread the
  signal thinner and cost us on T rank especially (T was top 10 on
  4/10 at 1200/240, now 1/10 at 800/160).
- S still does well (5/10 top-3). The summary file is whole-doc,
  so chunk size affects it less.

### Iteration 3 — recursive 1500/300, bge-base-en-v1.5 768 dims
Reindex: 2495s wall (~42 min). Fewer chunks than 1200/240.

| # | query | T rank | S rank | T score | S score | subtotal |
|---|-------|--------|--------|---------|---------|----------|
| 1 | trademark price negotiation | 14 | 2 | 1 | 3 | 4 |
| 2 | where did I negotiate the price for the trademark | 5 | 6 | 2 | 2 | 4 |
| 3 | muse trademark pricing discussion | absent | 5 | 0 | 2 | 2 |
| 4 | counter offer for trademark assets | 9 | 5 | 2 | 2 | 4 |
| 5 | how much did we ask for the trademark | 1 | 16 | 3 | 1 | 4 |
| 6 | trademark assignment agreement meeting | absent | absent | 0 | 0 | 0 |
| 7 | right of first refusal trademark | 10 | 9 | 2 | 2 | 4 |
| 8 | bean counter mode trademark | 1 | 18 | 3 | 1 | 4 |
| 9 | 1.5 million trademark deal | 16 | 2 | 1 | 3 | 4 |
| 10 | trademark deal move quickly quick execution | 2 | 1 | 3 | 3 | 6 |

TOTAL: 36/60, TOP10_EITHER: 9/10, TOP10_BOTH: 4/10

**Observations:**
- 3 points behind 1200/240 but with a different shape: Q6 got worse
  (2→0) while Q10 got better (4→6). Larger chunks hurt Q6's
  specific-phrase matching; help Q10's thematic matching.
- 4/10 TOP10_BOTH vs 1200/240's 3/10 — more balanced but lower total.

### Iteration 4 — recursive 1000/200, bge-base-en-v1.5 768 dims
Reindex: 2729s wall.

| # | query | T rank | S rank | T score | S score | subtotal |
|---|-------|--------|--------|---------|---------|----------|
| 1 | trademark price negotiation | 16 | 4 | 1 | 2 | 3 |
| 2 | where did I negotiate the price for the trademark | 5 | 6 | 2 | 2 | 4 |
| 3 | muse trademark pricing discussion | absent | 5 | 0 | 2 | 2 |
| 4 | counter offer for trademark assets | absent | 7 | 0 | 2 | 2 |
| 5 | how much did we ask for the trademark | 1 | 17 | 3 | 1 | 4 |
| 6 | trademark assignment agreement meeting | absent | 19 | 0 | 1 | 1 |
| 7 | right of first refusal trademark | 9 | 10 | 2 | 2 | 4 |
| 8 | bean counter mode trademark | 6 | 15 | 2 | 1 | 3 |
| 9 | 1.5 million trademark deal | 18 | 3 | 1 | 3 | 4 |
| 10 | trademark deal move quickly quick execution | 8 | 1 | 2 | 3 | 5 |

TOTAL: 32/60, TOP10_EITHER: 9/10, TOP10_BOTH: 3/10

## 3. Final summary

**Winning config (so far):** recursive 1200/240, total 39/60,
top10_either 9/10. bge-base is the strongest embedder in the sweep
as of 2026-04-19. The curve so far:

| chunk | overlap | total | delta |
|-------|---------|-------|-------|
| 800   | 160     | 28    | -11   |
| 1000  | 200     | 32    | -7    |
| 1200  | 240     | 39    | peak  |
| 1500  | 300     | 36    | -3    |

Classic inverted-U centered on 1200. Next probes: vary overlap at
1200 chunk-size (1200/120 low, 1200/360 high) to locate overlap
optimum independently of chunk size.
