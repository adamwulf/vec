# E10 harness notes

Operator notes for the E10 Markdown-extraction retrieval harness. This
file documents HOW to run the harness and WHY it is built the way it is.
It is not the experiment plan or report — the manager owns `plan.md` and
`report.md`.

## What the harness compares

One corpus snapshot, one embedder, one chunk geometry, one concurrency —
two `TextExtractor` arms:

| arm           | `text_extraction` (raw value) | meaning                        |
|---------------|-------------------------------|--------------------------------|
| `raw`         | `raw`                         | current / raw extraction       |
| `markdown-v1` | `markdown-v1`                 | generic Markdown normalization |

Only the extraction mode differs. There is **no** format-specific
database behavior. The fixed profile is `e5-base@1200/0` (real
`intfloat/e5-base-v2`, 1200-char chunks, 0 overlap).

## The corpus and its scope

Source: `/tmp/LinksDatabase` (override with `VEC_MARKDOWN_CORPUS_DIRECTORY`).

The runner freezes **Markdown only** (`*.md`) into a scratch snapshot:
9 files total — the 8 saved items' `content.md` plus the large NPR asset
`assets/riot-data.md` (~2.5 MB). Everything else is **excluded**:
`transcript.json`, `content.json`, `info.json`, `activities.json`,
`properties.json`, `*.webloc`, `*.vtt`, `*.strings`, and all images/OCR.
No JSON and no OCR assets are indexed.

Nine files is a small corpus, so **top10 recall is uninformative** — a
run would trivially retrieve most files. Scoring therefore emphasizes
`rank1`, `top3`, `top5`, and `MRR`, plus separate no-answer probes.

## The fixed query manifest

`queries/rubric-queries.json` is the single source of truth for the
queries and their labels. Labels (`primary_file`, `relevant_files`,
`passage_criteria`) were assigned by reading each document's content
**before** any ranking was observed, and are frozen once committed.

The 15 queries cover: every one of the 8 saved items and `riot-data.md`;
deep transcript detail (`q04`, `q05`, `q06`, `q14`, `q15`); exact names /
code terms (`q02`, `q05`, `q07`, `q08`, `q09`); vague recollection
(`q03`, `q10`); and three no-answer probes (`q11` far, `q12`
adjacent-tech, `q13` a metadata trap that surfaces only via promotional
link text in the raw arm). `q14`/`q15` probe deep machining passages
(rake/power/chip-breaker trade-offs) rather than the video title.

**File rank vs. passage quality.** File rank is the automatic,
authoritative signal. `passage_criteria` are advisory, human-checkable
strings the best passage should contain. The harness records TWO
case-insensitive checks per criterion, kept distinct:

* `matched_in_pre_tokenizer_input` — the criterion against the
  **pre-tokenizer model input** for the retrieved chunk: the chunk is
  re-extracted by its ordinal and passed through the same
  `normalizeBertInputs` the embedder uses (content capped at the E5 char
  limit, then the `passage: ` prefix). This is the one `all_criteria_met`
  uses. **Caveat:** the BERT tokenizer then truncates to 512 tokens
  (fewer characters than the char cap), so a match here is *necessary but
  not sufficient* evidence the model encoded the term — the harness does
  not run the tokenizer, so it never claims exact effective-embedded
  evidence. It still prevents a whole-document chunk from claiming deep
  evidence beyond the char cap.
* `matched_in_source_range` — the criterion against the chunk's source
  line range (a **superset** of the chunk; the whole file for a
  whole-document chunk). Advisory only.

A human audits a passage by opening the source file at the recorded
`line_start` / `line_end`.

## Environment contract

| variable                       | required | meaning |
|--------------------------------|----------|---------|
| `VEC_E10_BENCHMARK`            | to run   | set to `1` to enable; otherwise the test is skipped. |
| `VEC_MARKDOWN_MODEL_DIRECTORY` | yes¹     | absolute path to the pinned local `e5-base-v2` Bert bundle. |
| `VEC_MARKDOWN_MODEL_REVISION`  | no       | model revision/hash; stamped into the frozen manifest. |
| `VEC_MARKDOWN_CORPUS_DIRECTORY`| no       | corpus root (default `/tmp/LinksDatabase`). |
| `VEC_E10_OUTPUT_DIRECTORY`     | no       | archive directory (default: a fresh temp dir). |
| `VEC_E10_SCRATCH_DIRECTORY`    | no       | scratch root for snapshot + throwaway DBs (default: a fresh temp dir). |
| `VEC_E10_CONCURRENCY`          | no       | pipeline concurrency (default 8); shared by both arms. Must be a positive integer if set (no silent fallback). |
| `VEC_E10_MANIFEST`             | no       | override path to the query manifest. |

