# Bean Test — Chunk-size / splitter tuning for vec search

## The problem

A conversation transcript mentions the phrase "bean counter mode" in the
context of a trademark price negotiation. With the current default chunk
size (2000 chars, RecursiveCharacterSplitter), `vec search` does **not**
surface the target files for semantically relevant queries — even though
`grep -r "bean counter"` finds them immediately.

Hypothesis: the phrase is too small a fraction of a 2000-char chunk, so
its signal is averaged out of the chunk's 512-dim sentence-embedding
vector. Shrinking the chunk should increase the phrase's weight in the
vector and restore retrieval.

## Target files (what we need the search to surface)

The "win" condition is these two files appearing in the **top 10** of
search results for the test queries below:

- `granola/2026-02-26-22-30-164bf8dc/transcript.txt` (the raw conversation;
  the actual "bean counter" phrase appears on line 118 and line 134)
- `granola/2026-02-26-22-30-164bf8dc/summary.md` (line 32 — the "Pricing
  Discussion" section explicitly mentions "Gets Adam 'out of bean counter
  mode' for quick execution")

## Corpus

- **Path:** `/Users/adamwulf/Library/Containers/com.milestonemade.EssentialMCP/Data/Documents/tools/markdown-memory`
- **Size:** ~100+ markdown/transcript files. Mix of meeting transcripts,
  summaries, research docs, and notes. This is the real noise floor the
  target files have to beat.
- **DB name:** `markdown-memory` (in `~/.vec/markdown-memory/`). Safe to
  reset/rebuild repeatedly — it's a test index.

## Test queries

These are what a generic agent might try if asked "where did I negotiate
the price for the trademark? I was in bean counter mode." They range from
direct phrase overlap (easy) to paraphrased intent (hard), so a good
config should lift all of them:

1. `trademark price negotiation bean counter`
2. `where did I negotiate the price for the trademark`
3. `bean counter mode`
4. `haggling over trademark price`
5. `1.5 million trademark deal`
6. `out of bean counter mode for quick execution`
7. `muse trademark pricing discussion`
8. `counter offer for trademark assets`
9. `how much did we ask for the trademark`
10. `trademark deal pricing move quickly`

## Scoring rule

For each query, run `vec search --db markdown-memory --format json
--limit 20 "<query>"` and inspect the resulting JSON. Per query:

- **+3 points** if `granola/2026-02-26-22-30-164bf8dc/transcript.txt`
  appears in positions 1–3
- **+2 points** if it appears in positions 4–10
- **+1 point** if it appears in positions 11–20
- **+0 points** if absent
- Same scoring for `summary.md` in that folder, independently

Max score per query = 6 (both files in top 3). Max total across 10 queries
= 60. **Target: at least 40 total points, AND both files in top 10 for
≥6 of the 10 queries.** That's the "keep" threshold.

Stop conditions (any of):
- Both files in top 10 for ≥8 of 10 queries AND total score ≥ 45
- User wakes up and checks in
- Total wall-clock exceeds 10 hours

## Tunable variables

The agent can adjust any of these. Each full-run reindex is needed when
changing splitter config.

### Already exposed as CLI flags (on `update-index`)

- `--chunk-chars N` — max chunk size in characters (default 2000)
- `--chunk-overlap N` — chunk overlap in characters (default 200)

### Requires a small code change to enable

- **Splitter choice.** `TextExtractor(splitter:)` accepts any
  `TextSplitter`. The codebase ships two:
  - `RecursiveCharacterSplitter` (char-based, default) —
    `Sources/VecKit/RecursiveCharacterSplitter.swift`
  - `LineBasedSplitter` (line-based, heading-aware) —
    `Sources/VecKit/LineBasedSplitter.swift`. Defaults: 30 lines, 8 overlap.
  To test LineBasedSplitter, add a CLI flag `--splitter line|recursive` or
  temporarily hardcode it in `UpdateIndexCommand.swift`.

- **Separators.** `RecursiveCharacterSplitter.defaultSeparators` is
  `["\n\n", "\n", ". ", " "]`. For conversational transcripts with no
  paragraph breaks, it may be worth trying `["\n", ". ", "? ", "! ", " "]`
  (add per-sentence separators, drop `\n\n`) or similar. Pass via the
  splitter's `separators:` init parameter.

- **Whole-document embedding.**
  `Sources/VecKit/TextExtractor.swift:69` adds a `.whole` chunk when the
  document fits in 10 000 chars (the NLEmbedding cap). Worth verifying
  whether transcripts are short enough to get this — if yes, the whole
  chunk might be "winning" over tight small chunks and masking the fix.
  If no, no difference.

### Higher-effort levers (still fair game — no restraints)

The user has explicitly greenlit changing anything: splitter, chunk
strategy, indexer, pre-processing, the embedder itself. Use judgment on
what's worth the time — roughly in order of effort:

- **Text pre-processing.** Transcripts have a ton of filler ("yeah,
  yeah," "okay?", "right, right"). A simple cleanup pass before chunking
  (collapse repeated acknowledgements, normalize speaker tags) could
  dramatically increase signal density per chunk. Low-ish effort, high
  potential upside for this specific corpus.

- **Multi-granularity indexing.** Index the same file at multiple chunk
  sizes (e.g. 200 AND 800) and let the ranker see both. Requires more DB
  storage but can give "exact phrase" and "broader context" both a path
  to surface. Medium effort.

- **Query-side expansion.** Before searching, expand the query with
  synonyms/paraphrases and combine scores. Outside the index but a
  legitimate lever. Medium effort.

- **Different embedder.** `NLEmbedding.sentenceEmbedding(for: .english)`
  is Apple's default and fine, but a modern open-weights model (nomic-
  embed, BGE, E5) on CoreML is a real upgrade. **Biggest lift** — changes
  dimension (VectorDatabase stores 512-dim), storage layout, and adds a
  model-download step. Only attempt if simpler levers fully exhaust.
  Flag it as a finding with recommended next steps if reached.

## Iteration protocol

Work on branch `agent/agent-c54ba5da` (where this file lives). For each
iteration:

1. Pick a config (start small: chunk-chars 400, overlap 80).
2. Reset the test index:
   - `vec reset --db markdown-memory --yes` (if that's the reset flag;
     check `vec reset --help` first)
   - Alternatively: `rm -rf ~/.vec/markdown-memory && vec init ...` —
     check `vec init` syntax.
3. Rebuild:
   - `cd` to the corpus root:
     `/Users/adamwulf/Library/Containers/com.milestonemade.EssentialMCP/Data/Documents/tools/markdown-memory`
   - `vec update-index --db markdown-memory --chunk-chars N --chunk-overlap M`
4. Run all 10 queries through `vec search --db markdown-memory
   --format json --limit 20 "<query>"`. Parse JSON, score per the rule
   above.
5. Append a row to `bean-test-results.md` (create if missing). One row per
   iteration. Columns:
   `timestamp | config | total_score | queries_hit_top10 | notes`
   Plus a per-query score breakdown in an indented block under the row.
6. If the iteration beat the previous best, note it as a new high-water
   mark. Do NOT commit code changes per iteration — only keep the log.
7. Decide the next config based on the trend (bigger/smaller chunk?
   different overlap? different splitter?).

At the end (stop condition hit OR search space exhausted):
- Pick the winning config.
- Commit ONE change that makes that config the new default for this use
  case (either updating the `RecursiveCharacterSplitter` default values,
  or changing the `UpdateIndexCommand` default, whichever is more
  appropriate).
- Write a final summary section in `bean-test-results.md`:
  - Winning config
  - Trajectory (how scores moved across iterations)
  - What didn't work and why
  - Any suggested follow-up experiments

## Known working commands (verified)

**ALWAYS invoke the CLI via `swift run vec <subcommand>`.** This is
covered by the existing `Bash(swift:*)` permission allowlist and
auto-rebuilds incrementally on code changes, so you don't need a
separate `swift build` step between iterations. Do NOT use
`.build/debug/vec` — it's not on the allowlist and will block on a
permission prompt with no one to approve it.

Concrete commands:
- Wipe the test DB: `swift run vec reset --db markdown-memory --force`
- Rebuild the index:
  `cd /Users/adamwulf/Library/Containers/com.milestonemade.EssentialMCP/Data/Documents/tools/markdown-memory && swift run --package-path /Users/adamwulf/Developer/swift-packages/vec/.ittybitty/agents/<your-worktree>/repo vec update-index --db markdown-memory --chunk-chars N --chunk-overlap M`
  (or invoke from the repo root without `cd` — the DB name alone is
  enough to locate it, `--db markdown-memory` resolves to `~/.vec/markdown-memory/`)
- Run a scored search:
  `swift run vec search --db markdown-memory --format json --limit 20 "your query"`

## Helpful context

- `RecursiveCharacterSplitter` deliberately emits NO chunks when the
  whole document fits in `chunkSize`, because a `.whole` chunk already
  covers it. This means short files produce only the whole-doc vector,
  which is an important fact when reasoning about small chunk sizes.
- The `summary.md` target file is SHORT (~900 chars). It will only ever
  have a `.whole` embedding under any chunk-size configuration — its
  retrieval depends entirely on how well "bean counter mode for quick
  execution" survives in an average of the whole doc's vector. If the
  summary is a persistent miss while the transcript works, that's a
  known limitation, not a tuning failure.
- The `transcript.txt` target file is LONG and will produce many chunks
  under small configs. Its retrieval should improve dramatically as
  chunks shrink.
