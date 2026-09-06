# E10 — Markdown extraction before embedding

Completed 2026-09-06. Keep `markdown-v1` opt-in. The experiment found denser transcript passages and fewer chunks, but **no measured improvement in file-finding accuracy**: both arms already ranked the correct file first for every answered query in this nine-file sample.

## What changed

Markdown link/image destinations are removed before the existing chunker runs; visible labels and alt text remain. This uses a Markdown parser and applies to `.md` and `.markdown` files in any directory. It does not recognize transcript timestamps, Notion bundles, or this corpus layout. Newlines and source-line correspondence remain intact. Code, bare URLs, frontmatter, headings, and lists are preserved. Reference definitions in the body and emphasis markers remain literal in this first version.

Raw extraction remains the default. A database records its extraction mode; updates and inserts inherit it. Legacy records decode as raw. Changing the mode requires reset/reindexing, preventing mixed extraction versions within an index.

## Method and provenance

The [fixed query manifest](queries/rubric-queries.json) was committed before any ranking: 12 answered queries covering exact names, vague recollection, and transcript details, plus 3 no-answer probes. Both arms used the same frozen nine Markdown files, including the large NPR attachment, from `/tmp/LinksDatabase`. Other assets were excluded equally; production scanning did not change.

Both arms used local `intfloat/e5-base-v2` revision `f52bf8ec8c7124536f0efb74aca902b2995e5bcd`, profile `e5-base@1200/0`, concurrency 8, batch 32, bucket width 500, and default compute policy. Search fetched 30 chunk hits and coalesced up to 10 files, matching the CLI. Only extraction mode differed. No model download or corpus upload occurred during the comparison.

The [successful run archive](runs/20260906-225138-metal/summary.md) contains all 30 query results, arm summaries, and a [frozen input manifest](runs/20260906-225138-metal/frozen-input-manifest.json) with corpus/model/query hashes and actual build settings. The run completed with exit 0 in 1,463 seconds on an M1 Pro with Metal available. Source commit `94f44fb` has the same tree as manager commit `20390ed`. Both arms indexed 9/9 files with no skipped files or failed chunks. The manager independently verified all input hashes, query identities, result-file completeness, and the Python scorer output. No source document bodies are archived.

The first attempt in the manager runtime failed before rankings because CoreML could not execute even a three-number tensor operation and Metal returned no device. The same probes passed in the worker runtime, which ran the unchanged benchmark through Python. The [failed attempt](runs/20260906-1741-coreml-unavailable/failure.md) is preserved separately and excluded from scoring.

## Results

| Measure | Raw | Markdown v1 |
|---|---:|---:|
| Correct file at rank 1 | 12/12 | 12/12 |
| Correct file in top 3 / top 5 | 12/12 / 12/12 | 12/12 / 12/12 |
| Mean reciprocal rank | 1.000 | 1.000 |
| Advisory passage criteria all present | 6/12 | 8/12 |
| Total chunks | 3,093 | 2,973 |
| Three transcript files: chunks | 163 | 78 |
| Index wall time | 665.95 s | 667.02 s |
| Extraction time reported by pipeline | 108.11 s | 63.55 s |
| Search-loop wall time, all 15 queries | 82.04 s | 47.09 s |
| Process RSS after indexing | 5,940 MiB | 4,817 MiB |

Overall chunk count fell 3.9%; transcript chunk count fell 52.1%. Transcript character counts fell 34.7%, 53.8%, and 54.4%. The large NPR attachment accounts for most chunks and changed little, which explains the smaller overall reduction. Indexing wall time was essentially unchanged. RSS is a process measurement at a point in time, not peak memory or database size.

Timing and memory differences are observations from one ordered run: raw ran first, normalized second. Runtime caches, initialization, batching shapes, and system load can affect them. Search-loop time includes passage-audit work, so these figures are not isolated query-latency benchmarks. This experiment does not establish a speed or memory improvement.

## Passage checks

The advisory metric tests whether the fixed criteria occur in the highest-scoring passage for the expected file, after the same character preparation used by batch embedding. It checks **pre-tokenizer input**, not proof that the model encoded every matching word: BERT subsequently truncates to 512 tokens. It is a literal heuristic, not a human relevance score or answer-accuracy measure. Source ranges remain separately inspectable.

The two added passes are both in the HSS tool-grinding transcript:

- **q05, grinding HSS bits on a bench grinder:** raw's best passage spans source lines 32–43 and lacks the bench-grinder detail. Normalized's best passage spans 219–244 and includes both the material and the grinding step.
- **q15, chip breaker and rake:** raw's passage ends at line 724, immediately before the explanation that the rake becomes more positive. Normalized spans 715–740 and retains that explanation. This is a concrete example of more surrounding content fitting into the same character budget.

There are still meaningful misses. For **q14**, normalization includes the weaker-edge explanation at lines 497–500, but the best chunk ends at 507; the lower-power explanation starts at 509. It still fails the full criteria. **q02** finds the correct large NPR file but its best passage lacks the requested militia name. **q04** splits atmosphere and Thanksgiving evidence across different passages. **q07** misses one literal criterion despite a passage about fractional indexing, illustrating the limits of keyword checks.

## No-answer probes

| Query | Raw top result / score | Markdown v1 top result / score |
|---|---|---|
| Sourdough hydration | HSS grinding / 0.789 | HSS grinding / 0.770 |
| Kubernetes ingress and TLS | HSS grinding / 0.766 | Runestone / 0.768 |
| Sicilian Najdorf theory | Anna Rudolf account story / 0.754 | Anna Rudolf account story / 0.754 |

Neither mode establishes that an answer exists. These scores are similarities, not confidence probabilities. Three negative probes cannot calibrate a rejection threshold; none was added.

## Decision and next step

This is a useful optional preprocessing capability with encouraging passage-density evidence, not a demonstrated solution to retrieval accuracy. The small, mostly topically distinct sample has a file-rank ceiling and does not test generalization to a larger directory. The two extra heuristic passes come from one transcript. Existing batch/single inference parity failures on this host are recorded in the [review notes](review-notes.md); inference was held fixed rather than changed during this experiment.

The next smallest experiment should improve the evaluation: add similar-topic distractor documents and user-written recollection queries, fixing labels before ranking, while keeping this model and chunker unchanged. If passage boundaries remain the problem, evaluate one generic boundary/context change separately. There is no evidence here requiring a newer model, format-specific parsing rules, or a default flip.

To opt in for a fresh or reset database:

```bash
vec update-index --db <name> --text-extraction markdown-v1
```

See [harness notes](harness-notes.md) for the exact benchmark invocation and [review notes](review-notes.md) for test coverage and known baseline issues.
