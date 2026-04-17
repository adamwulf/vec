# Optimal Chunk Sizes for Splitting English Prose for a Vector Database

**Scope:** English-language notes and long-form articles (not code, not multilingual) being embedded into a vector database for retrieval.

---

## Top-line recommendation

**Default: Split on recursive / sentence-aware boundaries at ~512 tokens (≈ 380 words, ≈ 2,000 characters) with 10–15% overlap (~50–75 tokens).**

Two flavors, depending on source-document type:

| Source type | Target chunk size | Overlap | Splitter |
|---|---|---|---|
| **Short notes** (personal notes, Zettelkasten-style, snippets, meeting notes) | **~256 tokens** (~190 words, ~1,000 chars) | ~25–50 tokens (~10–20%) | Recursive on `\n\n` → `\n` → sentence → word; keep the whole note as one chunk when it is already shorter than the target |
| **Long-form articles** (essays, blog posts, docs, book chapters) | **~512 tokens** (~380 words, ~2,000 chars) | ~50–75 tokens (~10–15%) | Recursive character / sentence splitter, respecting paragraph and heading boundaries |

Start with `RecursiveCharacterTextSplitter`-style splitting (or an equivalent sentence-aware splitter). Do **not** start with semantic chunking — the evidence is mixed and it costs an embedding call per sentence for a marginal (and sometimes negative) gain. Revisit only if retrieval evaluation on your own corpus demands it.

Rationale and evidence follows.

---

## 1. Industry-standard defaults across major frameworks

| Framework / Component | Default chunk size | Default overlap | Unit |
|---|---|---|---|
| **LangChain** `RecursiveCharacterTextSplitter` / `CharacterTextSplitter` | **4,000** | **200** | characters (~1,000 tokens, 5% overlap) |
| **LlamaIndex** `SentenceSplitter.from_defaults()` | **1,024** | **20** | tokens (~2% overlap) |
| **Haystack 2.x** `DocumentSplitter` | **200** | **0** | words (~260 tokens, no overlap) |
| **Unstructured.io** (practical guidance) | ~250 tokens (~1,000 chars) | "tunable" | tokens |
| **Pinecone** (practical guidance) | explore 128–1,024 | not prescribed | tokens |

