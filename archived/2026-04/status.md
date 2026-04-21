# vec — retrieval quality status (2026-04-18)

> **⚠ SUPERSEDED — 2026-04-20.** This snapshot reflects the state
> *before* the Phase D embedder expansion (bge-base, nl-contextual)
> and the E4 batched-embedding work. The current default is
> **`bge-base@1200/240`** (rubric **36/60, 9/10 top-10**), not
> nomic. For the live picture see:
> - `embedder-expansion-plan.md` §"Final comparison" — current
>   per-model rubric/throughput numbers
> - `e4-next-steps-report.md` — batched-embedding outcome and
>   wallclock data
> - `indexing-profile.md` — the four built-in profiles that ship today
>
> Below preserved as historical context for the nomic-only era.

## Where things stand

**Retrieval ceiling raised from 6/60 → 35/60** (5.8×) by replacing Apple's
`NLEmbedding.sentenceEmbedding` with `nomic-embed-text-v1.5` at 768 dims,
plus chunking tuned to `RecursiveCharacterSplitter` **1200/240**.

The nomic migration and sweep is **complete and merged** on this branch.
179 tests pass. Defaults in `RecursiveCharacterSplitter.swift` are now
1200/240.

## Ship gate was NOT hit

The retrieval ship gate is 45/60 AND 7/10 both-target-top-10 queries.
Actual: 35/60, 3/10. See `retrieval-results-nomic.md` for the full
sweep trajectory and per-query detail.

The binding constraint is the **transcript** (granola 164bf8dc) being
absent from top 20 on several topical queries (Q1, Q3, Q6). The
corpus has ~a-dozen meetings on the same trademark topic, and the
embedder correctly ranks the more-topical documents higher. Pure-vector
retrieval is out of runway against that noise floor — the remaining
levers are **not** chunking or embedder tuning.

## Follow-up levers (in rough priority order)

1. **Hybrid retrieval (BM25 + vector)** — a lexical channel rewards
   exact phrase matches ("bean counter", "1.5 million") that pure
   vector smooths out. Expected 5–10 pts on this rubric. Biggest lift.
2. **Query expansion** — generate 2–3 paraphrases per query (LLM or
   local), aggregate results. Lift on topical queries (Q1–Q6).
3. **Multi-granularity indexing** — index each file at both 1200/240
   and a smaller size (e.g. 400/80), let the ranker see both.
4. **Per-file-type defaults** — `summary.md` files are short enough
   that `.whole` is always the interesting embedding; `transcript.txt`
   benefits from chunking. Branch at index time.
5. **Pluggable embeddings + embedder comparison** — swap in BGE-large,
   E5-large, Jina. Requires refactoring `EmbeddingService` to a protocol
   + per-embedder config persisted per DB. Was queued as "Phase A" in the
   nomic agent's todo but not started.

## Infra that changed during the nomic migration

- `swift-tools-version: 6.0`, `.macOS(.v15)` platform minimum.
- `swift-embeddings` 0.0.26 dependency (jkrukowski).
- `EmbeddingService` is now an actor with `embedDocument(_:)` /
  `embedQuery(_:)` — prefixes `search_document: ` / `search_query: `
  per nomic's training. Dimension is 768.
- `EmbedderPool` collapsed to a single shared actor instance
  (swift-embeddings is actor-safe under concurrent load).
- Model weights cache at `~/Documents/huggingface/nomic-ai/…` on first
  use. Cache is "download once, reuse forever." Adds ~140 MiB +
  tokenizer files on first run.
- Tests: `NLEmbeddingThreadSafetyTests` rewritten as
  `NomicEmbedderConcurrencyTests` (20-task canary). XCTest smoke test
  with an `mach_task_basic_info` RSS guardrail added.

## What to hand the next agent

If the next task is a follow-up experiment from the "levers" list above,
point the new agent at:

- `retrieval-rubric.md` — 10 queries + scoring rule (do not modify).
- `retrieval-results-nl.md` — NLEmbedding baseline history (6/60 ceiling).
- `archived/nomic-experiment-plan.md` — the executed plan (for plan
  shape and review-cycle discipline; reuse the structure for new
  experiments).
- `retrieval-results-nomic.md` — detailed sweep data, per-iter tables,
  trajectory, and the explicit "what didn't work" section. This should
  be extended (not overwritten) if the next experiment is comparable.
- This file (`status.md`) — the snapshot you're reading.

The next experiment should pick ONE lever (don't stack multiple), state
a measurable ship gate upfront, and follow the same phased structure:
(1) plan → (2) review-cycle the plan → (3) implement → (4) review-cycle
the impl → (5) measure against the retrieval rubric.

## Budget notes

The nomic agent used ~19h of 24h. Each reindex of the full
markdown-memory corpus runs 25–190 min depending on chunk count;
scoring runs fit comfortably inside 5–10 min. Budget the next
experiment accordingly — parameter sweeps burn wall-clock on reindexing,
not on scoring.
