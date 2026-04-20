# Embedder Expansion — Plan

Agent: `agent-c54ba5da` (2026-04-19)

Supersedes the now-completed `indexing-profile-plan.md` work (Phases 1-5
shipped on this branch; Phase 6 merge-to-main deferred — this plan
continues on the same branch).

## Goal

Extend `vec` with additional on-device embedder options, tune their
chunking parameters per-embedder against the bean-counter rubric, and
publish a compare/contrast of all supported embedders on the
`markdown-memory` test corpus.

The IndexingProfile refactor (Phase 3a-3e, shipped) already made
adding new embedders a small, localized change:

- new `FooEmbedder: Embedder` file,
- one row in `IndexingProfileFactory.builtIns`,
- one case in the factory's `make(alias:)` switch,
- one default chunk size / overlap pair recorded in the row.

This plan exercises that path for 2-3 additional embedders and
optimizes their defaults.

Non-goals:
- Changing the `IndexingProfile` struct, identity grammar, or factory
  API (stable as of phase 3e).
- Hybrid retrieval (BM25 + dense), re-ranking, or query rewriting.
- GPU-accelerated embedders that require a non-Apple runtime (CUDA,
  ROCm) — macOS on-device only.
- iOS support — will be a bonus if the chosen embedders happen to
  ship iOS-compatible, but not a gate.

## Ship criteria

1. At least 2 new embedders landed as `IndexingProfileFactory`
   built-ins alongside `nomic` and `nl`, each with its own tests
   (factory row, canonical dim, identity parsing, profile-mismatch
   behavior).
2. Each new embedder has a per-alias default `chunkSize / chunkOverlap`
   selected by parameter sweep against `retrieval-rubric.md`, not
   copy-pasted from another alias.
3. A `retrieval-results-<alias>.md` file exists for each new embedder,
   following the same format as `retrieval-results-nomic.md` — one row
   per sweep iteration, final row marked as the selected default.
4. A final compare/contrast section in this doc records: alias,
   final identity (`alias@N/M`), rubric score (x/60), top-10 hit
   count (x/10), indexing throughput (files/sec), DB size per 1000
   chunks, model download/install size.
5. All tests green; no new CLI flags; no changes to existing profile
   behavior for `nomic` / `nl`.

## Constraints (locked in)

- **Platform**: macOS-first. iOS bonus only.
- **Model size budget**: < 10 GB total install + download cost across
  all added embedders.
- **Fitness function**: `retrieval-rubric.md` (10 queries × 2 target
  files, 0-60 points, max 10/10 top-10 hits) against the
  `markdown-memory` corpus.
- **Dependency stance**: anything goes. Prefer Apple / CoreML when
  available; sentence-transformers-via-CoreML next; llama.cpp / GGUF
  last.
- **Branch**: `agent/agent-c54ba5da`. Stays on this branch.

## Bean-counter rubric — known caveats

Relevant context from the Phase 5 sweeps we just completed:

- `nomic@1200/240` → **35/60, 8/10** (matches plan target ≈35/60).
- `nl@2000/200` → **0/60, 0/10** (plan expected ≈6/60 but the
  baseline was not reproducible on today's environment, even on the
  pre-refactor commit). Treat `nl` as the weak baseline, not a
  target.

So new embedders should be compared primarily against **nomic**.
Beating 35/60 or meaningfully closing the top-10 gap is the bar.

Also: the rubric is 10 queries. Expect ±2 points of noise per run.
Only move `chunkSize / chunkOverlap` in response to gaps larger
than that.

## Phase A — research sweep

**Owner**: one researcher sub-agent via `research-pi`.

**Deliverable**: a `embedder-research.md` file listing 4-8 candidate
on-device embedders. For each: name, canonical dim, integration
cost (Apple framework / CoreML ml package / llama.cpp GGUF /
other), approximate install size, license, rough retrieval quality
from MTEB or other public benchmarks, any known gotchas.

Candidates worth including in the survey (not exhaustive):
- Apple `NLContextualEmbedding` (newer than `NLEmbedding`,
  sentence-level, macOS 14+).
- `all-MiniLM-L6-v2` via CoreML — classic small baseline.
- `BGE-small-en-v1.5` / `BGE-base-en-v1.5` / `BGE-large-en-v1.5`
  via CoreML or GGUF.
- `gte-small` / `gte-base` / `gte-large` via CoreML or GGUF.
- `E5-small-v2` / `E5-base-v2` / `E5-large-v2`.
- `nomic-embed-text-v2-moe` (MoE, Matryoshka dims).
- `mxbai-embed-large-v1`.
- `snowflake-arctic-embed-*` family.

Researcher should rank by expected-quality-per-megabyte and flag
the 2-3 most promising "easy wins" for Phase B.

