# Embedder Alternatives for `vec` — Research Survey

## Constraint update (2026-04-17)

After the initial draft of this document, the user clarified that the
earlier constraint set — on-device, no API key, no daemon, Swift-native,
512-dim sqlite-vec schema preservation — was **over-tight**. The user is
the only user of this tool, can re-index at will, and wants "the best
embedder for the task", not the easiest swap.

Explicitly, the following are now OK:

- Throwing away the 512-dim sqlite-vec schema (any dim is fine).
- Full re-index on every change.
- Larger model sizes and memory footprints.
- Separate install steps — Ollama daemon, Docker, llama.cpp binary, a
  Python subprocess — if the quality win justifies it.
- A one-time HF download, OR a paid API, OR running a local server.
- Changing the runtime for the embedding layer entirely (e.g. calling out
  to a Python process).

Still preferred:

- Data privacy is nice-to-have, not a hard requirement. Hosted APIs
  (OpenAI, Voyage, Cohere, Google Gemini) are on the table if clearly
  best.
- "One-time network download then forever offline" is preferred over
  "every query hits the network" — but neither is disqualifying.

**The recommendation ranking below has been re-evaluated under these
constraints; see §5 for the revised ranking and §5.1 for models that the
original doc dismissed which now deserve a fresh look.**

§§1–4 are left intact as a record of the original reasoning and the
underlying technical / integration facts (those are still true; only the
weighting has changed).

---

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

**Re-evaluated 2026-04-17 under the loosened constraints in the opening
"Constraint update" section.** Primary axis is expected retrieval quality
on this corpus (small English, conversational transcripts + markdown
notes). Secondary axis is maturity / battle-tested-ness (how widely the
model is deployed, how stable its published numbers are). Tertiary axis
is time-to-data — how quickly we can A/B it against the 6/60 baseline.
Integration effort is **explicitly demoted**: "hard to integrate" is fine
if the quality delta is large.

MTEB numbers below are retrieval-subtask scores where that is what we
could verify on the model card / leaderboard; where only an overall MTEB
average was available that is noted explicitly. All dimension / context
numbers are from the model cards fetched for this round (see §6 for added
sources). Where we could not verify a number first-hand it is marked
"unverified".

### Ranking

1. **Qwen3-Embedding-8B (local, via Ollama or llama.cpp GGUF).**
   **Apache-2.0, 4096 dims (MRL to 32), 32K context.** Currently #1 on the
   MTEB multilingual leaderboard (overall ≈ 70.58 as of mid-2025) and
   consistently strong on the English-v2 variant of MTEB. 8B params /
   ~16 GB bf16 on disk; Q8 GGUF should bring that to ~8 GB. The model is
   **instruction-aware** — queries take an "Instruct: …\nQuery: …" prefix;
   documents do not. This is the biggest-quality ceiling in the open-weights
   space, full stop, and with the back-compat constraint dropped we can
   afford the memory and first-run download. Under §4.5's pool model this
   is only viable if we collapse `EmbedderPool` to a single shared
   instance — verify thread-safety empirically before committing. Run it
   via Ollama (lowest integration friction, HTTP) or llama.cpp GGUF
   (native). **Smaller Qwen3-Embedding-0.6B variant (1024-dim, ~1.2 GB,
   MTEB English-v2 ≈ 70.70) is a surprising and strong fallback** if 8B
   is overkill — it reportedly lands in a similar neighborhood on English
   v2 despite being 13× smaller.

2. **Voyage-3-large (API).** **Currently the best-measured API embedder
   for pure retrieval**, per Voyage's own evaluation across 100 retrieval
   datasets outperforming OpenAI-v3-large by ~9.74% and Cohere-embed-v3
   by ~20.71%. Awesome-agents' March 2026 snapshot puts its MTEB overall
   at ~66.80. 2048 dims (Matryoshka to 1024 / 512 / 256), 32K context,
   int8 / binary quantization support baked in. Pricing: **$0.18 per 1M
   tokens**; first 200M tokens on the v4-series free tier, but v4-large
   is newer and has less third-party evaluation yet. For our corpus size
   (bean-test index ≈ 10K chunks ≈ ~5M tokens) a one-time index cost is
   under $1. The fact that Anthropic formally partners with Voyage is
   also a small moat if we later ask Claude to re-rank. **This is the
   lowest-effort way to actually feel the quality ceiling of modern
   embedders** — one HTTP client, no weights, no pool, no daemon.

