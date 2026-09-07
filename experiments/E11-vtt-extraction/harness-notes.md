# E11 harness notes

Operator notes for the E11 WebVTT-extraction retrieval harness. This file
documents HOW to run the harness and WHY it is built the way it is. It is
not the experiment plan or report — the manager owns `plan.md`,
`validation.md`, and any `report.md`.

The harness is a focused adaptation of the E10 Markdown harness
(`Tests/VecKitTests/MarkdownRetrievalExperimentTests.swift`). It reuses
E10's schema, freezing, preflight, strict partial-failure handling,
coalesced search, and passage auditing unchanged, and adds three
WebVTT-specific pieces: a `.vtt` corpus freeze, a sample-manifest
anti-drift gate, and per-arm / per-file scaffolding-noise statistics. No
`Sources/` inference or extraction code is changed by this harness.

## What the harness compares

One corpus snapshot, one embedder, one chunk geometry, one concurrency —
two `TextExtractor` arms:

| arm      | `text_extraction` (raw value) | meaning                                   |
|----------|-------------------------------|-------------------------------------------|
| `raw`    | `raw`                         | current extraction: the whole `.vtt` file, cue scaffolding included |
| `vtt-v1` | `vtt-v1`                      | the v1 WebVTT normalizer runs on `.vtt`   |

Only the extraction mode differs. There is **no** format-specific database
behavior and **no** inference change. The fixed profile is `e5-base@1200/0`
(real `intfloat/e5-base-v2`, 1200-char chunks, 0 overlap), the same pinned
local E5 bundle E10 used.

Both arms document AND query through exactly the same code paths: documents
via the batch embedding pipeline (`IndexingPipeline` →
`Embedder.embedDocuments`), queries via the single-query path
(`E5BaseEmbedder.embedQuery`). Only the `TextExtractor` mode differs.

**Baseline: main `5ee92ab563d348924312747e6631a639b96f1b35`, post parity
fix.** This branch is **rebased** onto that main commit, which includes the
single/batch embedding-parity fix. For E5 the batch document path now
prepends `passage: ` within the 2,000-character cap using the SAME shared
helper the single/query paths use (`E5BaseEmbedder.normalizeInputs`,
prefix-then-cap), so the single and batch document paths apply identical
input preprocessing, and E5 query/single vectors are unchanged by the fix.
The fix brings single and batch into agreement within the tested 0.9999
cosine tolerance (see `BertBatchParityTests` and
`data/embedding-batch-parity.md`); this run does not itself re-verify parity
and makes **no** claim that single-vs-batch divergence is mathematically
impossible in general beyond that tested fix. The five pre-existing
single-vs-batch parity assertions recorded in the E10-era `validation.md`
were addressed by this fix and no longer apply as failures to this run.

Because of that fix, **this baseline differs from the E10 inference
revision**: E11 absolute scores are NOT comparable to E10's, and E11 must be
read as raw-vs-vtt-v1 on this inference. The harness itself changes no
inference code; it merely runs on the rebased baseline. Running documents
through the batch path and queries through the single path reflects the real
CLI.

## The corpus and its scope

Source (default): `experiments/E11-vtt-extraction/sample` (override with
`VEC_VTT_CORPUS_DIRECTORY`).

The runner freezes **WebVTT only** (`*.vtt`), discovered **recursively**,
into a scratch snapshot. The E11 sample is a **fixed, committed corpus of
16 files: 1 real caption file and 15 synthetic ones**. Everything else in
the directory (including the sample manifest itself) is excluded from the
snapshot.

Sixteen files is a small corpus, so **top10 recall is uninformative** — a
run would trivially retrieve most files. Scoring therefore emphasizes
`rank1`, `top3`, `top5`, and `MRR`. The planned rubric has **15 answered
queries and no no-answer queries**, so there are no no-answer probes to
report (the harness still supports them generally, per the E10 rule, if a
future manifest adds one).

### Sample manifest — anti-drift gate

