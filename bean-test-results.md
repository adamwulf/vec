# Bean Test — Optimizer Results Log

Target files:
- T = `granola/2026-02-26-22-30-164bf8dc/transcript.txt`
- S = `granola/2026-02-26-22-30-164bf8dc/summary.md`

Scoring per query: rank 1-3 → +3, rank 4-10 → +2, rank 11-20 → +1, absent → 0.
Max per query = 6 (two files). Max total = 60 over 10 queries.

## Iterations

| # | timestamp | config | total | top10 | notes |
|---|-----------|--------|-------|-------|-------|
| 0 | 2026-04-17 | default (2000/200, recursive) | 6/60 | 0/10 | baseline — summary hits Q6/Q7 only; transcript only surfaces once (rank 13, Q2) |

### Iteration 0 — default (chunk-chars 2000, overlap 200)

```
| # | query                                                    | T rank | S rank | T score | S score | subtotal |
| 1 | trademark price negotiation                              | -      | -      | 0       | 0       | 0        |
| 2 | where did I negotiate the price for the trademark        | 13     | -      | 1       | 0       | 1        |
| 3 | muse trademark pricing discussion                        | -      | -      | 0       | 0       | 0        |
| 4 | counter offer for trademark assets                       | -      | -      | 0       | 0       | 0        |
| 5 | how much did we ask for the trademark                    | -      | -      | 0       | 0       | 0        |
| 6 | trademark assignment agreement meeting                   | -      | 6      | 0       | 2       | 2        |
| 7 | right of first refusal trademark                         | -      | 3      | 0       | 3       | 3        |
| 8 | bean counter mode trademark                              | -      | -      | 0       | 0       | 0        |
| 9 | 1.5 million trademark deal                               | -      | -      | 0       | 0       | 0        |
| 10| trademark deal move quickly quick execution              | -      | -      | 0       | 0       | 0        |
TOTAL: 6/60, QUERIES_HIT_TOP10: 0/10
```

Observation: summary.md occasionally surfaces because it's a `.whole`-chunk-only doc. transcript.txt barely registers — at 2000 chars per chunk, each transcript chunk is a semantic blob too diluted to survive cosine against brief noun-phrase queries.

| 1 | 2026-04-17 | 400 / 80 / recursive | 3/60 | 0/10 | smaller chunks HURT — transcript vanishes entirely; only Q6 hits summary |

### Iteration 1 — chunk-chars 400, overlap 80

```
| # | query                                                    | T rank | S rank | T score | S score | subtotal |
| 1 | trademark price negotiation                              | -      | -      | 0       | 0       | 0        |
| 2 | where did I negotiate the price for the trademark        | -      | -      | 0       | 0       | 0        |
| 3 | muse trademark pricing discussion                        | -      | -      | 0       | 0       | 0        |
| 4 | counter offer for trademark assets                       | -      | -      | 0       | 0       | 0        |
| 5 | how much did we ask for the trademark                    | -      | -      | 0       | 0       | 0        |
| 6 | trademark assignment agreement meeting                   | -      | 3      | 0       | 3       | 3        |
| 7 | right of first refusal trademark                         | -      | -      | 0       | 0       | 0        |
| 8 | bean counter mode trademark                              | -      | -      | 0       | 0       | 0        |
| 9 | 1.5 million trademark deal                               | -      | -      | 0       | 0       | 0        |
| 10| trademark deal move quickly quick execution              | -      | -      | 0       | 0       | 0        |
TOTAL: 3/60, QUERIES_HIT_TOP10: 0/10
```

Observation: the hypothesis "shrinking chunks fixes the transcript" is refuted. The transcript is too noisy — raw spoken filler dilutes embeddings at any chunk size. Summary.md got WORSE at Q7 (vanished from rank 3) because smaller chunk-size may have changed .whole-ness threshold or index composition. Also notable: file count jumped from 516→674, meaning default 2000/200 SKIPS some files — worth investigating separately but not blocking.