The gate is exact: the heavy test runs only when `VEC_E10_BENCHMARK` is
exactly `1`. The cheap preflight tests (`MarkdownRetrievalManifestTests`)
run in a normal `swift test` with **no** gate, model, or corpus — they
catch manifest/enum drift and the scratch-ownership invariant.

¹ Required whenever `VEC_E10_BENCHMARK=1`. The default `swift-embeddings`
download target (`~/Documents/huggingface`) is outside the harness's
writable roots, so the harness **never** downloads: it loads the pinned
bundle from this directory via the internal
`E5BaseEmbedder(modelDirectory:)` seam. If the variable is absent the
test **fails** (it does not skip).

## Running

```bash
VEC_E10_BENCHMARK=1 \
VEC_MARKDOWN_MODEL_DIRECTORY=/private/tmp/vec-e10-model/<revision> \
VEC_MARKDOWN_MODEL_REVISION=<revision> \
VEC_E10_OUTPUT_DIRECTORY="$PWD/experiments/E10-markdown-extraction/runs/$(date +%Y%m%d-%H%M%S)" \
swift test --disable-sandbox \
  --filter VecKitTests.MarkdownRetrievalExperimentTests
```

`--disable-sandbox` matches the parent dependency-resolve flag; use it if
the plain `swift test` sandbox blocks the local model read.

## Freeze, resume, and provenance

* **Preflight before any work.** Every arm's `text_extraction` must map to
  a real `TextExtractionMode`; arm keys and query IDs must be unique and
  filename-safe; a no-answer query must have empty `relevant_files` and an
  answered one must list its `primary_file`. This runs before indexing, so
  a bad mode can never abort the second arm after the expensive first run.
* **Freeze before ranking.** The snapshot is copied and every input —
  each Markdown file, the query manifest, the settings, **and every file
  in the model directory** — is hashed into `frozen-input-manifest.json`
  **before** any indexing or search runs. The model files are hashed
  directly (a claimed revision string alone is not trusted). Build
  identity is recorded too: debug/release, OS, host, cores, `swift
  --version`, git HEAD, git dirty status (tracked files only), and the
  `Package.resolved` SHA256. The `run_identity` SHA binds corpus + model
  + manifest + ALL settings (encoded with sorted keys) together.
* **Fail on partial index.** After each arm the runner requires EVERY file
  to be `.indexed` with zero failed chunks; any skip or partial embed
  failure aborts the run rather than emitting a quality result on a
  partial index.
* **No auto-resume.** The runner refuses to reuse a non-empty
  `VEC_E10_OUTPUT_DIRECTORY`. An interrupted arm is rebuilt into a fresh
  database and its queries recomputed — partial output is inspectable but
  never trusted. Per-query JSON is still written the moment each search
  returns, so a killed run leaves a readable trail.
* **Snapshot bodies stay scratch-only.** The snapshot lives under a
  UNIQUE child of the scratch root (never the override directory itself)
  and only that child is deleted on teardown. No corpus body is written
  into the committed archive — only hashes, counts, line ranges, and
  metric results.

## Archive layout (written to `VEC_E10_OUTPUT_DIRECTORY`)

```
frozen-input-manifest.json       # inputs + corpus/model hashes + build id
comparison.json                  # raw vs markdown-v1, per query + aggregate
summary.md                       # human-readable tables
raw/arm-summary.json             # counts, chunks, timings, RSS, metrics
raw/q01.json … raw/q15.json      # per-query: ALL ordered groups + audit
markdown-v1/arm-summary.json
markdown-v1/q01.json … q15.json
```

Each `q*.json` archives every coalesced group in rank order, with each
match's source range, so file rank is independently recomputable.
Re-score an archived run with `scripts/score-markdown-rubric.py <dir>` —
it recomputes rank from the archived groups and rejects a partial or
corrupt archive.