The parent's `freeze-sample.py` writes `manifest.json` next to the `.vtt`
sample (at `<corpus>/manifest.json`), recording every file's `path`,
`bytes`, and `sha256` (plus metadata the harness ignores: `schema_version`,
`experiment`, `frozen_at`, `real_source`, `real_files`, `synthetic_files`,
`scope`, and per-file `origin` / `cue_count` / inventory fields).

Before **any** indexing the harness:

1. **requires** the manifest (the benchmark refuses to run without it);
2. verifies its `{path, bytes, sha256}` set **exactly equals** the frozen
   snapshot — any missing path, extra path, byte mismatch, or hash mismatch
   is a hard failure (sha compare is case-insensitive). If both
   `real_files` and `synthetic_files` are present, they must sum to the file
   count;
3. archives a byte-for-byte copy as `sample-manifest.json`;
4. binds the manifest's sha256 into `frozen-input-manifest.json`
   (`sample_manifest_sha256`) **and** into the `run_identity`.

This makes it impossible to score the fixed rubric labels against a sample
that drifted after labeling.

### Corpus drift FAILS (it does not warn)

E10 only *warned* when the snapshot file count differed from the manifest's
`expected_markdown_files`, because its live `markdown-memory` corpus grows
via operator-triggered Granola syncs. E11's sample is a fixed committed
corpus, so any mismatch means the sample is wrong. The harness therefore
**throws** when the frozen `.vtt` count differs from
`corpus.expected_vtt_files` (16). Combined with the sample-manifest gate
above, the corpus is pinned three ways: count, per-file hash set, and the
sha256 of the manifest itself.

## The fixed query manifest

`queries/rubric-queries.json` is the single source of truth for the queries
and their labels, in the same shape as E10. Labels (`primary_file`,
`relevant_files`, `passage_criteria`) are assigned by reading each file's
content **before** any ranking is observed, and are frozen once committed.
The parent plans 15 answered queries (each pointing at one caption file) and
**no no-answer queries**; the 16th file is an unlabeled distractor, never a
`primary_file`, exercised only as a competing candidate. (The harness still
supports no-answer queries generally — a no-answer query has empty
`relevant_files`, per the E10 rule — but the planned E11 rubric has none.)

**File rank vs. passage quality.** File rank is the automatic,
authoritative signal. `passage_criteria` are advisory, human-checkable
strings the best passage should contain. The harness records TWO
case-insensitive checks per criterion, kept distinct:

* `matched_in_pre_tokenizer_input` — the criterion against the
  **pre-tokenizer model input** for the retrieved chunk. The chunk is
  reconstructed **by its ordinal** from the arm's own extractor and passed
  through the same **`E5BaseEmbedder.normalizeInputs`** the embedder uses:
  the `passage: ` prefix is prepended, then the combined string is capped
  at the E5 char limit (2,000) — **prefix-then-cap**, the shared helper for
  E5's single and batch document paths under the current-main parity fix.
  (This is E5's own helper, *not* the generic `normalizeBertInputs`, which
  caps content *before* prefixing — the Nomic convention — and no longer
  describes E5.) This is the one `all_criteria_met` uses. **For vtt-v1 this
  matters:** the normalizer reflows cue lines, so the raw source line range
  is *not* the embedded text — re-extracting the chunk by ordinal recovers
  the actual reflowed prose that was embedded. **Caveat:** the BERT
  tokenizer then truncates to 512 tokens (fewer characters than the char
  cap), so a match here is *necessary but not sufficient* evidence the model
  encoded the term.
* `matched_in_source_range` — the criterion against the chunk's **raw**
  source line range in the `.vtt` file (a **superset** that, for both arms,
  still contains timing lines and inline cue tags; the whole file for a
  whole-document chunk). Advisory only. Because vtt-v1 reflows, this is the
  *originating cue span*, not the embedded text; a criterion that matches
  here but not in the pre-tokenizer input indicates normalization
  reflowed/dropped it.