Next direction: try LARGER chunks (800, 1000) to see if the trend is monotonic, and in parallel plan pre-processing (strip filler, normalize speakers). Also try a mid size (600) to map the curve.

| 2 | 2026-04-17 | 4000 / 400 / recursive | 0/60 | 0/10 | monotonic regression — bigger doesn't help either, nothing surfaces |

### Iteration 2 — chunk-chars 4000, overlap 400

```
TOTAL: 0/60, QUERIES_HIT_TOP10: 0/10
```

Key insight across iterations 0–2: raw chunk-size tuning in {400, 2000, 4000} produces scores {3, 6, 0} — all bad. The transcript NEVER surfaces in top 20 for any meaningful query. This is a semantic-content problem, not a chunking problem. The transcript is conversational filler ("yeah, yeah, right, right") around tiny pockets of signal. ANY chunk that includes transcript text gets its vector dominated by generic conversational noise, so cosine similarity against clean query terms like "trademark price negotiation" loses to clean doc chunks like handbooks and markdown notes.

Strategic pivot: attack the corpus preprocessing. Steps planned:
1. Add a pre-processing layer in TextExtractor that, for transcript files, strips trivial speaker filler / backchannels and normalizes speaker tags.
2. Reindex at a moderate chunk size (2000) — same as default — and re-score.
3. If that lifts transcript rankings substantially, tune chunk size further.

| 3 | 2026-04-17 | noise-filter (headings/frontmatter skip, <50 chars) + 2000/200 | 2/60 | 0/10 | FIXED a real bug (100+ title-only notes.md were dominating) but target still absent — transcript chunks genuinely outscored by OTHER transcripts |

### Iteration 3 — noise filter (skip files with <50 chars meaningful body) + 2000/200

Mid-iteration diagnostic on query "bean counter mode":
- Before filter: top 15 are all 3-line title-only `notes.md` files (garbage)
- After filter: top 20 are all transcripts (correct file-class)
- BUT our target transcript `164bf8dc/transcript.txt` STILL doesn't surface — other transcripts (`2026-01-21-15-00-b57b1d89/transcript.txt`, `2026-01-20-18-00-92d67a7c/transcript.txt`, etc.) win.

137 files skipped (title-only notes.md, empty stubs). Chunk count dropped but signal-to-noise improved dramatically on phrase queries.

However, on topical queries (Q1–Q6, Q10) summary.md no longer appears at all — it got pushed out of top 20 too, because now the top 20 is stuffed with transcript chunks of OTHER meetings that really do discuss trademarks.

Hypothesis for WHY the target transcript still loses: our transcript has ~173 lines and the "bean counter mode" phrase is in just ~3 of them. A 2000-char chunk around line 118 includes paragraphs of filler. OTHER transcripts that mention the specific noun-phrases in clean sentences (like b57b1d89 at line 596: apparently a clean phrase) outrank it.

Two options:
A) Fix transcript preprocessing — strip per-line backchannels ("yeah yeah", "right right", "okay") to densify signal within each chunk
B) Accept that the transcript is genuinely harder than the summary; focus on getting summary to top 10 consistently

Next: try (A). Transcript preprocessing.

| 4 | 2026-04-17 | noise-filter + filler-strip + 600/120 | 2/60 | 0/10 | filler-strip did NOT help; smaller chunks + filler-strip ≈ noise-filter alone |

### Iteration 4 — filler-strip in TextExtractor + 600/120