## Phase B — shortlist decision

**Owner**: user + manager.

Pick 2-3 candidates from Phase A output to actually implement.
Smallest / easiest first. Write the picks inline at the bottom of
this phase block (in this doc) with a one-line rationale each.

Picks (locked in 2026-04-19 after Phase A):

- [x] **Candidate 1 — bge-base-en-v1.5** (MIT, 768-dim, MTEB retrieval 53.25).
  Simplest to land — no query/doc prefix branching (v1.5 trained to work
  without the optional `"Represent this sentence for searching relevant passages: "`
  prefix). Proves the factory extension path for a second HuggingFace
  model loaded through the existing `swift-embeddings` dependency.
- [x] **Candidate 2 — snowflake-arctic-embed-m-v1.5** (Apache 2.0, 768-dim,
  MTEB retrieval 55.14). Best quality-per-MB of anything in the survey.
  Requires query-side prefix `"Represent this sentence for searching relevant passages: "`;
  documents get no prefix. Same BERT architecture → same swift-embeddings
  loader.
- [x] **Candidate 3 — Apple NLContextualEmbedding** (zero install, 512-dim,
  macOS 14+, iOS 17+). Only candidate with no download cost. Quality is
  speculative — no public MTEB number. Upgrade path for today's poor
  `nl-en-512`.

**Key integration finding (not in research doc):** The existing
`NomicEmbedder` already uses `swift-embeddings`' `NomicBert` loader,
NOT llama.cpp. BGE-base and Arctic-m-v1.5 are standard BERT-architecture
models and load via the **same** library's `Bert.loadModelBundle(from:)`
HuggingFace-hub helper — no new Swift-package dependency needed. The
research doc assumed a llama.cpp/GGUF path; in reality both top picks
reuse the existing HuggingFace-safetensors download path. Estimated
effort drops from 3-6 h per embedder to 1-2 h.

Key implementation note: `Bert.ModelBundle.encode(_,maxLength:)` returns
the CLS-token output (no `postProcess` param like NomicBert). BGE and
Arctic both use CLS-pooling by convention — this is exactly what we
want. But `Bert.encode` does NOT L2-normalize, so the new embedders
must normalize the returned vector themselves before returning.

## Phase C — per-embedder landing

**Owner**: one impl sub-agent per embedder. Each landing runs
through the `review-cycle` skill (2 reviewer agents in parallel)
before the next one starts.

Deliverables per embedder:
1. `Sources/VecKit/<Name>Embedder.swift` — new actor conforming
   to `Embedder`. Follows the shape of `NomicEmbedder.swift` /
   `NLEmbedder.swift`.
2. New row in `IndexingProfileFactory.builtIns` with a *provisional*
   `defaultChunkSize` / `defaultChunkOverlap` (nomic's values are a
   reasonable seed — real tuning happens in Phase D).
3. New case in the factory's `make(alias:)` switch.
4. Unit tests: `IndexingProfileFactory.builtIn(forAlias: "<new>")`
   returns correct canonical dim + defaults; `make(alias: "<new>")`
   constructs the right embedder type.
5. Smoke test: embed a single short fixture string, assert vector
   length matches canonical dim.

**No parameter tuning in Phase C.** Just wire the embedder up with
plausible defaults and verify it runs end-to-end against the
existing corpus.

## Phase D — per-embedder parameter tuning

**Owner**: manager (me), not a sub-agent. These sweeps touch the
user's real `markdown-memory` DB and are cheap to run locally.

Process per embedder:
1. Parameter grid: `chunkSize ∈ {500, 1200, 2000, 3000}` and
   `chunkOverlap ∈ {100, 240, 500}` — 12 points. Narrow or widen
   based on initial signal.
2. For each (size, overlap): `vec reset markdown-memory --force`,
   `vec update-index --embedder <alias> --chunk-chars N
   --chunk-overlap M`, run all 10 bean-counter queries, score
   against the rubric.
3. Record one row per iteration in
   `retrieval-results-<alias>.md` (same format as
   `retrieval-results-nomic.md`).
4. Pick the best-scoring `alias@N/M` as the new default, update
   the `builtIns` row, commit.

Parameter-sweep budget: 12 runs × ~5 min/run per embedder ≈ 1 h
per embedder. If an embedder is clearly non-competitive after
4 runs, STOP and move on — don't burn the full grid.

## Phase E — compare / contrast

**Owner**: manager.

Deliverables:
1. A new `### Final comparison` section at the bottom of this
   plan file with the table described in Ship Criteria #4.
2. Update `indexing-profile-plan.md`'s replacement note (this
   file's header) if any conclusions change the "nomic is
   default" decision.