Because the raw arm's passage text still carries cue tags, character
entities, and rolling-caption fragmentation, these literal criteria can fail
on `raw` even when the content is present — so `passage_all_met` is a
structure-sensitive advisory, not an arm-neutral measure of semantic
accuracy, and it must not be read as a fair raw-vs-vtt-v1 accuracy
comparison.

A human audits a passage by opening the source file at the recorded
`line_start` / `line_end` (the coarse cue span, per the E11 source-mapping
design).

## Scaffolding-noise statistics (E11-specific)

The whole point of comparing `raw` vs `vtt-v1` is whether normalization
keeps WebVTT scaffolding out of the embedding input. The harness measures
this on the **full extracted chunk texts** (raw text for the `raw` arm,
normalized text for `vtt-v1`) via `VTTNoiseDetector`. This is an
**extracted-text heuristic, computed BEFORE E5's 2,000-character cap and the
BERT tokenizer's 512-token truncation** — so a timing line or tag counted
here is an *upper bound* on what reaches the model: content past the char
cap or the token limit (notably in the whole-document chunk, and the tail of
any long chunk) may never be embedded. It measures residual scaffolding
shape in the extracted text, not a guarantee of what is in the vectors.

A chunk is **noisy** if it contains at least one of:

* **timestamp LINE** — a full cue timing line: an `HH:MM:SS.fff` (or
  `MM:SS.fff`) clock, the `-->` arrow, a second clock, then optional cue
  settings. The regex is anchored to a line (`^…$` with
  `.anchorsMatchLines`), leading whitespace allowed (real exporters
  indent):

  ```
  ^[ \t]*(?:[0-9]{2,}:)?[0-9]{2}:[0-9]{2}\.[0-9]{3}[ \t]+-->[ \t]+(?:[0-9]{2,}:)?[0-9]{2}:[0-9]{2}\.[0-9]{3}(?:[ \t].*)?$
  ```

  Anchoring on the `-->` arrow is what stops ordinary prose that merely
  mentions a time (`we met at 3:00`) or a number (`1,575 defendants`) from
  counting. This mirrors `VTTTextNormalizer`'s private `timing` pattern; if
  that pattern changes, update this one in step.

* **inline tag** — a narrow WebVTT cue tag: `<` (optionally `/`) followed by
  EITHER an ASCII-letter-led element name (`<v …>`, `</v>`, `<c.loud>`,
  `<i>`, `<lang en>`, `<ruby>`, `<br>`, …) OR an inline `<HH:MM:SS.fff>`
  timestamp:

  ```
  </?(?:[A-Za-z][^<>\r\n]*|(?:[0-9]{2,}:)?[0-9]{2}:[0-9]{2}\.[0-9]{3})>
  ```

  Requiring a letter or a timestamp immediately after `<` means ordinary
  prose comparisons — `a < b`, `5 < 10 > 3`, `temperature < 0` — never
  count as tags.

  **Known heuristic edges (intentional, documented, not fixed):** a
  spaceless `a<b>c` counts, and a **decoded literal `<i>`** that appears in
  genuine prose (e.g. from `&lt;i&gt;`, which the vtt-v1 normalizer decodes)
  counts as syntactic noise. These are rare; the metric measures residual
  angle-bracket markup *shape*, not semantics.

Counts are recorded per arm (aggregate) and per file, and each over two
buckets:

* `all_chunks` — every extracted chunk (the `.whole` document chunk plus the
  passage chunks);
* `passage_chunks` — the passage chunks only (every chunk except `.whole`).

Each bucket carries `chunk_count`, `timestamp_chunks`, `inline_tag_chunks`,
`noisy_chunks`, and `noisy_share`. `noisy_chunks` is the **union**
(timestamp OR tag, counted once); `timestamp_chunks` and `inline_tag_chunks`
may overlap. `noisy_share = noisy_chunks / chunk_count` (0 when there are no
chunks). The arm aggregate is the exact **sum** of the per-file buckets
(share recomputed from the summed counts), so the Python scorer can
re-derive the arm total by summing per-file counts and validating the
ratios.

