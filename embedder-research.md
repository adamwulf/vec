# On-Device Embedder Survey (Phase A)

Survey of candidate embedders to add to the `vec` macOS CLI. Baseline to beat:
`nomic-v1.5-768` (Nomic Embed v1.5, GGUF via llama.cpp, ~280 MB, MTEB
retrieval ~52.8). The other currently shipping embedder, `nl-en-512` (Apple
NLEmbedding), is included below for completeness but is not a candidate — it
is the one we are trying to replace.

---

## Candidates

### 1. Apple NLContextualEmbedding

- **Source:** Apple (Natural Language framework).
- **Canonical dimension:** 512 (per Callstack blog; Apple docs expose
  `dimension` as a runtime property rather than a fixed number, since three
  underlying models ship based on script: Latin / Cyrillic / CJK).
- **Integration cost:** Apple framework (built into macOS 14+).
- **Install / download size:** Zero in the app bundle; assets are downloaded
  on-demand by the OS via
  `requestAssets(completionHandler:)`. Asset size is not published by Apple,
  but the models are shared across the OS so there is no per-app cost.
- **License:** Apple platform framework — free to use on Apple devices.
- **Retrieval quality signal:** No published MTEB/BEIR number. Apple publishes
  no retrieval leaderboard results. WWDC23 Session 10042 ("Explore Natural
  Language multilingual models") markets it as a replacement for
  NLEmbedding-style workflows, but gives no retrieval benchmarks.
- **Known gotchas:**
  - macOS 14+ / iOS 17+ only.
  - Max sequence length is 256 *tokens* per call (smaller than most
    transformer embedders' 512) — long documents must be chunked.
  - Output is a *sequence* of per-token vectors, not a pooled sentence
    vector: call sites must pool (mean/CLS) to get a single vector per chunk.
  - Separate model per script — you must pick the right one per language.
  - Assets must be explicitly requested and may fail to download; also check
    `hasAvailableAssets` before `load()`.
- **Sources:**
  - Apple docs: <https://developer.apple.com/documentation/naturallanguage/nlcontextualembedding>
  - Callstack (third-party summary of dims/tokens):
    <https://www.callstack.com/blog/on-device-ai-introducing-apple-embeddings-in-react-native>
  - WWDC23 Session 10042: <https://developer.apple.com/videos/play/wwdc2023/10042/>

---

### 2. all-MiniLM-L6-v2

- **Source:** `sentence-transformers/all-MiniLM-L6-v2` (Microsoft MiniLM base
  + sentence-transformers fine-tune).
- **Canonical dimension:** 384.
- **Integration cost:** CoreML (community-converted `.mlpackage` exists at
  e.g. Apple-published SwiftUI demos; also available as GGUF and ONNX).
- **Install / download size:** 22.7M params (~90 MB fp32, ~45 MB fp16,
  ~23 MB int8).
- **License:** Apache 2.0.
- **Retrieval quality signal:** Mid-tier. MTEB overall ~56.3; MTEB retrieval
  subset ~41.9 (well below baseline). Widely used as a "cheap and cheerful"
  baseline; the published card only lists one retrieval task (ArguAna 50.17).
- **Known gotchas:**
  - Max sequence **256 word-pieces** (trained at 128) — worst seq length of
    anything in this survey; bad fit for long transcripts.
  - No query/doc prefix needed.
  - Quality is below our nomic-v1.5 baseline, so this is a reference point,
    not a ranking candidate.
- **Sources:**
  - <https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2>
  - CoreML conversion example discussed in Apple Developer CoreML topic feed
    and HuggingFace community conversions (search: "all-MiniLM-L6-v2 coreml").

---

### 3. BGE family (bge-small / bge-base / bge-large-en-v1.5)

- **Source:** BAAI (Beijing Academy of AI), `BAAI/bge-*-en-v1.5`.
- **Canonical dimensions:** 384 (small) / 768 (base) / 1024 (large).
- **Integration cost:** Primarily available as PyTorch/safetensors and
  GGUF; CoreML conversions exist in the community (e.g.
  `michaeljelly/bge-small-en-coreml-v1.5`) but are not first-party. GGUF
  via llama.cpp is the most reliable route today.
- **Install / download size:**
  - bge-small-en-v1.5: 33.4M params, ~33 MB fp16.
  - bge-base-en-v1.5: 109M params, ~219 MB fp16.
  - bge-large-en-v1.5: 335M params, ~670 MB fp16.
- **License:** MIT — commercial-OK.
- **Retrieval quality signal (MTEB retrieval, 15-task average):**
  - bge-small-en-v1.5: **51.68**
  - bge-base-en-v1.5: **53.25**
  - bge-large-en-v1.5: **54.29**
  All three beat or approximately match the nomic-v1.5-768 baseline
  (~52.8); `-base` and `-large` clear it comfortably.
- **Known gotchas:**
  - Max sequence length 512.
  - Query instruction `"Represent this sentence for searching relevant passages:"`
    is **optional in v1.5** (model is trained to work without it). Documents
    get no prefix.
  - BERT WordPiece tokenizer (bert-base-uncased vocab).
- **Sources:**
  - <https://huggingface.co/BAAI/bge-small-en-v1.5>
  - <https://huggingface.co/BAAI/bge-base-en-v1.5>
  - <https://huggingface.co/BAAI/bge-large-en-v1.5>

---

### 4. GTE family (gte-small / gte-base / gte-large)

- **Source:** Alibaba DAMO Academy, `thenlper/gte-*`.
- **Canonical dimensions:** 384 / 768 / 1024.
- **Integration cost:** PyTorch/safetensors primary; GGUF community
  conversions available; no widely-known first-party CoreML.
- **Install / download size:**
  - gte-small: 33.4M params, ~70 MB.
  - gte-base: 109M params, ~220 MB.
  - gte-large: 335M params, ~670 MB.
- **License:** MIT.
- **Retrieval quality signal (MTEB retrieval):**
  - gte-small: **49.46**
  - gte-base: **51.14**
  - gte-large: **52.22**
  None beat the nomic-v1.5 baseline (~52.8) by a clear margin; `-large` is
  essentially a wash.
- **Known gotchas:**
  - Max sequence 512.
  - **No prefixes required** — direct-encode both queries and documents.
    That's a nicer DX than BGE/E5 for general-purpose similarity search.
  - BERT tokenizer.
- **Sources:**
  - <https://huggingface.co/thenlper/gte-small>
  - <https://huggingface.co/thenlper/gte-base>
  - <https://huggingface.co/thenlper/gte-large>

---

### 5. E5 family (e5-small-v2 / e5-base-v2 / e5-large-v2)

- **Source:** Microsoft (intfloat), `intfloat/e5-*-v2`.
- **Canonical dimensions:** 384 / 768 / 1024.
- **Integration cost:** PyTorch/safetensors primary; GGUF and ONNX
  conversions exist.
- **Install / download size:**
  - e5-small-v2: ~33M params, ~130 MB fp32 / ~66 MB fp16.
  - e5-base-v2: 109M params, ~438 MB fp32 / ~219 MB fp16.
  - e5-large-v2: 335M params, ~1.3 GB fp32 / ~670 MB fp16.
- **License:** MIT.
- **Retrieval quality signal:** Model cards don't print a single summary
  retrieval number, but the MTEB leaderboard lists roughly:
  e5-small-v2 ≈ 49.0 retrieval, e5-base-v2 ≈ 50.3, e5-large-v2 ≈ 50.6
  (BEIR subset). All trail nomic-v1.5 and BGE.
- **Known gotchas:**
  - **Prefixes are MANDATORY**: `"query: "` and `"passage: "`. Omitting them
    causes measurable quality drop (cited by the authors). This adds
    branching cost to the indexing pipeline if you don't have a
    queries-vs-docs distinction baked in.
  - Max sequence 512.
  - Cosine-similarity scores cluster in 0.7-1.0 (low training temperature) —
    cosine threshold intuition from other models won't transfer.
- **Sources:**
  - <https://huggingface.co/intfloat/e5-small-v2>
  - <https://huggingface.co/intfloat/e5-base-v2>
  - <https://huggingface.co/intfloat/e5-large-v2>

---

### 6. nomic-embed-text-v2-moe

- **Source:** Nomic AI, `nomic-ai/nomic-embed-text-v2-moe`.
- **Canonical dimension:** 768 (Matryoshka to 512 / 384 / 256).
- **Integration cost:** GGUF via llama.cpp (Nomic publishes an official
  `nomic-embed-text-v2-moe-GGUF` repo). PyTorch path requires
  `trust_remote_code=True` plus the `megablocks` library — not viable on
  device.
- **Install / download size:** 475M total / 305M active params. HF weights
  1.9 GB fp32; GGUF Q4_K_M ~300–400 MB range expected.
- **License:** Apache 2.0.
- **Retrieval quality signal:** BEIR 52.86, MIRACL 65.80 (best-in-class
  multilingual). BEIR 52.86 is essentially *tied* with our existing
  `nomic-v1.5-768` baseline for English retrieval — multilingual is where
  v2 pulls away.
- **Known gotchas:**
  - Prefixes **mandatory**: `search_query:` and `search_document:`.
  - Max sequence 512.
  - MoE architecture: llama.cpp support for MoE embedders is newer and
    worth verifying before integration (the GGUF repo exists, but routing
    support has had rough edges historically).
  - No win over v1.5 for English-only corpora — only worth adding if
    multilingual is a target goal.
- **Sources:**
  - <https://huggingface.co/nomic-ai/nomic-embed-text-v2-moe>
  - <https://huggingface.co/nomic-ai/nomic-embed-text-v2-moe-GGUF>
  - <https://static.nomic.ai/nomic_embed_multilingual_preprint.pdf>

---

### 7. mxbai-embed-large-v1

- **Source:** Mixedbread, `mixedbread-ai/mxbai-embed-large-v1`.
- **Canonical dimension:** 1024 (Matryoshka — docs show truncation to 512
  and below).
- **Integration cost:** PyTorch/safetensors primary; GGUF community
  conversions exist (via llama.cpp); no first-party CoreML.
- **Install / download size:** 335M params, ~670 MB fp16.
- **License:** Apache 2.0.
- **Retrieval quality signal:** **MTEB retrieval 54.39**, MTEB overall
  64.68. Clearly above the nomic-v1.5 baseline, competitive with BGE-large.
  Marketed as beating text-embedding-3-large on overall MTEB.
- **Known gotchas:**
  - Query prefix required: `"Represent this sentence for searching relevant passages: "`
    (same convention as BGE). Documents get no prefix.
  - Max sequence length not explicitly stated on the card; the underlying
    BERT-large architecture implies 512.
  - Matryoshka truncation + binary quantization play well together — useful
    story for storage.
- **Sources:**
  - <https://huggingface.co/mixedbread-ai/mxbai-embed-large-v1>
  - <https://www.mixedbread.com/blog/mxbai-embed-large-v1>

---

### 8. snowflake-arctic-embed-m-v1.5

- **Source:** Snowflake, `Snowflake/snowflake-arctic-embed-m-v1.5`.
- **Canonical dimension:** 768 (Matryoshka to 256; 128-byte int4 also
  documented).
- **Integration cost:** PyTorch/safetensors primary; **official GGUF sizes
  published on the model card** (F32 436 MB, F16/BF16 219 MB, Q8_0 118 MB,
  TQ2_0 71.5 MB, TQ1_0 67.5 MB) — indicates the Snowflake team has
  validated the llama.cpp path. CoreML conversions are community-only.
- **Install / download size:** 109M params. Smallest usable quantization
  ~68 MB, fp16 ~219 MB — fits well in our <10 GB budget.
- **License:** Apache 2.0.
- **Retrieval quality signal:** **MTEB retrieval NDCG@10 = 55.14**. At 256
  dims int8 still scores 54.2; at 128-byte int4 still 53.7 — all of which
  beat the nomic-v1.5 baseline (~52.8).
- **Known gotchas:**
  - Query prefix required: `"Represent this sentence for searching relevant passages: "`
    (same phrasing as BGE/mxbai — convenient, we can share code).
    Documents get no prefix.
  - Max sequence 512.
  - Quantization ranges published: -0.18 to +0.18 for int4, -0.3 to +0.3
    for int8. Corpus-independent scalar quantization — no calibration
    dataset needed.
  - Family also includes `-s` (33M, 384-dim, retrieval 51.98 — slightly
    below baseline) and `-l` (335M, 1024-dim, retrieval higher but bigger).
- **Sources:**
  - <https://huggingface.co/Snowflake/snowflake-arctic-embed-m-v1.5>
  - <https://huggingface.co/Snowflake/snowflake-arctic-embed-s>
  - <https://www.snowflake.com/en/engineering-blog/arctic-embed-m-v1-5-enterprise-retrieval/>

---

## Reference: existing embedders

For context; these are not ranked below.

- **`nomic-v1.5-768`** — Nomic Embed Text v1.5, 768-dim, GGUF via llama.cpp,
  ~280 MB. MTEB retrieval ~52.8 (BEIR subset; MTEB overall 62.28). Current
  default. Matryoshka to 512/256/128/64. License: Apache 2.0. Requires
  `search_query:` / `search_document:` prefixes.
  <https://huggingface.co/nomic-ai/nomic-embed-text-v1.5>
- **`nl-en-512`** — Apple NLEmbedding (static word embeddings, English),
  512-dim. Apple framework, zero install. Pre-transformer-era quality;
  known poor performance on long transcripts (0/60 observed).

---

## Ranked shortlist

Three "easy wins" that (a) clear the nomic-v1.5 baseline on MTEB retrieval
and (b) have a low-friction integration path.

### 1. snowflake-arctic-embed-m-v1.5 — GGUF, 768-dim **(top pick)**

**Why:** Best quality-per-MB of anything in the survey. MTEB retrieval
55.14 at full precision beats the baseline by ~2.3 points, and it
*still* beats it (53.7) at the most aggressive 128-byte int4 Matryoshka
compression. 109M params — half the size of nomic-v1.5 — with higher
retrieval quality. Apache 2.0. Snowflake publishes their own GGUF sizes on
the card, implying they validate the llama.cpp path themselves. Share
pooled embedding code with future BGE/mxbai adds since they all use the
same query prefix.

**Install path:** Download fp16 GGUF (~219 MB) or Q8_0 (~118 MB) on first
use into the same `~/.vec/models/` directory used by `nomic-v1.5-768`.
Reuse the existing llama.cpp Swift binding. The query prefix
`"Represent this sentence for searching relevant passages: "` must be
prepended at search time; indexed documents get no prefix.

**Expected effort:** ~4–6 hours to wire as a new
`IndexingProfileFactory.builtIn` row. The hard parts (llama.cpp binding,
model-download UX, pooling) are already solved by the nomic-v1.5 path; the
new code is a profile entry + prefix handling + a download URL. An extra
hour each if we want to expose the Matryoshka-truncated `-256d` variant and
the int8/int4 quantization choices as separate profile rows.

### 2. bge-base-en-v1.5 — GGUF, 768-dim

**Why:** MTEB retrieval 53.25 — clears the baseline by ~0.5, which is
modest, *but* the v1.5 "no query prefix required" property means the
indexing/query pipeline is identical on both sides. That's a code-path
simplification relative to anything else in the shortlist. MIT license.
109M params / ~219 MB fp16. Well-trodden in the llama.cpp ecosystem.

**Install path:** Download GGUF (~220 MB) on first use into
`~/.vec/models/`. Reuse the llama.cpp binding. No prefix branching needed
at query time — this is the main architectural win over arctic/mxbai.

**Expected effort:** ~3–4 hours for a new `IndexingProfileFactory.builtIn`
row. Less than arctic because there's no prefix handling to add. Good
candidate to land *first* as the simplest validation that the profile
system can host a second llama.cpp embedder.

### 3. Apple NLContextualEmbedding — Apple framework, 512-dim

**Why:** Zero install cost. macOS 14+ is a reasonable baseline for a new
CLI feature. It is also the only candidate that is *guaranteed* to work
with no download, which makes it valuable as a fallback when the user has
no network or as the "first-run works immediately" default.

**Caveat on quality:** no published MTEB score, so this is a speculative
win — we do not yet know if it clears the `nomic-v1.5-768` bar. Apple
marketing language suggests it is a large step up from the static
`NLEmbedding` we're already shipping (`nl-en-512`), which was 0/60 on the
real transcript corpus. A concrete A/B against the nomic baseline on our
eval corpus is a prerequisite before making this a default.

**Install path:** No file download from our side — call
`requestAssets(completionHandler:)` on first use, wait for OS asset
download, then call `load()` before first embed. Pool the per-token
vector sequence ourselves (mean-pool is the safe default). Handle the
256-token per-call limit by splitting long chunks.

**Expected effort:** ~6–10 hours. More than the GGUF rows because (a)
we need a new loader path (not llama.cpp) and (b) we need to add pooling
and chunking for the 256-token window. Plus ~2–4 hours to run a quality
eval against `nomic-v1.5-768` on the existing transcript corpus before
adopting it. If it doesn't beat the baseline there, de-prioritize in
favor of the first two picks.

---

## Rejected / not shortlisted

- **GTE family**: gte-large (52.22) is essentially a wash with the baseline
  and gte-small/base are below it. Nothing to gain over BGE at the same
  sizes.
- **E5 v2 family**: mid-50s on MTEB overall but retrieval subset hovers
  around 49–51, below the baseline. Also the mandatory `query:`/`passage:`
  prefixes add pipeline complexity for no quality win vs. BGE.
- **all-MiniLM-L6-v2**: below baseline and 256-word-piece max sequence is
  bad for long transcripts. Keep as a reference point only.
- **nomic-embed-text-v2-moe**: tied with our existing v1.5 on English
  retrieval, so not an English win. Revisit if/when multilingual becomes a
  goal — at that point it becomes the obvious pick because of Apache 2.0 +
  official GGUF + MIRACL 65.80.
- **mxbai-embed-large-v1 / bge-large-en-v1.5**: both clearly beat the
  baseline (54.39 and 54.29) and are credible candidates — kept off the
  top-3 only because they're ~3× the weights of arctic-m-v1.5 at a similar
  quality level. Worth revisiting once a "bigger/slower, higher-quality"
  profile row is in demand.
