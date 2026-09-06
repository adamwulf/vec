# E10 harness notes

Operator notes for the E10 Markdown-extraction retrieval harness. This
file documents HOW to run the harness and WHY it is built the way it is.
It is not the experiment plan or report — the manager owns `plan.md` and
`report.md`.

## What the harness compares

One corpus snapshot, one embedder, one chunk geometry, one concurrency —
two `TextExtractor` arms:

| arm          | `TextExtractionMode` | meaning                              |
|--------------|----------------------|--------------------------------------|
| `raw`        | `.raw`               | current / raw extraction             |
| `markdownV1` | `.markdownV1`        | generic Markdown normalization       |

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

The 13 queries cover: every one of the 8 saved items and `riot-data.md`;
deep transcript detail (`q04`, `q05`, `q06`); exact names / code terms
(`q02`, `q05`, `q07`, `q08`, `q09`); vague recollection (`q03`, `q10`);
and three no-answer probes (`q11` far, `q12` adjacent-tech, `q13` a
metadata trap that surfaces only via promotional link text in the raw
arm).

**File rank vs. passage quality.** File rank is the automatic,
authoritative signal. `passage_criteria` are advisory, human-checkable
strings the best passage should contain; the harness runs a best-effort,
case-insensitive check against the retrieved passage (reconstructed from
its source line range) and records the result separately. A human audits
a passage by opening the source file at the recorded `line_start` /
`line_end`.

## Environment contract

| variable                       | required | meaning |
|--------------------------------|----------|---------|
| `VEC_E10_BENCHMARK`            | to run   | set to `1` to enable; otherwise the test is skipped. |
| `VEC_MARKDOWN_MODEL_DIRECTORY` | yes¹     | absolute path to the pinned local `e5-base-v2` Bert bundle. |
| `VEC_MARKDOWN_MODEL_REVISION`  | no       | model revision/hash; stamped into the frozen manifest. |
| `VEC_MARKDOWN_CORPUS_DIRECTORY`| no       | corpus root (default `/tmp/LinksDatabase`). |
| `VEC_E10_OUTPUT_DIRECTORY`     | no       | archive directory (default: a fresh temp dir). |
| `VEC_E10_SCRATCH_DIRECTORY`    | no       | scratch root for snapshot + throwaway DBs (default: a fresh temp dir). |
| `VEC_E10_CONCURRENCY`          | no       | pipeline concurrency (default 8); shared by both arms. |
| `VEC_E10_MANIFEST`             | no       | override path to the query manifest. |
| `VEC_E10_PERSIST_PREVIEWS`     | no       | `1` writes previews/snippets into the archive — do **not** commit that output. |

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

* **Freeze before ranking.** The snapshot is copied and every input —
  each Markdown file, the query manifest, the settings, the model
  revision — is hashed into `frozen-input-manifest.json` **before** any
  indexing or search runs. A `run_identity` SHA binds them together.
* **No auto-resume.** The runner refuses to reuse a non-empty
  `VEC_E10_OUTPUT_DIRECTORY`. An interrupted arm is rebuilt into a fresh
  database and its queries recomputed — partial output is inspectable but
  never trusted. Per-query JSON is still written the moment each search
  returns, so a killed run leaves a readable trail.
* **Snapshot bodies stay scratch-only.** The snapshot lives under the
  scratch root and is deleted on teardown. No corpus body is written into
  the committed archive — only hashes, counts, line ranges, and metric
  results (unless `VEC_E10_PERSIST_PREVIEWS=1`, whose output must not be
  committed).

## Archive layout (written to `VEC_E10_OUTPUT_DIRECTORY`)

```
frozen-input-manifest.json     # inputs + hashes, written before ranking
comparison.json                # raw vs markdownV1, per query + aggregate
summary.md                     # human-readable tables
raw/arm-summary.json           # counts, chunks, timings, RSS, metrics
raw/q01.json … raw/q13.json    # per-query detail (top groups, audit)
markdownV1/arm-summary.json
markdownV1/q01.json … q13.json
```

Re-score an archived run with `scripts/score-markdown-rubric.py <dir>`.
