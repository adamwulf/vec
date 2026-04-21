# Bean Test — Retrieval tuning for vec search

## The problem

Adam has a corpus of meeting transcripts and summaries. One specific
meeting covers a trademark price negotiation where he talked about being
in "bean counter mode" and counter-offering $1.5M. With the current
default chunk size (2000 chars, RecursiveCharacterSplitter), `vec search`
does **not** reliably surface that meeting for plausible queries someone
might type to find it — even when `grep` finds exact phrase matches.

**The real goal:** a user searching for "where did I negotiate the
trademark price?" (or any similar paraphrase) should find that meeting in
the top results. The "bean counter" phrase is just one of many possible
queries — do NOT over-optimize on that specific phrase. The win is that a
variety of reasonable queries all surface the right meeting, including
ones that don't mention "bean counter" at all.

Hypothesis: the current 2000-char chunks average out signal for any
specific phrase or topic. Shrinking chunks (or switching splitters, or
adding pre-processing, or any other lever) should increase topical
concentration per chunk and restore retrieval quality broadly.

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

These are what a generic agent might try if asked to find the trademark
negotiation meeting. They deliberately span from exact-phrase ("bean
counter") to generic-topical ("trademark assignment meeting") so the
config can't just win by memorizing one specific idiom. A good config
lifts ALL of them, not just the phrase-heavy ones.

**Core topical queries** (no "bean counter" phrase — these test that the
meeting surfaces on its actual subject matter):

1. `trademark price negotiation`
2. `where did I negotiate the price for the trademark`
3. `muse trademark pricing discussion`
4. `counter offer for trademark assets`
5. `how much did we ask for the trademark`
6. `trademark assignment agreement meeting`
7. `right of first refusal trademark`

**Phrase-leaning queries** (these should also work, but the config
shouldn't only win on these):

8. `bean counter mode trademark`
9. `1.5 million trademark deal`
10. `trademark deal move quickly quick execution`

Do not collapse these to a smaller set. The whole point is to see that
the config generalizes across phrasings.

## Scoring rule

**Canonical sources of truth:**

- `scripts/rubric-queries.json` — the 10 queries, the 2 target files,
  and the rank-bracket → points mapping. Edit this file to change the
  rubric; nothing else hard-codes the numbers.
- `scripts/score-rubric.py` — the scorer. Reads the manifest above,
  consumes a directory of `q01.json` … `q10.json`, emits the rank
  table and the `TOTAL: X/60, TOP10_EITHER: N/10, TOP10_BOTH: M/10`
  line. If a human count disagrees with the script, the script is
  right.

For each query, run `vec search --db markdown-memory --format json
--limit 20 "<query>"` and save the JSON. Per query:

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

You (the optimizer) are a **manager** agent — you can and should spawn
sub-agent workers with `ib new-agent --worker "..."` to keep your own
context window clear. Running 10 searches' JSON output through your own
context every iteration is wasteful; a worker can crunch the JSON and
hand you back one tidy score block.

For each iteration:

1. **Pick a config.** Start small (chunk-chars 400, overlap 80). Later,
   drive the next config from the trend in the relevant results log
   (e.g. `data/retrieval-nl.md`, `data/retrieval-nomic.md`, or a
   new `data/retrieval-<embedder>.md` if you're running a fresh
   experiment).

2. **Reset the test index:**
   `swift run vec reset --db markdown-memory --force`

3. **Rebuild the index:**
   `swift run vec update-index --db markdown-memory --chunk-chars N --chunk-overlap M`
   (from anywhere in the repo — --db is enough to locate the DB)

4. **Delegate scoring to a worker sub-agent.** Spawn a `--worker` with a
   self-contained prompt containing the 10 queries and the scoring rule:

   ```
   ib new-agent --worker "Run these 10 search queries against the vec
   markdown-memory DB and score results. For each query, run:
     swift run vec search --db markdown-memory --format json --limit 20 \"<query>\"
   Parse the JSON array (index 0 = rank 1). For each of the two target
   files, score:
     - rank 1-3: +3
     - rank 4-10: +2
     - rank 11-20: +1
     - absent: 0
   Target files:
     - granola/2026-02-26-22-30-164bf8dc/transcript.txt
     - granola/2026-02-26-22-30-164bf8dc/summary.md
   Queries: [paste the full list of 10 queries from retrieval-rubric.md]
   Return a markdown block like:
     | # | query | T rank | S rank | T score | S score | subtotal |
     plus a final line: TOTAL: X/60, QUERIES_HIT_TOP10: N/10
   When done, signal: ib send <your-manager-id> 'Scoring complete: X/60, N/10'
   "
   ```

   Pass your own agent ID as `<your-manager-id>` (it's in the ittybitty
   manager banner at session start). When the worker signals complete,
   read its output with `ib look <worker-id>`, extract the score block,
   then `ib kill <worker-id> --force`.

5. **Append to the relevant `retrieval-results-<embedder>.md`** (create
   if missing). One row per iteration:
   `timestamp | config | total_score | queries_hit_top10 | notes`
   Plus the per-query score block from the worker, indented.

6. If the iteration beat the previous best, note it as a new high-water
   mark. Do NOT commit code changes per iteration — only keep the log.

7. Decide the next config based on the trend. Spawn the next iteration's
   scoring worker in parallel with your own work on picking the next
   config if it helps — workers are cheap, manager context is precious.

At the end (stop condition hit OR search space exhausted):
- Pick the winning config.
- Commit ONE change that makes that config the new default for this use
  case (either updating the `RecursiveCharacterSplitter` default values,
  or changing the `UpdateIndexCommand` default, whichever is more
  appropriate).
- Write a final summary section in the results log:
  - Winning config
  - Trajectory (how scores moved across iterations)
  - What didn't work and why
  - Any suggested follow-up experiments
- Kill any remaining sub-agent workers with `ib kill <id> --force` before
  signaling completion.

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

## Running a baseline

This section is the recipe for producing a fresh per-embedder baseline
on the markdown-memory corpus. Every new embedder, default-flip, or
chunking change should generate one of these so retrieval-quality and
wallclock numbers stay comparable across rounds.

The deliverable is one `retrieval-results-<alias>.md` file (create if
missing) plus an archived JSON dump of the scored search runs. Both go
in the repo root next to the existing rubric files.

### 1. Reindex markdown-memory with the target embedder

`markdown-memory` is a test DB — Adam has OK'd wiping it at any
time and leaving it in whatever embedder/chunk configuration the
last sweep landed on. No `cd` needed (see CLAUDE.md "DO NOT cd"):

```bash
swift run vec reset --db markdown-memory --force
time swift run vec update-index \
  --db markdown-memory \
  --embedder <alias> \
  --chunk-chars <N> --chunk-overlap <M> \
  --verbose
```

Capture from `time`:
- `real` wallclock (the headline number for the results log)

Capture from the trailing `[verbose-stats]` one-liner:
- `files`, `chunks`, `batches`
- `extract_ms`, `embed_ms`, `save_ms` (per-stage totals)
- `pool_util` (target ≥ 0.95 — sub-0.9 is the canary that something is
  starving the pool, see `experiments/E4-batched-embed/plan.md` §"Pool-util accounting")
- `chunks_per_sec`, `batches_per_sec`

The `[verbose-stats]` line is grep-friendly on purpose; copy it
verbatim into the results log so future readers can reparse it
without rerunning.

### 2. Capture the 10-query JSON to the benchmarks archive

All 10 query texts live in `scripts/rubric-queries.json` — the single
source of truth. Use the manifest rather than copying the queries
into a shell loop by hand (drift kills reproducibility):

```bash
mkdir -p benchmarks/<alias>-<N>-<M>
for i in $(seq 1 10); do
  n=$(printf "%02d" $i)
  text=$(jq -r ".queries[$((i-1))].text" scripts/rubric-queries.json)
  swift run vec search \
    --db markdown-memory \
    --format json --limit 20 \
    "$text" \
    > benchmarks/<alias>-<N>-<M>/q${n}.json
done
```

The archived JSONs are committed — see `benchmarks/README.md`. This
is what lets a future reader rescore a historical sweep when the
scoring rule or the scorer itself evolves (exactly what happened to
bge-base on 2026-04-20 — a 2026-04-19 manual count was off by 3
points; the archive let us fix the record).

### 3. Score

```bash
python3 scripts/score-rubric.py benchmarks/<alias>-<N>-<M>/
```

The script prints the rank table and the canonical TOTAL line. Copy
both verbatim into `data/retrieval-<alias>.md`. The script's output
is the authoritative score — do not hand-edit it.

### 4. Append to `data/retrieval-<alias>.md`

Every results log row MUST carry these columns so cross-embedder
comparison is mechanical, not eyeballed (closes phase-2 docs NB14):

| Column | Source | Notes |
| --- | --- | --- |
| `timestamp` | run-time UTC | ISO 8601 |
| `commit` | `git rev-parse --short HEAD` | so the row is replayable |
| `alias` | the `--embedder` value | e.g. `bge-base` |
| `chunk_chars` / `overlap` | the flags passed | the other half of the profile identity |
| `corpus_files` / `corpus_chunks` | from `[verbose-stats]` | corpus-shape sanity check |
| `wallclock_real_s` | `time` output | end-to-end index time |
| `extract_ms` / `embed_ms` / `save_ms` | `[verbose-stats]` | per-stage breakdown |
| `pool_util` | `[verbose-stats]` | < 0.9 = investigate before trusting wallclock |
| `chunks_per_sec` | `[verbose-stats]` | apples-to-apples throughput |
| `total_score` | rubric tally | out of 60 |
| `queries_hit_top10` | rubric tally | out of 10 — the load-bearing criterion |
| `notes` | freeform | hardware, thermal state, any caveats |

Below the table row, paste the per-query score block and the verbatim
`[verbose-stats]` line. One block per iteration.

### 5. Mark the new high-water mark (if any)

If the run beat the previous best on `queries_hit_top10` (primary) or
`total_score` (tiebreak), note it as the new winner for that alias.
Cross-alias winners are decided in `experiments/PhaseD-embedder-expansion/plan.md`'s
"Final comparison" table, not here.

### 6. Commit the results log + archived JSONs

One commit per baseline run, message format:

```
baseline: <alias>@<chunkChars>/<overlap> — <total_score>/60, <hits>/10 top-10
```

Body: paste the table row plus a one-line summary of what was novel
about this run (new embedder? swept chunk size? cold vs warm cache?).
