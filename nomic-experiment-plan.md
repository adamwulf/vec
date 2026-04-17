# Experiment: swap NLEmbedding → `nomic-embed-text-v1.5`

## The goal

Find out whether swapping our embedder from Apple's `NLEmbedding.sentenceEmbedding`
to `nomic-embed-text-v1.5` lifts retrieval quality on the bean-test corpus from
its current ceiling of **6/60** (see `bean-test-results.md`).

This is an isolated experiment, not a production swap. The experiment branch
should be prepared so we can decide — based on numbers — whether to invest in a
full migration (DB dim change, async-ification of the call path, caching,
distribution UX). None of that work belongs in this experiment; keep the
scaffolding minimal.

## Success criteria

Use the same 10 queries and scoring rubric from `bean-test.md`. Three gates:

- **Ship gate:** ≥ 30/60 total, AND both target files in top 10 on ≥ 4/10 queries.
  "This is a real lift; proceed to plan the full migration."
- **Interesting gate:** 15–29/60. "Moves the needle but not a landslide. Worth
  testing a follow-up lever (hybrid BM25, larger dim, different chunk config)."
- **Kill gate:** < 15/60. "Nomic at 512 dims isn't the answer for this corpus.
  Record the result and revisit whether the bottleneck is chunking, the corpus,
  or query formulation — not the embedder."

Record the result with per-query table, same format as `bean-test-results.md`.

## Back-compat is NOT a constraint

The user is the only user of this tool and can reindex at will. We do NOT
need:

- `--embedder` flag preserving NLEmbedding as the default.
- A protocol with two implementations coexisting.
- A persisted DB config to guard against embedder/index mismatch.
- An `EmbedderPool` of N copies (if nomic is thread-safe, use one; if not,
  use N).
- Support for the 512-dim sqlite-vec schema if a different dim performs better.

Just rip out NLEmbedding and replace it. Pick the embedder config that
produces the best score, not the config that is easiest to roll back from.

## Fixed variables (do not retune)

- Chunker: `RecursiveCharacterSplitter`, 2000 chars / 200 overlap (baseline —
  proven optimum by the prior experiment; changing both embedder AND chunking
  at once would muddle the signal).
- Test corpus: `~/Library/Containers/com.milestonemade.EssentialMCP/Data/Documents/tools/markdown-memory`.
- Test DB: `markdown-memory` (safe to wipe/rebuild; already used by the prior
  experiment).
- Test queries: the exact 10 from `bean-test.md`. Do not add or remove any.

## Free variables (pick one each, document which)

- **Model precision.** Start with GGUF **Q8_0** (~140 MiB) via llama.cpp OR the
  default MLTensor format via `swift-embeddings`. We want the lightest option
  that exercises the full quality — Q8 is widely understood to be
  quality-indistinguishable from fp16 at a fraction of the size.
- **Output dim.** Start at **768** (the full model). Back-compat isn't a
  constraint, so there's no reason to truncate unless the larger dim fails to
  justify its cost. If 768 lands in the ship gate, it's the winner. If it
  lands in the interesting gate, retest at 512 and 256 to see whether the
  Matryoshka truncation meaningfully sacrifices quality for speed/storage.
- **Prefix handling.** `search_document:` on every indexed chunk;
  `search_query:` on every search query. Non-negotiable — nomic was trained
  with these.

## Integration path

**Use `swift-embeddings` (jkrukowski/swift-embeddings, MIT, SPM-compatible,
MLTensor-based).** Rationale:

- Explicit NomicBERT support per its README.
- Pure Swift, pure SPM — no CoreML conversion, no llama.cpp build system.
- Models download from Hugging Face on first use (see "Network concern" below).
- The same package can host future model swaps (BGE, MiniLM, E5) without
  re-architecting.

This is the lowest-effort path that gives a real answer.

### Do NOT do

- Don't add chunk-content caching. Out of scope — relevant only for the OpenAI
  path and this is local.
- Don't keep a protocol-switched NLEmbedding fallback path. Just replace it.
- Don't change the scoring worker's query list or rubric.
- Don't keep API knobs (env vars, flags) that exist only to preserve the old
  embedder's behavior.

## Code changes (minimum viable)

The codebase currently has a single concrete `EmbeddingService` class used
directly at three sites:

- `Sources/VecKit/IndexingPipeline.swift` — inside `EmbedderPool.init` (line ~646)
- `Sources/VecKit/IndexingPipeline.swift` — warmup loop (line ~672)
- `Sources/vec/Commands/SearchCommand.swift` — at the top of `run()` (line ~60)

Swap approach (back-compat is not a constraint):

