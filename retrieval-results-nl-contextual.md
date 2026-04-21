# NLContextualEmbedding Experiment — Parameter sweep results

markdown-memory corpus scored against Apple's `NLContextualEmbedding`
for English at 512 dims (per-token contextual vectors, mean-pooled
and L2-normalized). Same 10 queries + scoring rule as
`retrieval-rubric.md`.

**Caveat for this embedder**: NLContextualEmbedding's
`maximumSequenceLength` is ~256 tokens (≈1000 English chars); chunks
over that are truncated by the tokenizer. A 1200-char chunk is a
rough upper bound on what the model actually sees — 800/160 is
expected to fit better.

**Scoring legend** — "top10" column uses "either T or S in top 10"
(matches the scoring script; stricter "both" counts are in the
per-iteration tables).

## 1. Summary table

| # | timestamp | config | total | top10 | notes |
|---|-----------|--------|-------|-------|-------|
| 1 | 2026-04-19 | recursive 1200/240 | 3/60 | 1/10 | seed at nomic peak; wall-clock 424s (~7 min) — very weak, only T hits at all |
| 2 | 2026-04-20 | recursive 800/160 | 2/60 | 0/10 | fits in 256-token window; 12055 chunks, 530s wall — no improvement, slightly worse |

## 2. Per-iteration details

### Iteration 1 — recursive 1200/240, NLContextualEmbedding 512 dims
Reindex: 674 files, 8170 chunks, 424s wall (vs bge-base's 2520s
at same config — nl-contextual is ~6x faster per chunk). p50 embed
1.07s, p95 3.55s.

| # | query | T rank | S rank | T score | S score | subtotal |
|---|-------|--------|--------|---------|---------|----------|
| 1 | trademark price negotiation | absent | absent | 0 | 0 | 0 |
| 2 | where did I negotiate the price for the trademark | 7 | absent | 2 | 0 | 2 |
| 3 | muse trademark pricing discussion | absent | absent | 0 | 0 | 0 |
| 4 | counter offer for trademark assets | absent | absent | 0 | 0 | 0 |
| 5 | how much did we ask for the trademark | 11 | absent | 1 | 0 | 1 |
| 6 | trademark assignment agreement meeting | absent | absent | 0 | 0 | 0 |
| 7 | right of first refusal trademark | absent | absent | 0 | 0 | 0 |
| 8 | bean counter mode trademark | absent | absent | 0 | 0 | 0 |
| 9 | 1.5 million trademark deal | absent | absent | 0 | 0 | 0 |
| 10 | trademark deal move quickly quick execution | absent | absent | 0 | 0 | 0 |

TOTAL: 3/60, TOP10_EITHER: 1/10, TOP10_BOTH: 0/10

**Observations:**
- Catastrophically weak on this corpus. Neither target file appears
  in top 20 for 8 of 10 queries.
- S (summary, whole-doc embed ~900 chars) never hits — surprising
  given 900 chars fits in the 256-token window. Suggests the model
  is just a poor semantic match for this domain, not a chunk-size
  issue.
- T (transcript) hits twice, both outside top 3. Top results for
  most queries are `notes.md` files, which is a symptom of
  shallow lexical overlap dominating (notes files are shorter and
  more keyword-dense).
- Much faster than bge-base (~7 min vs ~42 min), but speed doesn't
  matter if retrieval is this poor.

### Iteration 2 — recursive 800/160, NLContextualEmbedding 512 dims
Reindex: 12055 chunks, 530s wall. 800 chars fits comfortably in the
256-token window, so this isolates model quality from truncation.

| # | query | T rank | S rank | T score | S score | subtotal |
|---|-------|--------|--------|---------|---------|----------|
| 1 | trademark price negotiation | absent | absent | 0 | 0 | 0 |
| 2 | where did I negotiate the price for the trademark | 30 | absent | 0 | 0 | 0 |
| 3 | muse trademark pricing discussion | absent | absent | 0 | 0 | 0 |
| 4 | counter offer for trademark assets | absent | 19 | 0 | 1 | 1 |
| 5 | how much did we ask for the trademark | 22 | absent | 0 | 0 | 0 |
| 6 | trademark assignment agreement meeting | absent | absent | 0 | 0 | 0 |
| 7 | right of first refusal trademark | absent | 13 | 0 | 1 | 1 |
| 8 | bean counter mode trademark | absent | absent | 0 | 0 | 0 |
| 9 | 1.5 million trademark deal | absent | absent | 0 | 0 | 0 |
| 10 | trademark deal move quickly quick execution | absent | absent | 0 | 0 | 0 |

TOTAL: 2/60, TOP10_EITHER: 0/10, TOP10_BOTH: 0/10

**Observations:**
- 1 point worse than 1200/240, still catastrophically weak.
- Fitting the chunk within the 256-token window did NOT rescue
  retrieval — this rules out truncation as the root cause. The model
  is simply a poor semantic match for the trademark/negotiation
  vocabulary in this corpus.
- Zero targets in top 10 for any query — worse than nomic's weakest
  and >15x worse than bge-base by subtotal.

## 3. Final summary

**NLContextualEmbedding is unsuitable for this corpus.** Both a
chunk-size-matched config (800/160, fits in 256-token window) and the
nomic-peak config (1200/240) fail to bring either target file into
top 10 for ≥9 of 10 queries. The model appears to prioritize shallow
keyword overlap (notes files with "trademark" in them rank highest)
over semantic topic matching.

Skipping further parameter probes — no chunk/overlap choice will
salvage a fundamentally poor embedder-for-corpus match. Speed
advantage (~7 min vs bge-base's ~42 min) doesn't matter when
retrieval is this weak.