Sources:
- LangChain default 4,000 chars / 200 overlap: [LangChain docs — splitting recursively](https://docs.langchain.com/oss/python/integrations/splitters/recursive_text_splitter), [Understanding LangChain's RecursiveCharacterTextSplitter](https://dev.to/eteimz/understanding-langchains-recursivecharactertextsplitter-2846)
- LlamaIndex `SentenceSplitter` 1,024 tokens / 20 overlap: [LlamaIndex — Sentence splitter reference](https://docs.llamaindex.ai/en/stable/api_reference/node_parsers/sentence_splitter/), [Basic Strategies](https://developers.llamaindex.ai/python/framework/optimizing/basic_strategies/basic_strategies/)
- Haystack 2.x `DocumentSplitter` defaults (`split_by="word"`, `split_length=200`, `split_overlap=0`): [Haystack source — document_splitter.py](https://github.com/deepset-ai/haystack/blob/main/haystack/components/preprocessors/document_splitter.py), [Haystack DocumentSplitter docs](https://docs.haystack.deepset.ai/docs/documentsplitter)
- Unstructured.io "250 tokens ≈ 1,000 characters" starting point: [Unstructured — Chunking for RAG best practices](https://unstructured.io/blog/chunking-for-rag-best-practices)
- Pinecone's 128 / 256 / 512 / 1,024 exploration range: [Pinecone — Chunking strategies](https://www.pinecone.io/learn/chunking-strategies/)

**Why the defaults disagree.** LangChain's 4,000-character default was chosen as a conservative fit for early GPT-3.5 context windows and is generally considered too large for modern retrieval quality; LlamaIndex's 1,024 tokens is tuned for longer-form document QA; Haystack's 200 words (~260 tokens) is close to what recent benchmarks actually recommend; Unstructured's 250 tokens is explicitly framed as a starting point based on internal evaluation. The practical consensus across recent benchmarks (below) is that **~256–512 tokens outperforms 1,024+ for most English prose retrieval tasks.**

---

## 2. Empirical benchmarks by chunk size

### Chroma Research — "Evaluating Chunking Strategies for Retrieval"

Chroma's evaluation measured precision/recall/IoU on retrieved tokens across multiple corpora.

- `RecursiveCharacterTextSplitter` at **400 tokens with no overlap** was the best-performing heuristic baseline, hitting **88.1–89.5% recall** — effectively tying much more expensive methods.
- `RecursiveCharacterTextSplitter` outperformed a pure `TokenTextSplitter` at all sizes ≤ 400 tokens.
- `LLMSemanticChunker` reached the highest recall (0.919) but only by a small margin over the 400-token recursive baseline, at dramatically higher cost.
- `ClusterSemanticChunker` with a 400-token max achieved 0.913 recall.

Source: [Chroma Research — Evaluating Chunking Strategies for Retrieval](https://research.trychroma.com/evaluating-chunking); replication toolkit: [brandonstarxel/chunking_evaluation on GitHub](https://github.com/brandonstarxel/chunking_evaluation).

### NVIDIA — "Finding the Best Chunking Strategy for Accurate AI Responses"

NVIDIA tested 128, 256, 512, 1,024, and 2,048-token fixed chunks plus page- and section-level splits across five datasets (DigitalCorpora767, Earnings, FinanceBench, KG-RAG, RAGBattlePacket). Overlap values tested were 10%, 15%, and 20%.

Key numbers:
- **Token-based chunking accuracy stayed in a narrow band of 0.603–0.645 regardless of size** — the difference between best and worst size choices was only a few points.
- Dataset-specific optima: FinanceBench peaked at 1,024 tokens (0.579); Earnings peaked at 512 tokens (0.681); RAGBattlePacket peaked at 1,024 tokens (0.804).
- **Overlap of 15% performed best** on FinanceBench with 1,024-token chunks.
- Explicit recommendation: **factoid queries → 256–512 tokens; analytical / synthesis queries → 1,024 tokens or page-level chunks**.

Source: [NVIDIA Technical Blog — Finding the Best Chunking Strategy](https://developer.nvidia.com/blog/finding-the-best-chunking-strategy-for-accurate-ai-responses/).

### "Rethinking Chunk Size for Long-Document Retrieval" (arXiv 2505.21700)

Tested 64, 128, 256, 512, 1,024 tokens on six QA datasets (NarrativeQA, NQ, NewsQA, COVID-QA, TechQA, SQuAD) with two embedding models (Stella, Snowflake).

- On **SQuAD** (short factoid answers), **64-token chunks gave the best recall@1 at 64.1%**, monotonically declining as chunks grew.
- On **NarrativeQA** (dispersed answers requiring broader context), recall@1 rose from **4.2% at 64 tokens → 10.7% at 1,024 tokens** — larger is better for synthesis-heavy tasks.
- Stella (decoder-based) benefited from larger chunks; Snowflake (encoder-based) preferred smaller.

Source: [Rethinking Chunk Size for Long-Document Retrieval (arXiv 2505.21700v2)](https://arxiv.org/html/2505.21700v2).

### Cross-benchmark takeaway

**For generic English prose retrieval with short-to-moderate queries, 256–512 tokens is the sweet spot.** Going smaller (64–128) only helps when your queries are entity-lookup / fact-extraction queries. Going larger (1,024+) only helps when queries require multi-sentence synthesis and answers are dispersed across a document.

Additional summaries of these findings: [PremAI — RAG Chunking Strategies 2026 Benchmark Guide](https://blog.premai.io/rag-chunking-strategies-the-2026-benchmark-guide/), [Firecrawl — Best Chunking Strategies for RAG](https://www.firecrawl.dev/blog/best-chunking-strategies-rag).

---

## 3. Chunk size vs. embedding model context window and query length

### Embedding-model ceilings

- Legacy encoder-based embedders (BGE, E5, GTE) have a hard ceiling of **512 tokens**. Input longer than that is silently truncated.
- Modern long-context embedders: Nomic Embed (8,192), BGE-M3 (8,192), OpenAI `text-embedding-3-*` (8,191). These *accept* long input but quality does not scale linearly with length.
- Even with an 8K context window, **stuffing more than a paragraph or two into one vector blurs distinct topics into a single averaged meaning** and reduces retrieval precision.

Sources: [Nomic Embed paper (arXiv 2402.01613)](https://arxiv.org/html/2402.01613v2), [Unstructured — Chunking best practices](https://unstructured.io/blog/chunking-for-rag-best-practices).

### Query-length asymmetry

User queries in typical RAG are **very short** — commonly 5–20 tokens (a sentence or less). This creates an **asymmetric retrieval problem**: a short query vector must match against chunk vectors. If chunks are too long, a single narrow query topic gets diluted by the rest of the chunk's content, pulling its vector away from the query's vector. If chunks are too short, the matching chunk may not contain the full answer by itself.

A chunk in the 256–512-token range is short enough to represent a single coherent idea and long enough to contain a self-contained answer fragment.

Source: [Weaviate — Vector Search Explained](https://weaviate.io/blog/vector-search-explained).

### Multi-scale indexing (advanced)

If you have the storage budget, AI21 showed that indexing the same corpus at multiple chunk sizes (e.g., 100 / 200 / 500 tokens) and fusing with Reciprocal Rank Fusion improved retrieval **1–37%** across benchmarks without any model changes. This is a solid "phase-2" upgrade but overkill for a first cut.

Source: [AI21 — Chunk size is query-dependent](https://www.ai21.com/blog/query-dependent-chunking/).

---

## 4. Overlap

**Recommendation: 10–15% of chunk size.**

- NVIDIA directly tested 10%, 15%, and 20% overlap and found **15% best** on FinanceBench at 1,024-token chunks. ([NVIDIA](https://developer.nvidia.com/blog/finding-the-best-chunking-strategy-for-accurate-ai-responses/))
- Broad practitioner consensus is **10–20% overlap** as a starting range. ([Unstract docs](https://docs.unstract.com/unstract/unstract_platform/user_guides/chunking/), [F22 Labs](https://www.f22labs.com/blogs/7-chunking-strategies-in-rag-you-need-to-know/))
- LangChain's default is only 5% (200 / 4,000 chars) — on the low end of what evaluations actually recommend.
- Chroma's best recursive result (400 tokens) used **zero overlap**, which suggests that with well-chosen sentence/paragraph boundaries, overlap buys less than commonly assumed.

**Concrete guidance:**
- For 256-token chunks → 25–50 token overlap.
- For 512-token chunks → 50–75 token overlap.
- Do not exceed ~25% overlap: it bloats the index (every overlapping chunk is a duplicate vector) and hurts result diversity without much recall gain.

Overlap's real job is to prevent an answer from being split across a chunk boundary. A recursive splitter that respects paragraph and sentence boundaries already mitigates this, so overlap becomes a cheap belt-and-suspenders measure rather than the primary defense.

---

## 5. Semantic / recursive / sentence-based vs. fixed-size

### Fixed-size (character or token count, no structure awareness)

**When to use:** never, as a first choice for prose. It breaks mid-sentence, mid-word, and destroys semantic coherence at boundaries. Only acceptable for highly uniform text (e.g., logs) where structure doesn't matter.

### Recursive character / sentence-aware splitting

**When to use: this is the default.** Splits on a priority list of separators (`\n\n` → `\n` → `. ` → ` ` → `""`), keeping chunks at or below a target size while respecting paragraph and sentence boundaries. Chroma's evaluation and the NVIDIA benchmark both show recursive splitting at 400–512 tokens is within ~1–3 percentage points of the most expensive semantic methods. ([Chroma Research](https://research.trychroma.com/evaluating-chunking))

### Semantic chunking (embedding-based topic boundaries)

**When to use: only if recursive splitting fails your evaluation.** Every sentence must be embedded to compute similarity and find split points, which is expensive at ingest time. Results are inconsistent: Chroma saw `LLMSemanticChunker` hit 91.9% recall (best in their test); FloTorch's test had semantic chunking **54% end-to-end accuracy, 15 points behind recursive splitting**. The ~2–3% expected gain rarely justifies the cost on first build.

Sources: [PremAI — 2026 Benchmark Guide](https://blog.premai.io/rag-chunking-strategies-the-2026-benchmark-guide/), [Firecrawl — Best Chunking Strategies](https://www.firecrawl.dev/blog/best-chunking-strategies-rag).

### Structure-aware (Markdown / heading-aware / "by title")

**When to use: when your source has reliable structure** (Markdown headings, HTML `<h*>`, titled sections). Unstructured.io's "by title" strategy and LlamaIndex's `MarkdownNodeParser` keep sections intact. This is generally the single highest-leverage upgrade over plain recursive splitting for structured prose like docs and articles.

Source: [Unstructured — Chunking for RAG Best Practices](https://unstructured.io/blog/chunking-for-rag-best-practices).

---

## 6. Rules of thumb: tokens ↔ words ↔ lines ↔ characters

For modern English-trained BPE tokenizers (GPT-3.5/4, `text-embedding-3-*`, `cl100k_base`, most open-source successors):

- **1 token ≈ ¾ of a word** (OpenAI's published rule of thumb) ([OpenAI — What are tokens](https://help.openai.com/en/articles/4936856-what-are-tokens-and-how-to-count-them))
- **1 token ≈ 4 characters** of English prose
- **100 tokens ≈ 75 words**
- **1 word ≈ 1.3 tokens**
- A typical prose line at 80-char width ≈ ~13 words ≈ ~17 tokens

### Handy conversion table

| Tokens | Words | Characters | 80-col lines | Paragraphs |
|---|---|---|---|---|
| 64 | ~48 | ~256 | ~3 | 1 short |
| 128 | ~96 | ~512 | ~6 | 1 |
| **256** | **~190** | **~1,024** | **~13** | **1–2** |
| **512** | **~380** | **~2,048** | **~26** | **2–4** |
| 1,024 | ~760 | ~4,096 | ~52 | 4–8 |
| 2,048 | ~1,500 | ~8,192 | ~100 | 8–15 |

Sources: [OpenAI tokens help](https://help.openai.com/en/articles/4936856-what-are-tokens-and-how-to-count-them), [OpenAI Tokenizer](https://platform.openai.com/tokenizer).

**If you measure in characters (LangChain-style):** target ~1,000 chars for notes, ~2,000 chars for articles.
**If you measure in words (Haystack-style):** target ~190 for notes, ~380 for articles.
**If you measure in tokens (LlamaIndex-style, most accurate):** 256 for notes, 512 for articles.

---

## 7. Concrete starting points by content type

### Short notes (personal notes, meeting notes, Zettelkasten, idea snippets)

- **Chunk size: ~256 tokens (~190 words, ~1,000 chars)**
- **Overlap: ~25–50 tokens (10–20%)**
- **Splitter:** recursive on `\n\n` → `\n` → sentence → word
- **Special-case:** if a note is already shorter than the target, keep it as a single chunk; do not pad.
- **Why:** Notes are usually single-topic and short. Small chunks keep each vector sharply focused; the token-per-word economy of scale makes a fact lookup more precise. Too-large chunks blur the note's single point into surrounding context.

### Long-form articles (essays, blog posts, docs, book chapters)

- **Chunk size: ~512 tokens (~380 words, ~2,000 chars)**
- **Overlap: ~50–75 tokens (10–15%)**
- **Splitter:** recursive, structure-aware: respect Markdown headings (`#`, `##`) and paragraph boundaries first, then split within-section by sentence.
- **Optional upgrade:** keep the section heading (and ideally the article title) prepended to each chunk as metadata or inline "breadcrumb" — restoring context that was lost when the section was cut. This is a cheap, consistent retrieval-quality win.
- **Why:** Long-form prose often requires 2–4 paragraphs of context for a fact to be self-contained. 512 tokens aligns with both Chroma's best-performing recursive configuration and NVIDIA's best-for-synthesis range, and still fits safely inside the 512-token window of legacy encoder-based embedders.

### When to deviate

- **Fact-lookup / entity queries are dominant** → drop to 128–256 tokens. You'll see recall@1 improvements on factoid questions.
- **Synthesis / analytical queries are dominant** → go up to 1,024 tokens or page-level chunks. You'll preserve cross-paragraph context for multi-step reasoning.
- **Mixed / unknown query distribution** → stay at 512 tokens; it's the benchmark-validated middle.

---

## Evaluation advice

Every source agrees on one concrete piece of process advice: **evaluate on your own corpus and your own query distribution.** A 30-minute eval loop to try your target (e.g., 512/64 overlap) against two neighbors (256/32 and 1,024/128) on 50–100 representative queries, measuring recall@5 and/or MRR, is worth more than any blog post's recommendation — including this one.

Chroma's open-source [`chunking_evaluation`](https://github.com/brandonstarxel/chunking_evaluation) toolkit is a reasonable starting harness.

---

## Summary

| Question | Answer |
|---|---|
| Single best default for English prose? | **512 tokens recursive, ~10–15% overlap** |
| Best for short notes? | **256 tokens, ~10–20% overlap**; keep short notes whole |
| Best for long articles? | **512 tokens, ~50–75 overlap**, structure-aware, prepend heading |
| Fixed-size splitting? | Avoid; use recursive as the minimum |
| Semantic chunking? | Wait — only after measuring that recursive is insufficient |
| 1 token ≈ ? words | **0.75 words** (100 tokens ≈ 75 words) |
| 1 token ≈ ? characters | **4 characters** of English |
| Framework disagreement? | LangChain's 4,000-char default is too big; LlamaIndex's 1,024 tokens is too big for notes; Haystack's 200 words (~260 tokens) is closest to the benchmark sweet spot |

---

## Sources

### Framework documentation
- [LangChain — RecursiveCharacterTextSplitter docs](https://docs.langchain.com/oss/python/integrations/splitters/recursive_text_splitter)
- [LangChain — langchain_text_splitters reference](https://reference.langchain.com/python/langchain-text-splitters)
- [Understanding LangChain's RecursiveCharacterTextSplitter (Dev.to)](https://dev.to/eteimz/understanding-langchains-recursivecharactertextsplitter-2846)
- [LlamaIndex — Sentence splitter reference](https://docs.llamaindex.ai/en/stable/api_reference/node_parsers/sentence_splitter/)
- [LlamaIndex — Basic Strategies](https://developers.llamaindex.ai/python/framework/optimizing/basic_strategies/basic_strategies/)
- [Haystack — DocumentSplitter docs](https://docs.haystack.deepset.ai/docs/documentsplitter)
- [Haystack source — document_splitter.py](https://github.com/deepset-ai/haystack/blob/main/haystack/components/preprocessors/document_splitter.py)

### Empirical studies and benchmarks
- [Chroma Research — Evaluating Chunking Strategies for Retrieval](https://research.trychroma.com/evaluating-chunking)
- [Chroma chunking_evaluation GitHub](https://github.com/brandonstarxel/chunking_evaluation)
- [NVIDIA — Finding the Best Chunking Strategy for Accurate AI Responses](https://developer.nvidia.com/blog/finding-the-best-chunking-strategy-for-accurate-ai-responses/)
- [Rethinking Chunk Size for Long-Document Retrieval (arXiv 2505.21700)](https://arxiv.org/html/2505.21700v2)
- [AI21 — Chunk size is query-dependent](https://www.ai21.com/blog/query-dependent-chunking/)
- [PremAI — RAG Chunking Strategies: The 2026 Benchmark Guide](https://blog.premai.io/rag-chunking-strategies-the-2026-benchmark-guide/)
- [Firecrawl — Best Chunking Strategies for RAG in 2026](https://www.firecrawl.dev/blog/best-chunking-strategies-rag)
- [Redis — Best Chunking Strategies for RAG Pipelines](https://redis.io/blog/chunking-strategy-rag-pipelines/)

### Practitioner guidance
- [Unstructured — Chunking for RAG Best Practices](https://unstructured.io/blog/chunking-for-rag-best-practices)
- [Pinecone — Chunking Strategies](https://www.pinecone.io/learn/chunking-strategies/)
- [Unstract — Chunk size and overlap](https://docs.unstract.com/unstract/unstract_platform/user_guides/chunking/)
- [F22 Labs — 7 Chunking Strategies for RAG Systems](https://www.f22labs.com/blogs/7-chunking-strategies-in-rag-you-need-to-know/)

### Embedding-model and tokenization references
- [OpenAI — What are tokens and how to count them](https://help.openai.com/en/articles/4936856-what-are-tokens-and-how-to-count-them)
- [OpenAI Tokenizer playground](https://platform.openai.com/tokenizer)
- [Nomic Embed: Training a Reproducible Long Context Text Embedder (arXiv 2402.01613)](https://arxiv.org/html/2402.01613v2)
- [Weaviate — Vector Search Explained](https://weaviate.io/blog/vector-search-explained)
