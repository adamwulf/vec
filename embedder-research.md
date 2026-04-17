# Embedder Alternatives for `vec` — Research Survey

## Why this document exists

Our overnight tuning experiment (see `bean-test-results.md`) established that the
current embedder — Apple's `NLEmbedding.sentenceEmbedding(for: .english)`,
512-dim, on-device — is the retrieval bottleneck. The best configuration we
found scored **6/60** on a realistic test set; no chunking or preprocessing
lever moved that number meaningfully. The follow-up plan recommended swapping
the embedder itself.

This document surveys realistic embedder options, evaluates each on the axes
that matter for our codebase (dimensions, offline, privacy, integration
effort), and proposes an integration roadmap.

**Scope:** research only. No code changes. No corpus benchmarking (that is the
next agent's job).

---

## 1. Executive summary

1. **Top recommendation for quality lift while keeping things on-device:**
   `nomic-embed-text-v1.5` via a small Swift embedder package (either
   `swift-embeddings` by `jkrukowski` using `MLTensor`, or `llama.cpp` in GGUF
   form). **768 dims, Matryoshka-truncatable to 512 or 256**, Apache-2.0,
   MTEB 62.28. This keeps our privacy + offline guarantees, is the best
   documented modern open-weights embedder with Swift-callable paths, and its
   Matryoshka property means we can pick a dimension that matches our existing
   sqlite-vec schema (512) with almost zero quality loss.
2. **Fastest path to a quality lift, if we accept a network dependency:**
   OpenAI `text-embedding-3-small` — 1536 dims, $0.02 / 1M tokens, roughly on
   par with the small open-source models on MTEB (~62%) but with far cleaner
   integration (just HTTP). A one-afternoon swap.
3. **Avoid:** `NLContextualEmbedding` as a drop-in. It's Apple's newer
   contextual model but Apple's own docs explicitly redirect to `NLEmbedding`
   for semantic similarity; it emits per-token sequences, not a sentence
   vector. Also avoid `MLX` as a primary path — the mature Swift story is
   still thin (`MLXEmbedders` is a nascent library in `mlx-swift-lm`).
4. **Parallel lever worth doing regardless of which embedder wins:** add
   hybrid retrieval (BM25 / substring score fused with cosine). The bean-test
   diagnostic showed literal phrases like "bean counter" failing on cosine
   even when the literal phrase was in the target doc — a classic
   embedding-model failure mode that lexical ranking solves for free.

---

## 2. Comparison table

All "Quality" numbers below are MTEB average-score-on-MTEB v1 (English) from
the model's own card unless otherwise noted. Higher is better; our current
baseline (NLEmbedding) has no published MTEB score but behaves, anecdotally
and on our bean-test corpus, well below the small open-source models.

| Option | Dims | Size on disk | Offline | Privacy | Swift effort | Quality (MTEB) | License / cost |
|---|---|---|---|---|---|---|---|
| **Current: `NLEmbedding.sentenceEmbedding`** | 512 | ~50 MB (built-in) | yes | local | (in use) | not published; empirically poor for retrieval | free, Apple system framework |
| **OpenAI `text-embedding-3-small`** | 1536 (↓ configurable) | n/a (API) | **no** | **text leaves machine** | small — HTTP client, auth | ~62.3 | $0.02 / 1M tokens |
| **OpenAI `text-embedding-3-large`** | 3072 (↓ configurable) | n/a (API) | no | text leaves machine | small — HTTP client, auth | ~64.6 | $0.13 / 1M tokens |
| **OpenAI `text-embedding-ada-002`** (legacy) | 1536 | n/a (API) | no | leaves machine | small | ~61.0 | $0.10 / 1M tokens |
| **Voyage-4-lite** | 1024 (configurable 256/512/2048) | n/a (API) | no | leaves machine | small — HTTP | reportedly competitive; MTEB not in docs we could fetch | paid API |
| **Voyage-4** / voyage-4-large | 1024 (configurable) | n/a (API) | no | leaves machine | small — HTTP | competitive | paid API |
| **Cohere `embed-english-v3`** | 1024 | n/a (API) | no | leaves machine | small — HTTP | "SOTA among 90+ on MTEB" at release (Nov 2023) | paid API |
| **`nomic-embed-text-v1.5` (CoreML/MLTensor/GGUF)** | 768 Matryoshka-truncatable to 512/256/128/64 | safetensors sizes vary by precision — see HF file listing; GGUF Q8_0 ≈ 140 MiB, GGUF fp16 ≈ 262 MiB | yes | local | medium — swift-embeddings *or* llama.cpp | 62.28 @768, 61.96 @512, 61.04 @256 | Apache-2.0 |
| **`BAAI/bge-small-en-v1.5` (CoreML)** | 384 | ~130 MB | yes | local | medium — CoreML conversion + tokenizer | 62.17 | MIT |
| **`sentence-transformers/all-MiniLM-L6-v2` (CoreML)** | 384 | ~86 MB | yes | local | **low** — already ships in `similarity-search-kit` as `MiniLMAll` (46 MB quantised) | ~56 (community-reported; not published on the model card) | Apache-2.0 |
| **`intfloat/e5-small-v2`** | 384 | ~130 MB | yes | local | medium — CoreML conversion | similar to `bge-small`; needs `query:` / `passage:` prefixes | MIT |
| **`mixedbread-ai/mxbai-embed-large-v1`** | 1024 | ~670 MB (fp16) | yes | local | medium — CoreML conversion; large asset | 64.68 avg, 54.39 retrieval | Apache-2.0 |
| **Ollama (local server) + any of nomic / mxbai / minilm** | varies (768 / 1024 / 384) | same as underlying model | yes (local server required) | local | small — HTTP client, but user must install/run Ollama | same as underlying model | free |
| **LM Studio (local server) OpenAI-compatible endpoint** | varies | same as model | yes (local server required) | local | small — reuse OpenAI HTTP client | same as underlying model | free |
| **`NLContextualEmbedding` (Apple, macOS 14+)** | model-dependent (read at runtime via `NLContextualEmbedding.dimension`; 512/768 are values observed from one specific English variant), **per-token sequences, not sentence vector** | system | yes | local | medium — would need our own pooling strategy; Apple explicitly says to use `NLEmbedding` for semantic similarity | unknown; not designed for this use case | free, Apple system framework |
| **`similarity-search-kit` bundled models** (`MiniLMAll`, `MiniLMMultiQA`, `Distilbert`) | 384 / 384 / varies | 46 MB / 46 MB / 86 MB | yes | local | **low** — SPM drop-in | MiniLM ~56; MultiQA comparable | Apache-2.0 |
| **`swift-embeddings` (MLTensor, SPM)** | model-dependent | model-dependent | yes (after first-run model download from HF) | local | low-medium — SPM drop-in, model downloaded from HF | depends on model chosen | MIT (package) |

---

## 3. Per-option detail

### 3.1 OpenAI embeddings API

- **Source:** <https://platform.openai.com/docs/guides/embeddings>, announcement blog at <https://openai.com/index/new-embedding-models-and-api-updates/>.
- **Models & dims:**
  - `text-embedding-3-small` — 1536 dims default, shortenable via `dimensions` API param (the "Matryoshka-like" shortening OpenAI described at launch).
  - `text-embedding-3-large` — 3072 dims default, shortenable.
  - `text-embedding-ada-002` — 1536, legacy.
- **Pricing** (per 1M input tokens, early 2026 prices via multiple third-party trackers):
  - `3-small`: **$0.02** standard / $0.01 batch.
  - `3-large`: **$0.13** standard / $0.065 batch.
  - `ada-002`: $0.10.
- **Quality (MTEB):** `3-small` ≈ 62.3, `3-large` ≈ 64.6, `ada-002` ≈ 61.0
  (figures from OpenAI's launch blog plus independent confirmations).
- **Rate limits:** tier-dependent. Rate limits for embedding endpoints are
  substantially higher than chat TPM limits and scale up as spend increases.
  The Batch API has a separate enqueued-tokens quota. Always check
  platform.openai.com → Settings → Limits for current tier numbers.
- **Batch support:** yes, via the standard Batch API (50% discount, 24-hour
  SLA). For an indexer that runs overnight, batch is ideal.
- **Offline:** no. Every embedding is a network round-trip.
- **Privacy:** text leaves the machine. OpenAI's data-usage policy says API
  inputs are not used for training by default, but it's still a non-local
  leakage surface.
- **Swift effort:** very small. Plain HTTPS POST to
  `https://api.openai.com/v1/embeddings` with `Authorization: Bearer $KEY` and
  `{ "model": "text-embedding-3-small", "input": [...], "dimensions": 512 }`.
  Using the `dimensions` parameter to pin output at 512 lets us keep the
  existing sqlite-vec schema.
- **Risk:** requires user to provide and store an API key, and to be online.

### 3.2 Voyage AI

- **Source:** <https://docs.voyageai.com/docs/embeddings>.
- **Models (current generation, Voyage-4 series):** `voyage-4-large`,
  `voyage-4`, `voyage-4-lite`, all 1024 dims default with flexible 256 / 512 /
  2048 output options. Previous `voyage-3` series still available. Also
  domain-tuned variants: `voyage-code-3`, `voyage-finance-2`, `voyage-law-2`.
- **Context:** 32,000 tokens.
- **Batch:** up to 1,000 texts per request; 1M total tokens for lite models,
  320K for standard.
- **Pricing / MTEB:** not listed in the docs page we could fetch; separate
  pricing page.
- **Offline:** no.
- **Swift effort:** same as OpenAI, one HTTP client.
- **Why it's interesting:** Anthropic recommends Voyage as their embedding
  partner; if we ever integrate with Claude for query-side LLM work, this is
  the paved road.

### 3.3 Cohere embed-v3

- **Source:** <https://cohere.com/blog/introducing-embed-v3>,
  <https://docs.cohere.com/docs/cohere-embed>.
- **Models:** `embed-english-v3.0`, `embed-multilingual-v3.0`.
- **Dims:** 1024; context 512 tokens.
- **Quality:** SOTA among 90+ models on MTEB at its November 2023 launch.
- **Offline:** no.
- **Pricing:** see <https://cohere.com/pricing>; we didn't pull current per-token numbers.
- **Swift effort:** HTTP POST; same shape as OpenAI.

### 3.4 Local: `nomic-embed-text-v1.5`

- **Source:** <https://huggingface.co/nomic-ai/nomic-embed-text-v1.5>,
  paper at <https://arxiv.org/html/2402.01613v2>.
- **Dims:** 768 default, Matryoshka-truncatable. Reported MTEB per truncation
  (from the HF card):
  - 768 → 62.28
  - 512 → 61.96
  - 256 → 61.04
  - 128 → 59.34
  - 64 → 56.10
- **Size on disk:** ~0.1B params. Safetensors file sizes vary by precision
  and should be read from the HF file listing. GGUF quantised variants at
  <https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF> are smaller:
  Q8_0 ≈ 140 MiB, fp16 ≈ 262 MiB.
- **Max sequence length:** 8192 tokens (dynamic RoPE scaling).
- **Required prefixes:** yes — `search_document: ...` when indexing,
  `search_query: ...` when querying. Important: both the indexer and the
  search command would need to add these.
- **Thread-safe for shared instance:** unknown — depends on the inference
  backend. `swift-embeddings` / `MLTensor` thread-safety is not documented;
  llama.cpp's context is not thread-safe for concurrent calls on one context
  but is fine across independent contexts. **Verify before integration** —
  see §4 memory-footprint discussion.
- **First-run UX / distribution:** via `swift-embeddings` the weights
  download from Hugging Face on first use (see §3.13). Bundling the GGUF /
  safetensors as SPM resources trades a multi-hundred-MB binary for offline
  determinism.
- **License:** Apache-2.0.
- **Quality vs NLEmbedding:** expected to be a substantial step up. MTEB 62.28
  puts it above `text-embedding-ada-002` (61.0) and roughly at
  `text-embedding-3-small`.
- **Swift integration paths (in order of effort):**
  1. **`swift-embeddings` (MLTensor):** <https://github.com/jkrukowski/swift-embeddings>. SPM-compatible, claims support for BERT / ModernBERT / **NomicBERT** / RoBERTa / etc., models loaded from Hugging Face Hub. Uses Apple's `MLTensor` (no CoreML conversion needed by us). Likely the lowest-effort local path.
  2. **llama.cpp via GGUF:** official Swift-package-manifest support at <https://swiftpackageindex.com/ggml-org/llama.cpp>, though the repo warns that its `Package.swift` uses `unsafeFlags(_:)` and many projects wrap it in an `XCFramework` binary target for cleaner semver (see issue <https://github.com/ggml-org/llama.cpp/issues/10371> and the iOS/macOS discussions <https://github.com/ggml-org/llama.cpp/discussions/4423>). We would call into llama.cpp's C/C++ API, load `nomic-embed-text-v1.5.Q8_0.gguf`, and enable embedding mode.
  3. **CoreML conversion by us:** use `huggingface/exporters` → coremltools to convert; then load with plain CoreML. Most work, but gives us full control and best on-device inference performance.

### 3.5 Local: `BAAI/bge-small-en-v1.5`

- **Source:** <https://huggingface.co/BAAI/bge-small-en-v1.5>.
- **Dims:** 384.
- **Size:** 33.4M params (~130 MB fp16; much smaller quantised).
- **Max sequence length:** 512 tokens.
- **MTEB:** 62.17 average.
- **Prefix:** optional query prefix `"Represent this sentence for searching relevant passages:"` for retrieval tasks.
- **License:** MIT.
- **Swift integration:** same options as nomic — `swift-embeddings`,
  llama.cpp GGUF, or custom CoreML conversion. BGE is a BERT-architecture
  model so all three paths work.
- **Pros:** small (half the size of nomic), no mandatory prefix, high MTEB
  for its size.
- **Cons:** 512-token context is short vs nomic's 8192, which could matter
  if we ever want to embed bigger chunks.
- **Thread-safe for shared instance:** unknown — backend-dependent (same
  caveat as nomic). Verify before integration.
- **First-run UX / distribution:** same as nomic — `swift-embeddings`
  downloads on first use; alternatives are SPM-bundled resources or a
  separate fetch step.

### 3.6 Local: `sentence-transformers/all-MiniLM-L6-v2`

- **Source:** <https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2>.
- **Dims:** 384. **Already shipping in `similarity-search-kit`** as the
  `MiniLMAll` preset (46 MB quantised CoreML) — this is the lowest-friction
  local swap we have available.
- **Size:** 22.7M params.
- **MTEB:** commonly reported ~56 in community benchmarks; the HF model card
  itself does not publish an overall MTEB average (only per-task numbers, e.g.
  ArguAna 50.17). Still almost certainly better than NLEmbedding for
  retrieval given how old NLEmbedding's training data is.
- **Max sequence length:** 256 word pieces.
- **License:** Apache-2.0.
- **Thread-safe for shared instance:** unknown — via
  `similarity-search-kit`'s CoreML path, safety depends on whether the
  converted MLModel is called from a single queue. Verify before integration.
- **First-run UX / distribution:** model ships inside
  `similarity-search-kit` as a bundled resource — no network required on
  first run. Lowest-friction distribution story of the local options.

### 3.7 Local: `intfloat/e5-small-v2`

- **Source:** <https://huggingface.co/intfloat/e5-small-v2>.
- **Dims:** 384.
- **Prefixes:** **mandatory** — `query: ...` for queries, `passage: ...` for
  documents. Forgetting these significantly degrades retrieval.
- **License:** MIT.
- **Why consider:** E5 is often cited in RAG papers; `multilingual-e5-small`
  is a good fallback if we ever need multilingual coverage.

### 3.8 Local: `mixedbread-ai/mxbai-embed-large-v1`

- **Source:** <https://huggingface.co/mixedbread-ai/mxbai-embed-large-v1>.
- **Dims:** 1024 default (configurable via Matryoshka `truncate_dim`; MRL
  supported per the HF card — contradicting the "in the making" claim from
  the launch blog).
- **MTEB:** 64.68 average, 54.39 retrieval. Beats `nomic-embed-text` (49.01
  retrieval). Beats `text-embedding-3-large` on MTEB average (64.68 vs 64.58)
  but **loses on the retrieval subtask** (54.39 vs 55.44).
- **Size:** 335M params (BERT-large). Fp16 weights ≈ 670 MB — largest of the
  local options.
- **License:** Apache-2.0.
- **Trade-off:** highest quality of the local options, but ships 5-6x more
  weights than nomic. Plausible if we're comfortable with a one-time 700 MB
  download on first run.
- **Thread-safe for shared instance:** unknown — backend-dependent. Verify
  before integration.
- **First-run UX / distribution:** same pattern as nomic / BGE — weights
  download on first use via `swift-embeddings`; bundling a 670 MB asset in
  SPM resources is almost certainly a non-starter, so expect a separate
  fetch step in practice.

### 3.9 Apple `NLContextualEmbedding` (macOS 14+)

- **Source:** <https://developer.apple.com/documentation/naturallanguage/nlcontextualembedding>.
- **What it is:** an upgrade to `NLEmbedding` that returns contextualised
  vectors (BERT-like) instead of static word embeddings. Apple's intended use
  is as a feature extractor for text classification / word tagging with
  CreateML.
- **Dimensions:** model-dependent; Apple's own docs do not publish a fixed
  number. The dimension is read at runtime via `NLContextualEmbedding.dimension`
  and there are multiple model identifiers per language. The 512 / 768
  figures are values observed in one specific English variant exercised by
  the `buh/NaturalLanguageEmbeddings` demo — not a general contract.
- **Max sequence length:** documented, finite; returns a sequence of
  per-token vectors, not a single sentence vector.
- **Critical caveat (direct Apple quote in the docs page we fetched):**
  "For semantic similarity tasks, consider using `NLEmbedding`." Apple
  specifically directs semantic-similarity use cases back to the embedder we
  are already using.
- **What this means for us:** using `NLContextualEmbedding` would require us
  to design our own pooling (mean / CLS / attention) to collapse the
  sequence to a single vector. That is a research project in its own right,
  and Apple has already told us it's not the sweet spot for this class of
  model. **Not recommended** as a drop-in.

### 3.10 Ollama local server

- **Source:** <https://ollama.com/blog/embedding-models>.
- **Supported embedders:** `nomic-embed-text` (137M), `mxbai-embed-large`
  (334M), `all-minilm` (23M).
- **Dimensions:** 768 / 1024 / 384 respectively.
- **API:** `POST http://localhost:11434/api/embed` with `{ "model": ..., "input": ... }`.
- **Pros:** no Swift embedding code to write at all — just an HTTP client.
- **Cons:** external process dependency. User must `ollama pull nomic-embed-text`
  and keep the Ollama daemon running. That's a harsh onboarding story for a
  CLI tool that currently needs zero external setup.
- **Fit for our tool:** plausibly an *optional* backend via a flag, not the
  default.

### 3.11 LM Studio local server

- **Source:** <https://lmstudio.ai/docs/api/endpoints/openai>.
- **Same shape as Ollama** — a local server that speaks the OpenAI API. If we
  implement the OpenAI client, we get LM Studio for free by letting users
  point `OPENAI_BASE_URL` at `http://localhost:1234/v1`.
- **Same on-boarding friction** as Ollama: external app to install and run.

### 3.12 `similarity-search-kit` (Zach Nagengast)

- **Source:** <https://github.com/ZachNagengast/similarity-search-kit>.
- **SPM-compatible**, macOS 13+, ships with CoreML-converted embedder models
  out of the box: `MiniLMAll` (46 MB), `MiniLMMultiQA` (46 MB), `Distilbert`
  (86 MB), plus an `NLEmbedding` adapter.
- **API:** one protocol method, `func encode(sentence: String) async -> [Float]?`.
- **Why interesting:** this is the lowest-friction path to *any* non-NL
  embedder in our codebase. Drop the dep in `Package.swift`, construct
  `MiniLMEmbeddings()`, call `encode(sentence:)`, get a 384-dim vector.
- **Caveat:** the bundled models are older and cap out around MTEB ~56.
  Better than NLEmbedding, not as good as nomic / BGE / OpenAI. Useful as a
  stopgap or as the reference integration that we then swap the model on.

### 3.13 `swift-embeddings` (MLTensor, jkrukowski)

- **Source:** <https://github.com/jkrukowski/swift-embeddings>.
- **License:** MIT (per the GitHub repo).
- **SPM-compatible**. Uses Apple's `MLTensor` framework (no CoreML
  conversion needed).
- **Supported architectures:** BERT, ModernBERT, NomicBERT, RoBERTa,
  XLM-RoBERTa, CLIP text, Word2Vec, Model2Vec, static embeddings.
- **Example supported models:** `sentence-transformers/all-MiniLM-L6-v2`,
  `nomic-ai/nomic-embed-text-v1.5`, `intfloat/multilingual-e5-small`.
- **Why interesting:** this is the most promising Swift-native path to
  `nomic-embed-text-v1.5` specifically, without writing our own CoreML
  conversion. Models download from Hugging Face on first use.
- **Distribution / first-run UX caveat:** "downloads from HF on first use"
  breaks the offline-capable contract for any user running `vec` offline on
  first launch. Options: (a) bundle model weights as SPM resources — large
  binary, potentially multi-hundred-MB; (b) leave download-on-demand as-is
  and document the online-first-run requirement; (c) ship a separate
  `vec fetch-models` step that users run once before going offline. This
  choice has real integration cost and user-facing implications.

### 3.14 MLX and MLX-Swift

- **Source:** <https://github.com/ml-explore/mlx-swift>,
  <https://github.com/ml-explore/mlx-swift-lm>.
- **Status:** `MLXEmbedders` is listed as "popular Encoders / Embedding
  models example implementations" inside `mlx-swift-lm`, but the README
  doesn't enumerate tested embedder models. The Python side
  (<https://github.com/Blaizzy/mlx-embeddings>) is much more developed and
  supports BERT, ModernBERT, multilingual-e5, etc.; the Swift side lags.
- **Models in `mlx-community`:** `mlx-community/all-MiniLM-L6-v2-4bit` exists
  on HF, converted from sentence-transformers.
- **Fit for us:** plausible but currently higher effort than `swift-embeddings`
  or `similarity-search-kit`. Worth re-evaluating in 6-12 months.

---

## 4. Integration roadmap — what a swap actually touches

For each candidate, here is what we would have to change in this repo.

### 4.1 Abstraction layer (do this regardless of which embedder wins)

Today `EmbeddingService` is a concrete class that hard-wires
`NLEmbedding.sentenceEmbedding(for: .english)`. The first commit of any swap
should make it a protocol so we can swap implementations without touching
callers:

```swift
public protocol Embedder: Sendable {
    var dimension: Int { get }
    func embed(_ text: String) async -> [Float]?
}
```

Then rename the current class to `NLEmbedder: Embedder`, and callers
(`IndexBuilder`, `search` command, `update-index`) depend on the protocol.

**Switching to `async` is not a cosmetic type change.** Every call site on
the path needs await-ification, not just the protocol definition. Concrete
production callsites that currently construct or invoke `EmbeddingService`
(enumerated from `grep`):

- `Sources/vec/Commands/SearchCommand.swift:60` — `EmbeddingService()` at
  query time and the immediately-following `.embed(query)` call.
- `Sources/VecKit/IndexingPipeline.swift:646` — `EmbedderPool` constructs N
  instances inside `init` (`EmbeddingService()` in a map). This is the
  primary integration point — `EmbedderPool`, not `IndexingPipeline` at
  large.
- `Sources/VecKit/IndexingPipeline.swift:672` — warmup loop calls
  `embedder.embed("warmup text")` on every pooled instance.
- `Sources/VecKit/IndexingPipeline.swift:360` — in-pipeline per-chunk
  `embedder.embed(chunk.text)` call (after `pool.acquire()`).

If the new `Embedder.embed` returns `async`, all four lines need `await`
plus surrounding context-propagation changes. `EmbedderPool` itself is
already an actor and its `acquire` / `release` are already async, so most
of the actor boundary is fine — but the synchronous `.embed` inside the
task group at :360 and inside `warmAll()` at :672 are the lines that flip
from sync to async. Plan this as an async-ification of the whole call path.

Touched files (concrete list):
- `Sources/VecKit/EmbeddingService.swift` — split into protocol + impl.
- `Sources/VecKit/IndexingPipeline.swift` — three call sites (constructor,
  warmup, per-chunk embed).
- `Sources/vec/Commands/SearchCommand.swift` — one query-side call site.
- Add a factory that reads config/CLI flag to pick the impl.
- `Tests/VecKitTests` — see §4.6 for specific test files that break.

### 4.2 Database: variable dimensions

`VectorDatabase.init` already takes `dimension: Int = 512`, and the embedding
is stored as a raw Float32 blob — *no* schema-level dimension constraint. That
means bigger/smaller vectors drop in without a migration of the schema, but
**cross-embedder reuse of an existing index is unsafe** because stored vectors
won't be comparable.

Concrete changes:
- Write the embedder identifier (e.g. `nomic-embed-text-v1.5@512`) into a new
  `metadata` table at `initialize()` time, and refuse to `open()` a DB whose
  identifier doesn't match the current embedder.
- Expose a `vec reindex --embedder ...` command for the forced rebuild.
- Update `indexed_files` nothing needed — the completion records are per-file
  and remain valid conceptually; we just invalidate them together with
  chunks.

Touched files (1-2):
- `Sources/VecKit/VectorDatabase.swift` — add `embedding_metadata` table,
  `verifySchema` check, error type.
- CLI wiring for a `reindex` path (if not already covered).

### 4.3 Config / CLI surface

Current `update-index` already has `--chunk-chars` and `--chunk-overlap`. Add:
- `--embedder {nl|nomic|minilm|bge|openai|voyage|ollama}`
- `--embedder-dimensions N` (for models that support Matryoshka / shortening —
  nomic, OpenAI 3-*, Voyage-4).
- For API backends: `--api-key-env` (defaults to `OPENAI_API_KEY`,
  `VOYAGE_API_KEY` etc.) and `--base-url` (lets LM Studio / Ollama pretend to
  be OpenAI).
- Persist the chosen embedder in the DB metadata table (§4.2) so `search`
  doesn't need the flag again.

**API-key handling scope:** explicitly env-var-only in v1 — the CLI reads
the key from the environment variable named by `--api-key-env` (default
`OPENAI_API_KEY`). **Punt keychain integration as out-of-scope** for the
initial swap; it is worth doing eventually but shouldn't block the
research-to-implementation path. Do **not** add a literal `--api-key`
flag: any value passed that way lands in shell history and process-list
output, which is a real leak surface. If a future version wants
interactive key entry, use a read-from-stdin prompt, not an argv flag.

### 4.4 `Package.swift` deltas per option

| Option | New dependency |
|---|---|
| OpenAI / Voyage / Cohere / LM Studio / Ollama | none — hand-roll `URLSession` |
| `similarity-search-kit` bundled model | `.package(url: "https://github.com/ZachNagengast/similarity-search-kit", ...)` |
| `swift-embeddings` (nomic / MiniLM / e5) | `.package(url: "https://github.com/jkrukowski/swift-embeddings", from: "0.0.16")` |
| llama.cpp (GGUF nomic / bge) | `.package(url: "https://github.com/ggml-org/llama.cpp", ...)` or an XCFramework binary target |
| Custom CoreML conversion | none (system CoreML) |

### 4.5 Memory footprint under the current pool model

`EmbedderPool(count: concurrency)` is constructed in `IndexingPipeline.init`
at `IndexingPipeline.swift:174-179` with
`concurrency: Int = max(ProcessInfo.processInfo.activeProcessorCount, 2)`.
On typical Apple Silicon that's 8-12 instances. Each pooled instance is a
**separate copy of the model weights**, because the pool exists to work
around NLEmbedding's documented thread-unsafety (see
`Tests/VecKitTests/NLEmbeddingThreadSafetyTests.swift` — the regression
canary that segfaults if a single instance is shared across tasks).

Concrete memory pictures for a 10-wide pool:

| Embedder | Per-instance weights | Pool total (x10) |
|---|---|---|
| `NLEmbedding` (current) | ~50 MB | ~500 MB |
| `nomic-embed-text-v1.5` GGUF Q8_0 | ~140 MiB | ~1.4 GB |
| `all-MiniLM-L6-v2` quantised | ~46 MB | ~460 MB |
| `bge-small-en-v1.5` | ~130 MB | ~1.3 GB |
| `mxbai-embed-large-v1` fp16 | ~670 MB | ~6.7 GB |

**Implication:** unless a candidate embedder is thread-safe for a single
shared instance — in which case we can collapse the pool to one and save
the N× multiplier — the pool size needs to be reconsidered per-candidate.
`mxbai-embed-large-v1` at pool width 10 is effectively disqualifying on a
16 GB MacBook.

Each per-option detail in §3 lists a "Thread-safe for shared instance"
line. Anything marked "unknown" must be verified empirically (mirroring
what `NLEmbeddingThreadSafetyTests` does for NLEmbedding) before we commit
to pool size.

### 4.6 Test migration — specific assertions that break

Any embedder that doesn't produce 512-dim vectors breaks these specific
lines:

- `Tests/VecKitTests/VecKitTests.swift:40` — `XCTAssertEqual(result?.count, 512)`.
- `Tests/VecKitTests/VecKitTests.swift:65` — same 512 assertion on long-text path.
- `Tests/VecKitTests/VecKitTests.swift:70` —
  `XCTAssertEqual(service.dimension, 512)`.
- `Tests/VecKitTests/NLEmbeddingThreadSafetyTests.swift:19` —
  `private static let expectedDimension = 512` (used at :33 via
  `XCTAssertEqual(embedding.dimension, Self.expectedDimension, ...)`).

These need to be parameterised on `embedder.dimension` (or the 512
literal replaced with the new model's dimension) at minimum. The
thread-safety test (`NLEmbeddingThreadSafetyTests`) is specifically about
NLEmbedding's runtime — if we migrate to a new embedder, consider adding
an analogous concurrency canary for it rather than only mutating this one.

### 4.7 Migration path for existing DBs

Because we're storing vectors as raw BLOBs with no dimension constraint, the
safest path is:
1. Detect "old embedder" via the new `embedding_metadata` check on `open()`.
2. Emit a user-facing message: *"This index was built with NLEmbedding / 512
   dims. The current embedder is nomic-embed-text-v1.5 / 768 dims. Run
   `vec reindex` to rebuild (~N minutes)."*
3. Provide `vec reindex` that wipes `chunks` + `indexed_files` and
   re-walks the source directory.

No in-place vector "conversion" is possible — it's a full rebuild either way.

---

## 5. Recommendation ranking

Ranked by best-quality-per-unit-of-effort *while preserving our current
on-device, no-API-key, no-daemon-required UX*:

1. **`swift-embeddings` + `nomic-embed-text-v1.5` @ 512 dims via Matryoshka.**
   Keeps our 512-dim schema. SPM drop-in. MTEB 61.96 @512 is a dramatic
   upgrade from NLEmbedding. Mandatory query / passage prefixes are a minor
   code change in `EmbeddingService` and the `search` command. If
   `swift-embeddings` behaves well on our corpus, ship it.

2. **`similarity-search-kit` with `MiniLMAll`.** Lowest integration effort of
   all local options (one SPM import, one `encode()` call). Quality ceiling
   is lower (MTEB ~56) but still clearly above NLEmbedding. Good as a
   *stopgap* or as the reference integration we then swap the model on.

3. **OpenAI `text-embedding-3-small` @ 512 dims** (via the `dimensions` API
   param). Biggest quality/effort ratio if we're willing to give up on-device.
   Same 512-dim schema. Costs pennies at our corpus size (~10K chunks ≈
   ~5M tokens ≈ $0.10 one-time). Needs a permissioned API-key story and
   explicit "your text leaves the machine" notice.

   **Caching caveat — resolve before the OpenAI swap lands.** The "$0.10
   one-time" figure assumes each chunk is embedded exactly once. Today
   `update-index` re-embeds chunks whenever a file is modified, with no
   cache keyed by `(content_hash, embedder_id)`. For a purely local
   embedder that's fine — cost is only wall-clock. For a paid API it
   matters: an author who re-saves the same file repeatedly pays for each
   round trip. Before shipping OpenAI support, add a per-chunk content-hash
   cache so unchanged text reuses its stored vector across re-indexes.
   Suggested key: `(sha256(chunk_text), embedder_id, embedder_dim)`.

4. **Ollama backend via HTTP.** Zero embedding code to write; piggyback on an
   OpenAI client. But forces every user to install and run a separate
   daemon, which conflicts with our "single Swift executable" ethos. Do this
   only as an optional `--embedder ollama` switch, not default.

5. **`mxbai-embed-large-v1` or `voyage-4-large`.** Top-tier quality but
   significantly more integration friction (670 MB local weights, or a paid
   API with separate auth). Reserve for a second pass if the primary choice
   plateaus.

### Suggested next experiment (for the next agent)

Re-run the bean-test optimiser (`bean-test.md`) with the winner candidate
from the above ranking plugged in. Minimum viable comparison:

1. Pin chunk config at the known-winning baseline (Recursive, 2000 chars,
   200 overlap, no preprocessing — per `bean-test-results.md`).
2. Swap embedder to **`nomic-embed-text-v1.5` @ 512 dims** via
   `swift-embeddings`. Re-index. Score 10 queries.
3. If ≥ 30/60 (the "huge win" bar), also test **@ 768 dims** to see if the
   full model gives another bump. Update schema dim if so.
4. If < 30/60, fall back to **`text-embedding-3-small` @ 512 dims** (API) to
   isolate whether the ceiling is model quality or the corpus itself. Our
   retrieval was so poor (6/60) that any reasonable 2026-era embedder should
   clear 20+/60; if it doesn't, we have a deeper problem (chunking boundary,
   metadata leakage, query formulation) that no embedder can fix.

---

## 6. Sources

- OpenAI: <https://platform.openai.com/docs/guides/embeddings>, <https://openai.com/index/new-embedding-models-and-api-updates/>, <https://developers.openai.com/api/docs/models/text-embedding-3-small>, <https://developers.openai.com/api/docs/guides/rate-limits>.
- Voyage: <https://docs.voyageai.com/docs/embeddings>.
- Cohere: <https://cohere.com/blog/introducing-embed-v3>, <https://docs.cohere.com/docs/cohere-embed>.
- Nomic: <https://huggingface.co/nomic-ai/nomic-embed-text-v1.5>, <https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF>, <https://arxiv.org/html/2402.01613v2>.
- BGE: <https://huggingface.co/BAAI/bge-small-en-v1.5>.
- MiniLM: <https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2>.
- E5: <https://huggingface.co/intfloat/e5-small-v2>.
- Mixedbread: <https://huggingface.co/mixedbread-ai/mxbai-embed-large-v1>, <https://www.mixedbread.com/blog/mxbai-embed-large-v1>.
- Ollama: <https://ollama.com/blog/embedding-models>.
- Apple `NLContextualEmbedding`: <https://developer.apple.com/documentation/naturallanguage/nlcontextualembedding>.
- `NaturalLanguageEmbeddings` demo: <https://github.com/buh/NaturalLanguageEmbeddings>.
- `similarity-search-kit`: <https://github.com/ZachNagengast/similarity-search-kit>.
- `swift-embeddings`: <https://github.com/jkrukowski/swift-embeddings>.
- MLX-Swift: <https://github.com/ml-explore/mlx-swift>, <https://github.com/ml-explore/mlx-swift-lm>.
- MLX-Embeddings (Python): <https://github.com/Blaizzy/mlx-embeddings>.
- llama.cpp Swift package: <https://swiftpackageindex.com/ggml-org/llama.cpp>, discussion of iOS/macOS use <https://github.com/ggml-org/llama.cpp/discussions/4423>, known SPM issue <https://github.com/ggml-org/llama.cpp/issues/10371>.
- LM Studio OpenAI-compatible endpoint: <https://lmstudio.ai/docs/api/endpoints/openai>.