Expect the `raw` arm to be heavily noisy (its extracted chunks are riddled
with timing lines and tags) and `vtt-v1` to be near-zero; residual `vtt-v1`
noise is the useful signal (e.g. a decoded literal angle-bracket, or a
construct the normalizer left intact).

## Environment contract

| variable                    | required | meaning |
|-----------------------------|----------|---------|
| `VEC_E11_BENCHMARK`         | to run   | set to `1` to enable; otherwise the heavy test is skipped. |
| `VEC_VTT_MODEL_DIRECTORY`   | no¹      | absolute path to the pinned local `e5-base-v2` Bert bundle. Defaults to `/private/tmp/vec-e10-model/f52bf8ec8c7124536f0efb74aca902b2995e5bcd`. |
| `VEC_VTT_MODEL_REVISION`    | no       | model revision/hash stamped into the frozen manifest (defaults to the model directory's leaf name). |
| `VEC_VTT_CORPUS_DIRECTORY`  | no       | corpus root (default `experiments/E11-vtt-extraction/sample`). Must contain the `.vtt` sample and its `manifest.json`. |
| `VEC_E11_OUTPUT_DIRECTORY`  | no       | archive directory (default: a fresh temp dir). |
| `VEC_E11_SCRATCH_DIRECTORY` | no       | scratch root for snapshot + throwaway DBs (default: a fresh temp dir). |
| `VEC_E11_CONCURRENCY`       | no       | pipeline concurrency (default 8); shared by both arms. Must be a positive integer if set (no silent fallback). |
| `VEC_E11_MANIFEST`          | no       | override path to the query manifest. |

The gate is exact: the heavy test runs only when `VEC_E11_BENCHMARK` is
exactly `1`. The cheap tests (`VTTRetrievalManifestTests`) run in a normal
`swift test` with **no** gate, model, or corpus — they catch manifest/enum
drift, the scratch-ownership invariant, the noise-regex behavior, and the
sample-manifest verifier. The committed query manifest may not exist yet
(the manager writes the sample + rubric before the benchmark), so the
committed-manifest preflight **skips** when the file is absent rather than
failing.

¹ The default `swift-embeddings` download target (`~/Documents/huggingface`)
is outside the harness's writable roots, so the harness **never** downloads:
it loads the pinned bundle via the internal `E5BaseEmbedder(modelDirectory:)`
seam. If the resolved model directory does not exist the test **fails** (it
does not skip and does not download).

## Running

```bash
VEC_E11_BENCHMARK=1 \
VEC_VTT_MODEL_DIRECTORY=/private/tmp/vec-e10-model/<revision> \
VEC_VTT_MODEL_REVISION=<revision> \
VEC_E11_OUTPUT_DIRECTORY="$PWD/experiments/E11-vtt-extraction/runs/$(date +%Y%m%d-%H%M%S)" \
swift test --disable-sandbox --disable-swift-testing -c release -j 4 \
  --filter VecKitTests.VTTRetrievalExperimentTests
```

Flags:
* `--disable-sandbox` matches the parent dependency-resolve flag; use it if
  the plain `swift test` sandbox blocks the local model read.
* `--disable-swift-testing` avoids a release-runner issue: with `-c release`
  the extra Swift Testing launcher invokes the `vec` executable with an
  unknown `--test-bundle-path`, so the process exits 1 *after* the XCTest
  cases already passed. This benchmark (and every E11 test here) is
  XCTest-only, so disabling Swift Testing removes no E11 tests. `-c release`
  also makes the heavy run materially faster.

The cheap tests run the same way without the env vars:
`swift test --disable-sandbox --disable-swift-testing --filter VTTRetrievalManifestTests`.

**Do not run the benchmark until the parent authorizes it** after the
sample + rubric are frozen and reviewed. The parent will ask for a full
benchmark run in the worker runtime; the parent also adapts the scorer and
commits the sample + rubric before any benchmark.

## Freeze, resume, and provenance

* **Preflight before any work.** Every arm's `text_extraction` must map to a
  real `TextExtractionMode`; arm keys and query IDs must be unique and
  filename-safe; a no-answer query must have empty `relevant_files` and an
  answered one must list its `primary_file`. This runs before indexing, so a
  bad mode can never abort the second arm after the expensive first run.
* **Sample-manifest gate + drift failure before ranking** (see above).
* **Freeze before ranking.** The snapshot is copied and every input — each
  `.vtt` file, the query manifest, the sample manifest, the settings, **and
  every file in the model directory** — is hashed into
  `frozen-input-manifest.json` **before** any indexing or search runs. The
  model files are hashed directly (a claimed revision string alone is not
  trusted). Build identity is recorded too: debug/release, OS, host, cores,
  `swift --version`, git HEAD, git dirty status (tracked files only), and the
  `Package.resolved` SHA256. The `run_identity` SHA binds corpus + model +
  query manifest + sample manifest + ALL settings (sorted keys) together.
* **Fail on partial index.** After each arm the runner requires EVERY file
  to be `.indexed` with zero failed chunks; any skip or partial embed
  failure aborts the run. It also asserts the re-extracted chunk count
  equals the DB chunk count per file, so the ordinal-based passage audit and
  the noise stats operate on exactly the indexed chunk set.
* **No auto-resume.** The runner refuses to reuse a non-empty
  `VEC_E11_OUTPUT_DIRECTORY`. An interrupted arm is rebuilt into a fresh
  database and its queries recomputed — partial output is inspectable but
  never trusted. Per-query JSON is written the moment each search returns.
* **Snapshot bodies stay scratch-only.** The snapshot lives under a UNIQUE
  child of the scratch root (never the override directory itself) and only
  that child is deleted on teardown. No corpus body is written into the
  committed archive — only hashes, counts, line ranges, noise counts, and
  metric results. (The archived `sample-manifest.json` is the parent's own
  manifest, which carries no caption body.)

## Archive layout (written to `VEC_E11_OUTPUT_DIRECTORY`)

```
frozen-input-manifest.json       # inputs + corpus/model/sample hashes + build id
sample-manifest.json             # byte-for-byte copy of the parent's sample manifest
comparison.json                  # raw vs vtt-v1, per query + aggregate
summary.md                       # human-readable tables (incl. noise share)
raw/arm-summary.json             # counts, chunks, timings, RSS, metrics, noise_stats
raw/q01.json … q15.json          # per-query: ALL ordered groups + audit
vtt-v1/arm-summary.json
vtt-v1/q01.json … q15.json
```

### Schema notes for the scorer

The per-query `q*.json` and `comparison.json` keep the **E10 keys
verbatim**, so the E10 scorer adapts with minimal change:

* `q*.json`: `groups[]` (each `rank`, `file`, `best_score`, `match_count`,
  `matches[]` with `score`/`distance`/`chunk_type`/`line_start`/`line_end`/
  `chunk_ordinal`), plus `file_rank`, `hit_at_{1,3,5}`, `reciprocal_rank`,
  `is_no_answer`, `primary_file`, `relevant_files`, and `primary_audit`
  (with `all_criteria_met` and per-`criteria` `matched_in_pre_tokenizer_input`
  / `matched_in_source_range`). File rank is independently recomputable from
  the archived `best_score`-descending group order.
* `arm-summary.json`: the E10 fields plus **`noise_stats`** =
  `{ all_chunks, passage_chunks }`, each `{ chunk_count, timestamp_chunks,
  inline_tag_chunks, noisy_chunks, noisy_share }`. Every `per_file_chunks[]`
  entry carries the same `noise_stats` shape. The arm aggregate equals the
  sum of the per-file counts (ratios recomputed from the sums), so the
  scorer can validate by summing per-file counts and re-deriving the ratios.
* `frozen-input-manifest.json`: E10 fields plus `sample_manifest_path` and
  `sample_manifest_sha256`.

Re-score an archived run with the parent's E11 scorer (adapted from
`experiments/E10-markdown-extraction/scripts/score-markdown-rubric.py`); it
recomputes rank from the archived groups and rejects a partial or corrupt
archive.