```
| # | query                                                    | T rank | S rank | T score | S score | subtotal |
| 1 | trademark price negotiation                              | -      | -      | 0       | 0       | 0        |
| 2 | where did I negotiate the price for the trademark        | -      | -      | 0       | 0       | 0        |
| 3 | muse trademark pricing discussion                        | -      | -      | 0       | 0       | 0        |
| 4 | counter offer for trademark assets                       | -      | -      | 0       | 0       | 0        |
| 5 | how much did we ask for the trademark                    | -      | -      | 0       | 0       | 0        |
| 6 | trademark assignment agreement meeting                   | -      | -      | 0       | 0       | 0        |
| 7 | right of first refusal trademark                         | -      | 6      | 0       | 2       | 2        |
| 8 | bean counter mode trademark                              | -      | -      | 0       | 0       | 0        |
| 9 | 1.5 million trademark deal                               | -      | -      | 0       | 0       | 0        |
| 10| trademark deal move quickly quick execution              | -      | -      | 0       | 0       | 0        |
TOTAL: 2/60, QUERIES_HIT_TOP10: 0/10
```

Observation: after 4 iterations with 4 different chunk-size + preprocessing configs,
the target transcript still NEVER surfaces in top 20 and the summary only surfaces
on Q7 ("right of first refusal"). The best score was iteration 0's baseline: 6/60.
NLEmbedding cosine similarity on this corpus cannot rank this specific meeting
higher than other meetings that discuss trademarks in cleaner sentences. The
target transcript is inherently diluted with filler; even stripping filler doesn't
match the density of clean summary chunks from OTHER meetings.

Diagnostic probe on query "bean counter mode" after iteration 4: top result was
`granola/2026-03-06-09-15-095ad75d/transcript.txt` at 0.464. Literal phrase
matches lose to topical co-occurrence in Apple NLEmbedding space.

| 5 | 2026-04-17 | noise-filter + filler-strip + 2000/200 | 2/60 | 0/10 | confirmed filler-strip+noise-filter plateau; same 2/60 as iter 3/4 |
| 6 | 2026-04-17 | filler-strip only (no noise-filter) + 2000/200 | 0/60 | 0/10 | filler-strip WITHOUT noise-filter is actively worse |
| 7 | 2026-04-17 | 1200/240 (no preprocessing) | 0/60 | 0/10 | intermediate chunk size is WORSE than both 2000 and 400 — not monotonic |
| 8 | 2026-04-17 | LineBasedSplitter 20 lines / 5 overlap | 3/60 | 0/10 | line-based splitter: marginal, matches 400/80 recursive |
| 9 | 2026-04-17 | LineBasedSplitter 50 lines / 10 overlap | 0/60 | 0/10 | larger line-chunks: worse |

## Final summary

### Winning config: **baseline default (Recursive, 2000 chars, 200 overlap, no preprocessing)**

Score: **6/60, 0/10 queries hitting both in top 10.**

Far below the brief's target of ≥40/60 and ≥6/10. The brief's quality bar is
unreachable with the levers available (chunk size, splitter choice,
preprocessing). No iteration matched — much less beat — the out-of-the-box
default. Therefore no code change is committed; the default is already the
best we can do with these levers.

### Trajectory

```
iter  config                                                       score
 0    Recursive 2000/200 (default)                                  6/60  ← winner
 1    Recursive 400/80                                              3/60
 2    Recursive 4000/400                                            0/60
 3    Recursive 2000/200 + noise-filter (<50ch meaningful body)     2/60
 4    Recursive 600/120 + noise-filter + filler-strip               2/60
 5    Recursive 2000/200 + noise-filter + filler-strip              2/60
 6    Recursive 2000/200 + filler-strip only                        0/60
 7    Recursive 1200/240 (no preprocessing)                         0/60
 8    LineBasedSplitter 20/5                                        3/60
 9    LineBasedSplitter 50/10                                       0/60
```

The curve has no clear monotonic direction in chunk size (6 at 2000, 3 at 400,
0 at 4000 AND 0 at 1200). The "right" chunk size is brittle — there is no
smooth gradient along this axis on this dataset.

### What didn't work and why