3. Decide whether to change `IndexingProfileFactory.defaultAlias`.
   Default stays `nomic` unless another embedder beats it
   decisively (>5 points on the rubric or >2 extra top-10 hits)
   AND is not dramatically more expensive.

## Phase structure

Status legend: ✅ DONE · ⏳ NEXT UP · ◻ NOT STARTED.

| Status | Phase | Owner | Deliverable | Budget |
|:------:|------:|-------|-------------|-------:|
| ✅ DONE | A | researcher sub-agent (`embedder-researc-76b59360`) | `embedder-research.md` survey + ranked shortlist | 1-2 h |
| ✅ DONE | B | manager + user (picks locked 2026-04-19) | 3 picks written into Phase B above: bge-base, arctic-m-v1.5, NLContextualEmbedding | 15 min |
| ✅ DONE | C.1 | impl sub-agent (`bge-base-embedde-d9c3a224`) → review-cycle (both APPROVED) | bge-base-en-v1.5 wired in with tests (swift-embeddings `Bert` loader, CLS-pool + L2 norm, no prefix) | 1-2 h |
| 🚫 BLOCKED | C.2 | impl sub-agent (`arctic-m-47026f1e`) — rolled back, partial commit retained | snowflake-arctic-embed-m-v1.5: **blocked** (see "C.2 blocker" note below); shared `l2Normalize` helper + bge-base concurrency canary landed as consolation | 1-2 h |
| ⏳ NEXT UP | C.3 | impl sub-agent → review-cycle | Apple NLContextualEmbedding wired in with tests (NL framework, requestAssets, mean-pool + L2 norm, 256-token chunking) | 3-5 h |
| ◻ NOT STARTED | D | manager | Parameter sweep per embedder, winning defaults committed | 1 h × n |
| ◻ NOT STARTED | E | manager | Final compare/contrast report + default alias decision | 45 min |

When a phase ships, whoever ships it flips its row from ⏳/◻ to ✅
in the same commit and marks the next phase ⏳ NEXT UP.

### C.2 blocker — snowflake-arctic-embed-m-v1.5

Attempted 2026-04-19 by `arctic-m-47026f1e`. **Blocked** on
swift-embeddings' `Bert.loadModel` (at `BertUtils.swift:74-79`), which
unconditionally reads `pooler.dense.weight` / `pooler.dense.bias` from
the safetensors file. The Snowflake Arctic v1.5 model ships without
a BERT pooler (sentence-transformers models often strip it — the pooler
is unused at inference for CLS-pooled retrieval models). So load fails
with `missingTensorDataForKey("pooler.dense.weight")`.

Notably, `Bert.ModelBundle.encode` returns `sequenceOutput[0..., 0, 0...]`
— the CLS hidden state directly — and never consults the pooler output.
The pooler is purely a load-time requirement.

Paths forward (not taken now, recorded for future revisit):
- Patch swift-embeddings upstream / fork it to make the pooler optional
  in `Bert.loadModel`. Clean fix but touches dep management.
- Construct `Bert.Model` by hand, bypassing `loadModel` (build the
  embeddings + layers + layer-norm manually, pass a dummy pooler).
  Fragile; reimplements most of `BertUtils.loadModel`.
- Switch to a different loader path (e.g. a fork / a llama.cpp GGUF of
  the same model). Adds a new dependency.

For now: skip arctic-m, proceed to C.3 (NLContextualEmbedding,
independent integration path). Arctic stays in `embedder-research.md`
as a candidate to revisit when swift-embeddings exposes a
pooler-optional loader.

**Consolation landed** in `0c2c0f4`: extracted a shared `l2Normalize`
helper (`Sources/VecKit/EmbedderMath.swift`) so future BERT-family
embedders reuse one implementation; added a concurrency canary test
for `BGEBaseEmbedder` mirroring the Nomic canary.

## The relevant existing artifacts

- `Sources/VecKit/IndexingProfile.swift` — struct + factory + identity
  parser. Adding a new embedder edits `builtIns` and the `make`
  switch. Look at Nomic / NL rows for the template.
- `Sources/VecKit/Embedder.swift` — the protocol.
- `Sources/VecKit/NomicEmbedder.swift`,
  `Sources/VecKit/NLEmbedder.swift` — reference implementations.
- `retrieval-rubric.md` — the 10 queries and their 2 target files.
- `retrieval-results-nomic.md`, `retrieval-results-nl.md` — prior
  sweep data. Follow their format when writing new results.

### Final comparison

_(to be filled in at Phase E)_

| alias | identity | rubric | top-10 | files/sec | MB per 1k chunks | install size |
|-------|----------|--------|--------|-----------|------------------|--------------|
| nomic | nomic@1200/240 | 35/60 | 8/10 | _ | _ | _ |
| nl | nl@2000/200 | 0/60 | 0/10 | _ | _ | _ |