1. **Replace `EmbeddingService`'s implementation** with `swift-embeddings`
   wrapping `nomic-embed-text-v1.5`. Give it two methods —
   `embedDocument(_ text: String)` and `embedQuery(_ text: String)` — that
   prepend `search_document: ` and `search_query: ` respectively before
   calling into the package.
2. **Update the three call sites** to use the right method. Indexing-time
   callers (`IndexingPipeline` pool + warmup) use `embedDocument`.
   `SearchCommand` uses `embedQuery`.
3. **Update `dimension`** — if the chosen dim isn't 512, update
   `VectorDatabase`'s assumptions and any test asserts. The existing DB schema
   stores raw BLOBs with no dimension enforcement (verified in
   `VectorDatabase.swift:59,505-529` per the reviewer), so changing `dimension`
   plus a one-time `vec reset` is enough. No migration code needed.
4. **EmbedderPool**: if `swift-embeddings` / MLTensor is thread-safe for a
   shared instance, collapse the pool to a single instance (saves gigabytes at
   concurrency = 10 for a 768-dim model). If not, keep the pool of N. The
   agent should check by reading `swift-embeddings` source and trying a
   concurrent-use test — document the answer in the experiment results.
5. **Remove NLEmbedding-specific code** (`NLEmbedding.sentenceEmbedding`,
   `maxEmbeddingTextLength` if nomic's limits differ, the
   `NLEmbeddingThreadSafetyTests.swift` regression canary — or rewrite it as
   a `NomicEmbedder` canary if relevant). We're replacing the embedder, not
   hedging.

Everything else — chunk-content caching, distribution UX (bundling vs
download-on-demand), keychain/env-var key handling — is **out of scope** for
this experiment. The deliverable is a score. If the score lands in ship or
interesting gate, a follow-up task will sort out distribution.

## Network concern (user-flagged)

`swift-embeddings` downloads weights from Hugging Face on first use. The model
is <https://huggingface.co/nomic-ai/nomic-embed-text-v1.5>. Files to verify
before doing anything else:

1. **Measure the download.** Before the experiment even starts, the agent
   should curl / `huggingface-cli` list the file sizes and report:
   - Total size of what `swift-embeddings` will actually pull (safetensors +
     tokenizer + config JSON). This is NOT the same as the GGUF numbers in the
     research doc (~140 MiB Q8 / ~262 MiB fp16) — swift-embeddings uses MLTensor,
     not GGUF.
   - Whether any tokenizer / config files are extra downloads.
2. **One-time-only.** Weights cache locally after first download. Running the
   experiment repeatedly does not re-download. Confirm the cache location and
   report it in the experiment log (so it can be manually seeded on other
   machines or mirrored to S3).
3. **S3 mirror is a future step, not this experiment's problem.** The agent
   does NOT need to set up mirroring — just confirm the cache structure is
   "download once, reuse forever" and note the cache path.

Report these three items in the experiment log BEFORE starting iteration 1.
If the download is unexpectedly large (> 1 GB), pause and ask before
proceeding — at that point Q8 GGUF via llama.cpp might be a better experiment
path.

## Execution protocol

1. **Pre-flight.** Report swift-embeddings HF download size, cache path, any
   surprises.
2. **Write the code changes** outlined above. Compile cleanly. Verify the
   NLEmbedding path still works (regression safety).
3. **Wipe test DB:** `swift run vec reset --db markdown-memory --force`.
4. **Reindex with nomic:**
   `swift run vec update-index --db markdown-memory`
   (chunk config defaults — no `--chunk-chars` / `--chunk-overlap`. No
   `--embedder` flag exists; we've replaced the embedder outright.)
5. **Score.** Spawn a worker sub-agent with the same scoring prompt shape as
   `bean-test.md` section "Iteration protocol" — same 10 queries, same rubric.
   Do NOT re-invent the queries. Command the worker uses:
   `swift run vec search --db markdown-memory --format json --limit 20 "<query>"`
6. **Write up `nomic-experiment-results.md`** with: swift-embeddings download
   size, cache path, per-query table, total score, which gate was hit,
   recommendation for next step.
7. **Do not commit the code changes if the kill gate is hit.** Just commit
   the results log. If the ship or interesting gate is hit, leave the code in
   place on the branch — the manager will decide what to merge.

## Hand-off

This plan is executed by a fresh agent on a new branch. When spawning, point
the agent at:

- This file (`nomic-experiment-plan.md`) for what to do.
- `bean-test.md` for the query list and scoring rubric.
- `bean-test-results.md` for the baseline that any result must be compared
  against.
- `embedder-research.md` §3.4 and §3.13 for nomic + swift-embeddings detail
  (dims, Matryoshka truncation, prefix requirement).
- `Sources/VecKit/EmbeddingService.swift` and the three call sites
  (`IndexingPipeline.swift`, `SearchCommand.swift`) for where code changes go.