1. **Shrinking chunk size (400, 600, 1200).** The hypothesis was that smaller
   chunks concentrate per-query topic signal. Outcome: lost both the summary's
   whole-doc boost AND the transcript's best chunk simultaneously. Small chunks
   of transcripts are dominated by filler; the summary's whole-doc vector at
   2000/200 coincidentally sits on a good manifold, and shrinking
   reveals/promotes many other transcripts' cleaner chunks that outrank ours.

2. **Enlarging chunk size (2500+, 4000).** Averages out too much. By 4000 chars
   every chunk looks topically like a generic meeting transcript and the
   target can't beat more topical neighbours.

3. **Noise filter (skip files with <50 chars meaningful body).** 137 files
   skipped — all title-only `notes.md` stubs. Signal-to-noise improved on
   phrase queries (top 20 is now all transcripts, correct file-class), BUT the
   target's `summary.md` lost its topical-adjacency boost from sharing a top-20
   with those stubs. Net effect: target summary drops from rank 3 to rank 4+.
   The noise files were paradoxically helping by diluting the competing
   topical density among other summaries/transcripts.

4. **Transcript filler strip (drop "yeah/okay/right" turns).** Makes
   transcripts ~60% shorter and visibly denser on manual inspection. Does NOT
   move the target in rankings: the competing transcripts also get denser
   (they're also conversation files), and no differential advantage accrues.

5. **LineBasedSplitter (20 lines / 5 overlap, 50 lines / 10 overlap).** Similar
   story: small gives 3/60 (matches 400/80 recursive), large gives 0/60. The
   line boundary is not qualitatively better than the recursive-character
   boundary for this corpus.

### Root-cause analysis (what would actually work)

Apple NLEmbedding (`sentenceEmbedding(for: .english)`, 512-dim) is weak at
exact phrase matching. Confirmed empirically: only 4 files in the entire
corpus contain literal "bean counter" text (our 2 targets + 2 duplicates of
the same other meeting), yet NONE surface in top 10 for the query
`"bean counter mode"`. A transcript discussing "bean counters on your team"
(different meeting, different topic) outranks both literal phrase-matches.

The embedding is topic-dominated. It effectively averages over ~300-token
windows and returns a generic "business meeting about trademarks" vector
for most of our test queries. Under that model, the specific meeting cannot
win on phrase evidence.

### Suggested follow-up experiments

1. **Swap the embedder.** Switch from `NLEmbedding.sentenceEmbedding(.english)`
   to a modern open-weights model (nomic-embed-text-v1.5, BGE-small,
   intfloat/e5-small-v2) via CoreML. Biggest expected lift because it changes
   the fundamental signal, not how we cut the corpus. Flagged in the brief as
   the "biggest lift" — we're now out of cheaper levers to try.

2. **Hybrid retrieval (vector + lexical).** Add a BM25 or simple
   substring-score pass so exact phrases like "bean counter" are rewarded
   separately from cosine similarity. Cheap to add, large expected effect on
   phrase queries (Q8–Q10). This addresses the core failure mode observed:
   literal phrase matches that cosine similarity can't surface.

3. **Query expansion.** Before embedding each query, expand with 2–3 LLM-
   generated paraphrases and combine scores. May help Q1–Q6 where the user's
   phrasing differs from the corpus phrasing.

4. **Multi-granularity indexing.** Index the same file at multiple chunk sizes
   (e.g. 400 + 2000 + whole) and let the ranker see all three. Requires
   dedup at query time. Medium effort; not attempted here because every
   single-config attempt peaked at 6/60, so a union of configs has a known
   ceiling at ~6/60 plus marginal gains.

5. **Per-file-type tuning.** The summary and transcript have different
   retrieval profiles. The summary (~900 chars) always gets a `.whole`
   vector; the transcript (~5KB) gets chunk-competition. Different chunking
   strategies for `summary.md` vs `transcript.txt` files might help — but
   requires knowing file type at index time, which the extractor currently
   doesn't branch on.

### Commit plan

No code change beat the default. Baseline config is already the default; no
commit is necessary. The optimizer's deliverable is this log + the
recommendations above.
