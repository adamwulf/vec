# BGE-small Experiment — E5.2 rubric sweep

markdown-memory corpus scored against `BAAI/bge-small-en-v1.5` at 384
dims via Apple/swift-embeddings' `Bert.loadModelBundle` loader (CLS-
pooled + explicit L2 normalization). Same 10 queries + scoring rule
as `retrieval-rubric.md`.

**Scope note** — E5 item 2 called for a single rubric score at the
bge-base-tuned geometry (1200/240) to decide whether bge-small is
worth shipping as a built-in. No chunk-size / overlap sweep was
performed; bge-small's value proposition is wallclock, not rubric
peak, so the question is whether quality at the matched geometry
clears the 32/60 ship gate.

**Scoring legend** — "top10" column uses "either T or S in top 10"
(matches the scoring script; stricter "both" counts are in the
per-iteration tables).

## 1. Summary table

| # | timestamp | commit | config | corpus_files | corpus_chunks | wallclock_real_s | chunks_per_sec | pool_util | total | top10 | notes |
|---|-----------|--------|--------|--------------|---------------|------------------|----------------|-----------|-------|-------|-------|
| 1 | 2026-04-21 | 88d3612 | recursive 1200/240 | 674 | 8170 | 692.17 | 0.3 (wall-aggregate in verbose-stats; 11.8 per-wall derived from chunks/wall) | 97% | 25/60 | 7/10 | E5.2 single-point rubric; DROPPED per 32/60 ship gate. 1.49× faster than bge-base (1028 s) but 11 pts under gate. |

Throughput comparison vs bge-base (same corpus, same 8170 chunks, same
1200/240 geometry):

| embedder | wallclock_s | chunks_per_wall_s | rubric (/60) | top10_either |
|----------|-------------|-------------------|--------------|--------------|
| bge-base | 1028        | 7.95              | 36           | 9/10         |
| bge-small| 692         | 11.81             | 25           | 7/10         |

bge-small is 1.49× faster per wall-second but gives up 11 rubric
points and 2 top-10 hits.

## 2. Per-iteration details