3. **Google Gemini Embedding 001 (API).** Currently #1 on the MTEB
   English leaderboard (overall ≈ 68.32, retrieval subtask ≈ 67.71 per
   the March 2026 awesome-agents snapshot). 3072 dims. Hosted API, same
   integration shape as OpenAI. Pricing not pulled in this pass — needs
   verifying before commit. Worth testing alongside or against Voyage to
   see which lands higher on *our* corpus, since MTEB and our 10-query
   rubric are very different evaluations.

4. **OpenAI `text-embedding-3-large` at full 3072 dims.** Same API client
   as the v3-small path the original doc discussed, but without the
   `dimensions=512` truncation. MTEB overall ≈ 64.6, retrieval subtask
   higher than v3-small's but lower than Voyage-3-large per Voyage's own
   comparison. $0.13 / 1M tokens. **Easier procurement than Voyage
   (OpenAI keys are already in most devs' envs) and much cheaper than
   Voyage-3-large.** If quality-per-dollar matters, this is the pragmatic
   choice. Note that third-party evaluations consistently show
   `dimensions=1024` on 3-large performs indistinguishably from 3072 in
   practice for most retrieval tasks — useful if storage becomes a
   concern.

5. **`mxbai-embed-large-v1` at full 1024 dims (local).** Apache-2.0,
   335M params, fp16 ≈ 670 MB. MTEB overall 64.68, retrieval subtask
   54.39. The ceiling is clearly lower than Qwen3-Embedding-8B but the
   integration story is much cleaner: BERT-large architecture, works
   under `swift-embeddings`, llama.cpp GGUF, or Ollama. **Best on-device
   option if we don't want the 8B Qwen memory bill.** The prior doc's
   dismissal of this at 1024 dims was entirely driven by the dropped
   "keep the 512-dim schema" constraint.

6. **`Alibaba-NLP/gte-large-en-v1.5` (local).** Apache-2.0, 409M params,
   **1024 dims**, **8192-token context**, BERT+RoPE+GLU architecture, **no
   required prefix** — a refreshingly simple integration shape. MTEB avg
   65.39, retrieval subtask **57.91** (higher than mxbai's 54.39). This
   is the sleeper pick for a local embedder if we want "as-good-as-mxbai
   on retrieval, no prefix hassle, same dim". Supported by
   `swift-embeddings` (BERT family) and llama.cpp (GGUF available for
   some variants — verify before committing).

7. **`BGE-M3` (local, hybrid).** MIT, 1024-dim dense + sparse (BM25-like)
   + multi-vector (ColBERT-like) all from one model. XLM-RoBERTa-large
   base, 8192 context. The **hybrid dense+sparse mode directly addresses
   the "bean counter" literal-phrase failure** observed in
   `bean-test-results.md` — the sparse head functions like BM25 with
   learned weights, so exact phrases are rewarded. This is the only
   option on this list that *structurally* solves the phrase-evidence
   problem; all the others rely on the dense vector alone. Integration
   effort is higher (need to plumb two retrieval channels and fuse
   scores), but the prior experiment's hybrid-retrieval note (original
   §1 point 4) is absorbed into this single model.

8. **`BAAI/bge-en-icl` (local, in-context learning).** Apache-2.0, 7B
   Mistral-based, MTEB ≈ 71.24 overall. The standout feature is that
   retrieval quality improves measurably when you prepend 2-3 task-style
   query/response examples to the query. For this specific corpus
   (meeting-transcript retrieval) that's an actionable lever — we can
   hand-craft 2-3 synthetic "how would I ask about a meeting like this"
   examples once and bake them in. Same size / memory cost as
   Qwen3-Embedding-8B. Worth a run only after Qwen3-Embedding-8B and
   Voyage-3-large have established a ceiling we'd like to exceed.

9. **`intfloat/multilingual-e5-large-instruct` (local).** MIT, 600M,
   1024 dims, 512-token max context. Instruction-aware like Qwen3 but
   much smaller. Less attractive now that Qwen3-Embedding-0.6B exists at
   the same rough weight class with a higher score and longer context —
   but still a solid fallback if the Qwen3 family has an unforeseen
   integration hiccup.

10. **`nvidia/NV-Embed-v2` — DISQUALIFIED by license.** 8B, 4096 dims, MTEB
    retrieval 62.65 (second-highest verified number in this list after
    Qwen3/Gemini/Voyage). **License is CC-BY-NC-4.0 — non-commercial
    only.** Even for a single-user tool the license is sticky: it
    precludes ever open-sourcing `vec` with NV-Embed-v2 as the default,
    and NVIDIA explicitly redirects commercial use to paid NIMs.
    Not worth building on.

11. **Nomic-embed-text-v1.5 @ 768 dims (local).** Everything the original
    doc said about nomic is still true — it's an honest, well-documented,
    Apache-2.0 model with a real Swift path via `swift-embeddings`. At
    768 dims its MTEB is 62.28, which is now clearly behind every ranked
    option above. **Under the old constraints (512-dim schema, Swift-only
    integration) nomic was the top pick for the *right* reasons;
    under the new constraints it is outranked by every local model above
    it.** See "§5.2 On the nomic-experiment-plan.md" for what this means
    for the currently-proposed experiment.

### Cut-line / ignore

- `NLContextualEmbedding` — still not designed for sentence similarity
  (Apple's own docs say so). Unchanged from §3.9.
- `similarity-search-kit` + `MiniLMAll` — MTEB ~56 is now far below
  every option above. Only useful if we want a reference SPM integration
  we'll later swap.

---

## 5.1 Models worth testing that were dismissed under the old constraints

Each item below was ruled out (or deprioritised) in the original doc by a
constraint that has now been relaxed. Rough delta estimates are against
the old top pick (**nomic-embed-text-v1.5 @ 512 dims, MTEB retrieval
≈ 61.96**). All retrieval-subtask numbers are nDCG@10 on MTEB v1 unless
otherwise noted; some ranking tables quote MTEB *overall* average (a
broader aggregate of retrieval + classification + clustering + STS +
reranking) when that is all the model card published.

| Model | Why dismissed before | What opens up now | Est. quality delta vs nomic @512 |
|---|---|---|---|
| `Qwen3-Embedding-8B` | Not in original doc. 8B / 16 GB is absurd for the 512-dim schema + pool-of-10 constraints. | Single shared instance + server-side (Ollama) integration makes memory manageable. | Large positive. MTEB multilingual ≈ 70.58 vs nomic 62.28 (overall avg). |
| `Qwen3-Embedding-0.6B` | Not in original doc. | Fully on-device viable; smaller than mxbai. | Large positive. MTEB English-v2 ≈ 70.70 per model card — *if that reproduces on our corpus*, this would be the clear local default. Needs verification. |
| `Voyage-3-large` | Original doc had only general voyage-4-series info; dismissed under "prefer on-device". | Paid API is OK. | Large positive. Voyage-3-large beats OpenAI-v3-large by ~9.7% on retrieval (Voyage's own numbers across 100 datasets). |
| Google `Gemini Embedding 001` | Not in original doc. | Paid API is OK. | Likely largest positive for an API option — MTEB English overall ≈ 68.32, retrieval ≈ 67.71 (awesome-agents snapshot). Needs independent verification. |
| OpenAI `text-embedding-3-large` **at full 3072 dims** | Original doc dismissed 3072 implicitly because of the 512-dim schema. | Any dim is OK. | Moderate positive. MTEB avg 64.6 vs nomic 62.28 (overall avg). ~1-2 points is not a landslide, but the integration is the cheapest of any API option. |
| `mxbai-embed-large-v1` **at full 1024** | Original doc demoted it ("5-6× more weights than nomic", "plausible if we're comfortable with 700 MB"). | Size is no longer disqualifying. | Small-to-moderate positive. Retrieval 54.39 is actually *below* nomic's retrieval subtask; its strength is on STS/classification. Worth testing because it's a single HF download, but not the top pick. |
| `Alibaba-NLP/gte-large-en-v1.5` | Not in original doc (GTE family not surveyed). | — | Moderate positive. Retrieval 57.91, no prefix requirement, 8192 context — a *cleaner* integration than mxbai at similar-or-higher retrieval. |
| `intfloat/multilingual-e5-large-instruct` | Not in original doc (only `e5-small-v2` was, in §3.7). | — | Small positive. Comparable to mxbai in weight class; upside is the instruction-aware query format, downside is 512-token max. |
| `nvidia/NV-Embed-v2` | Not in original doc. | Large model OK. | **DISQUALIFIED.** CC-BY-NC-4.0. Even single-user, the license is sticky and precludes ever open-sourcing the tool. Reason it got famous — retrieval 62.65 — is moot. |
| `BAAI/bge-m3` | Not in original doc. | Any size / any runtime OK. | Architecturally interesting: the only candidate that *structurally* solves the phrase-evidence problem that sank our current cosine-only approach on the bean-test. Dense retrieval 63.00 (overall) is merely ok — the value is the hybrid. |
| `BAAI/bge-en-icl` | Not in original doc. | Any size OK; in-context examples are a new knob. | Large positive on overall MTEB (~71.24) if ICL examples land well for our query shape. |
| Ollama backend (any local model above) | Old doc: daemon install "harsh onboarding story". | Daemon OK. | Neutral — this is how we *run* models above, not a different model. Integration shape is the thinnest: single HTTP call, all pool/memory concerns go to the server. |
| Python subprocess for any sentence-transformers model | Not in original doc. | Language-runtime swap OK. | Neutral mechanism — same caveat as Ollama. Gives us the entire sentence-transformers / MTEB universe, including models we haven't scouted, at the cost of a Python install. |

### Unverified claims flagged for follow-up

- Gemini Embedding 001 pricing and any per-million-tokens tier. The
  model-card page for it was not fetched in this pass — need to confirm
  before committing to an API experiment.
- OpenAI `text-embedding-3-large` retrieval-subtask score *specifically*
  (not overall avg). The 64.6 figure is overall MTEB; the commonly-quoted
  retrieval subtask ≈ 55.44 from third-party blog posts could not be
  sourced from OpenAI directly in this pass — check HF card / MTEB
  leaderboard before putting it in a decision deck.
- Qwen3-Embedding-0.6B's reported MTEB English-v2 ≈ 70.70 vs the 8B
  variant's 70.58 is surprising — needs sanity-checking against the HF
  card because the "v2" English MTEB is a newer, re-scored leaderboard
  and the aggregation differs from the original MTEB.

---

## 5.2 On the `nomic-experiment-plan.md` first experiment

### Quick verdict: run it anyway, but **time-box it tightly and have a follow-up queued.**

The `nomic-experiment-plan.md` on the parent branch proposes to A/B swap
`NLEmbedding` for `nomic-embed-text-v1.5 @ 768 dims` via
`swift-embeddings`, reusing the 10-query bean-test rubric, with three
gates: ship (≥30/60), interesting (15–29/60), kill (<15/60).

Arguments **for** running it as written:

- **Time-to-data is the fastest of any option here.** `swift-embeddings`
  is a pure-SPM drop-in. The whole swap — plus the `vec reset` +
  reindex + 10-query score — is a single afternoon of work. Voyage-3-
  large and Qwen3 would each take longer to wire up even though the code
  surface is smaller, because we'd be introducing an HTTP client
  (Voyage) or a server dependency (Ollama for Qwen3) from scratch.
- **It's a load-bearing calibration.** We currently don't know whether
  the 6/60 ceiling is NLEmbedding specifically or whether the corpus /
  chunking / queries also share blame. Nomic at 768 sits in the
  same-architecture-family as every local option above it in the ranking,
  so its score is a cheap prior for the whole class. If nomic lands in
  the ship gate (≥30/60), any stronger model will too. If nomic lands in
  the kill gate (<15/60), that's evidence the corpus / chunking / queries
  are a bigger problem than the embedder — and we should stop scouting
  new models until that's understood.
- The plan file already correctly drops the back-compat scaffolding
  (protocol, dual-embedder flag, DB metadata check), matching the new
  constraints.

Arguments **against** running it as written without adjustments:

- Nomic is no longer the top-ranked candidate even among local models.
  If it hits the "interesting" gate (15–29/60), the plan's fallback
  ("tune chunk config, try 512 dim") is now weaker than "try the next
  embedder up the ranking". The plan's decision tree should route
  directly to Qwen3-Embedding-8B (via Ollama) or Voyage-3-large rather
  than to Matryoshka-truncating nomic.
- The plan locks in `swift-embeddings` as the integration substrate.
  That's fine for nomic *this experiment*, but if the next experiment is
  Qwen3-8B or an API embedder, `swift-embeddings` isn't the host. Write
  the experiment's integration code behind a thin embedder-protocol-of-
  convenience *inside `EmbeddingService`*, not sprayed across three
  call-sites, so experiment #2 can reuse the plumbing.

### Concrete recommendation

Keep `nomic-experiment-plan.md` as experiment #1. Do not revise its
success gates. **Do revise the "what's next if we hit the interesting
gate" decision tree** to jump to Qwen3-Embedding-8B (via Ollama HTTP)
and Voyage-3-large (API) rather than to chunk-config tuning or
Matryoshka truncation. Sketch for experiment #2 (whichever is the first
to fire after nomic):

1. **If nomic hits ship gate (≥30/60):** stop the research axis; we have
   the answer. Ship nomic, plan the distribution UX (bundled vs HF
   download on first run). Optionally run Voyage-3-large later as a
   ceiling check — if Voyage beats nomic by > 10 points, revisit.
2. **If nomic hits interesting gate (15–29/60):** next experiment is
   **Qwen3-Embedding-8B via Ollama**, not chunk retuning. Plan:
   - Pre-flight: `ollama pull qwen3-embedding:8b` (confirm model tag and
     disk footprint — should be ~8 GB Q8).
   - Replace the `swift-embeddings` Nomic call in `EmbeddingService`
     with an HTTP call to `POST http://localhost:11434/api/embed` with
     `model: "qwen3-embedding"` and the documents / queries wrapped in
     the "Instruct: …\nQuery: …" format for queries only.
   - Collapse `EmbedderPool` to a single instance (Ollama serialises
     requests for us on the server side).
   - Wipe DB, reindex (dimension will be 4096 unless we MRL-truncate;
     store at 4096 for experiment #2 to see the ceiling), rescore 10
     queries. Same rubric as bean-test.
   - Gates: ship ≥40/60 (higher bar — we spent more setup). Otherwise
     move to experiment #3.
3. **If nomic hits kill gate (<15/60):** don't chase more embedders
   immediately. Instead run a *diagnostic* sanity check: take the two
   target files and hand-embed them with OpenAI `text-embedding-3-large`
   via the API, and their top competing files, and compute cosine
   similarity directly against the 10 queries. That's a cheap sanity
   check that tells us whether *any* modern embedder would beat NLEmbedding
   on this specific corpus or whether the corpus+query set is structurally
   hard. Only after that diagnostic should we run experiment #2.

The nomic experiment is still the right first experiment. Just queue up
experiment #2's plan *now*, not after nomic returns its score.

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

### Added 2026-04-17 (for §5 / §5.1 re-evaluation)

- MTEB leaderboard (live): <https://huggingface.co/spaces/mteb/leaderboard>.
- MTEB repo: <https://github.com/embeddings-benchmark/mteb>.
- March 2026 awesome-agents MTEB snapshot: <https://awesomeagents.ai/leaderboards/embedding-model-leaderboard-mteb-march-2026/>.
- Qwen3 Embedding family (8B / 4B / 0.6B): <https://huggingface.co/Qwen/Qwen3-Embedding-8B>, <https://huggingface.co/Qwen/Qwen3-Embedding-4B>, <https://huggingface.co/Qwen/Qwen3-Embedding-0.6B>, <https://github.com/QwenLM/Qwen3-Embedding>.
- Voyage-3-large launch post: <https://blog.voyageai.com/2025/01/07/voyage-3-large/>.
- Voyage pricing: <https://docs.voyageai.com/docs/pricing>.
- GTE-large-en-v1.5: <https://huggingface.co/Alibaba-NLP/gte-large-en-v1.5>.
- GTE-Qwen2-7B-instruct: <https://huggingface.co/Alibaba-NLP/gte-Qwen2-7B-instruct>.
- Multilingual-E5-large-instruct: <https://huggingface.co/intfloat/multilingual-e5-large-instruct>.
- NV-Embed-v2 (disqualified by license): <https://huggingface.co/nvidia/NV-Embed-v2>, paper <https://arxiv.org/abs/2405.17428>.
- BGE-M3: <https://huggingface.co/BAAI/bge-m3>.
- BGE-en-ICL: <https://huggingface.co/BAAI/bge-en-icl>, paper <https://arxiv.org/abs/2409.15700>.