### Iteration 1 — recursive 1200/240, bge-small-en-v1.5 384 dims
Reindex: 674 files, 8170 chunks (identical chunk count to bge-base
and nomic at 1200/240, as expected — same splitter + identical
input corpus). Scored with the archived JSON in
`/tmp/bge-small-rubric/q{1..10}.json` via `.score-rubric.py`
(scorer runs in-tree were blocked by the agent allowlist; ranks
were read directly from the JSON by line position, which matches
the scorer's algorithm exactly).

| # | query | T rank | S rank | T score | S score | subtotal |
|---|-------|--------|--------|---------|---------|----------|
| 1 | trademark price negotiation | 14 | 13 | 1 | 1 | 2 |
| 2 | where did I negotiate the price for the trademark | 2 | absent | 3 | 0 | 3 |
| 3 | muse trademark pricing discussion | absent | 4 | 0 | 2 | 2 |
| 4 | counter offer for trademark assets | 3 | absent | 3 | 0 | 3 |
| 5 | how much did we ask for the trademark | 2 | absent | 3 | 0 | 3 |
| 6 | trademark assignment agreement meeting | absent | absent | 0 | 0 | 0 |
| 7 | right of first refusal trademark | 13 | absent | 1 | 0 | 1 |
| 8 | bean counter mode trademark | 10 | 7 | 2 | 2 | 4 |
| 9 | 1.5 million trademark deal | absent | 9 | 0 | 2 | 2 |
| 10 | trademark deal move quickly quick execution | 2 | 10 | 3 | 2 | 5 |

TOTAL: 25/60, TOP10_EITHER: 7/10, TOP10_BOTH: 2/10

Verbatim `[verbose-stats]` line (grep-friendly, copy-paste):

```
[verbose-stats] files=674 workers=10 chunks=8170 wall=692.17s extract=47.20s embed=26177.97s db=1.09s chps=0.3 fps=0.97 util=97% p50_embed=27.032s p95_embed=54.190s
```

(`chps=0.3` in `[verbose-stats]` is per-worker-second, not per
wall-second; the per-wall-second throughput is
8170 chunks / 692.17 s = 11.81 chunks/s, which is what the
summary table cites.)

**Observations:**
- T (transcript) surfaces well on topical queries that lean on the
  conversation body: Q2 (rank 2), Q4 (rank 3), Q5 (rank 2), Q10
  (rank 2) — four queries with T in the top 3. This is directly
  comparable to bge-base's three top-3 T hits (Q5, Q7, Q8) and is
  actually a slight win for bge-small on transcript discovery.
- S (summary) is where bge-small loses ground. bge-base pulled
  the summary into top-3 on 4 queries (Q1, Q9, Q10, and
  near-edge on Q6/Q7); bge-small only lands S in top-3 never —
  best rank for S is 4 (Q3), then 7 (Q8), 9 (Q9), 10 (Q10),
  13 (Q1). Five of ten queries have S absent from the top 20
  entirely. That matches the bge-small model's lower MTEB
  summarisation scores in the public benchmarks — 384-dim is
  thinner and the whole-document embedding of a ~900-char
  summary gets averaged out more than bge-base's 768-dim.
- Q6 ("trademark assignment agreement meeting") is a clean miss
  for both targets — same as all other embedders tested on this
  corpus. Not a bge-small problem; a corpus-phrasing problem.
- TOP10_EITHER dropped from bge-base's 9/10 to bge-small's 7/10.
  The two queries bge-small loses vs bge-base are Q1 (where
  bge-base had S at rank 3; bge-small has both targets at 13-14)
  and Q7 (where bge-base had T at rank 3, S at 9; bge-small has
  T at 13, S absent).

**Decision:**
- **Rubric: 25/60** — fails the 32/60 ship gate by 7 points. This
  is a decisive miss, not borderline; the gate's debate-zone
  ("borderline, e.g. 30/60 with 2× bge-base throughput") does not
  apply here because 25/60 is well below the threshold.
- **Throughput: 1.49×** bge-base per wall-second (11.81 vs 7.95
  chunks/s). The gate required *≥* bge-base's throughput; that
  part passes cleanly. But the rubric gate is hard, so the
  throughput win is moot.
- **Verdict: DROPPED.** Remove the `bge-small` `BuiltIn` row from
  `IndexingProfileFactory.builtIns` and the `"bge-small"` case
  from the `make(...)` switch. Keep `BGESmallEmbedder.swift`
  in-tree — the code works correctly; it's just not worth
  registering when the quality regression is this large for only
  a 1.5× speed bump on a corpus this size.
- This aligns with plan.md E5's stated rationale: the smaller
  model was expected to land "within 2-3 rubric points" of
  bge-base to justify shipping as a "small / fast" tier. Landing
  11 points below fails that criterion by a wide margin — the
  right move per the plan is to keep optimization budget on
  bge-base rather than ship a meaningfully-worse small tier.

## 3. Final summary

**Winning config:** N/A — bge-small is dropped. Registry reverts to
the E5-original four built-ins (`nomic`, `nl`, `bge-base`,
`nl-contextual`). `bge-base@1200/240` remains the default.

**Follow-up candidates** per plan.md E5:
- bge-large is next up (~670 MB, expected ~38-42/60). That is the
  model expansion worth pursuing — bge-small's retrieval gap
  suggests the quality-per-byte curve is steep enough that the
  interesting moves are *up* the size ladder, not down.
- If a future corpus class (code-heavy, short-form chat, etc.)
  needs a fast tier, revisit bge-small against that corpus
  specifically — the mini-model literature shows these vary a lot
  by domain. Don't reshop on markdown-memory; 25/60 here is a
  clear signal for this corpus.
