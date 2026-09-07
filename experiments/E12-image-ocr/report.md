# E12 — Opt-in image OCR before embedding: measured report

Status: measured and archived (2026-09-07). This report records the
native-runtime results of the two E12 benchmarks. It is written from the
committed archives under `runs/`; the pre-run design is in
[`plan.md`](plan.md) and the harness rationale in
[`harness-notes.md`](harness-notes.md).

The frozen inputs (18-image sample, 15 query labels, manifests, scorer)
were fixed and committed before any ranking. The prior worker session's
uncommitted retrieval archive was lost; every rank in this report was
regenerated from the frozen bytes and the unchanged 15 query labels — no
prior number is assumed.

## Question

Does OCR-indexing raster images (via the opt-in `image-ocr-v1`
extraction mode) make the text INSIDE images retrievable with the
existing default embedder, and what does that OCR cost in wall-clock and
memory at 1/4/8 concurrent jobs, cold vs warm cache?

## Provenance

All runs share this environment (recorded in each archive's
`execution-command.txt` / `frozen-input-manifest.json`):

| item | value |
|---|---|
| hardware | MacBookPro18,1 — Apple M1 Pro, 10 cores (8 performance + 2 efficiency), 32 GB RAM |
| OS | macOS Version 26.6.2 (Build 25G83) |
| Swift | Apple Swift 6.2.4 (swiftlang-6.2.4.1.4 clang-1700.6.4.2), target arm64-apple-macosx26.0 |
| build | `swift test -c release --disable-sandbox --disable-swift-testing -j 4` |
| embedder | local `intfloat/e5-base-v2`, revision `f52bf8ec8c7124536f0efb74aca902b2995e5bcd` (7 files hashed), NO network |
| profile | `e5-base@1200/0` — chunk 1200 / overlap 0, dim 768, concurrency 8, ocrConcurrency 4, batch 32, bucket 500 |
| OCR | `ImageOCR` v1, requestRevision 3 (`VNRecognizeTextRequestRevision3`), maxPixelDimension 4096 |
| Package.resolved | sha256 `d3dad0550daef3df320799330ec5b6b8ee49e8772ce2fde1a1a0e3aa796bb10c` |

The hardware model / RAM were read read-only via `sysctlbyname`
(`hw.model`, `machdep.cpu.brand_string`, `hw.perflevel*`, `hw.memsize`);
`10 cores` alone is not a machine identity.

The benchmarks are launched through
[`scripts/run-benchmark.swift`](scripts/run-benchmark.swift), a
task-local Swift shim that sets the required `VEC_E12_*` variables in the
CHILD process and spawns `xcrun swift test`; it exists because the
sandbox allow-list matches `swift` only as a first token, so an
env-prefixed `swift test` cannot be run directly. Each run's exact
invocation and resolved variables are logged at the top of that run's
`execution-log.txt`.

## Benchmark 1 — Retrieval (raw vs image-ocr-v1)

Archive: [`runs/20260907-retrieval/`](runs/20260907-retrieval/) —
run_identity `f8029b668a6e25945efe8eb2b3833130777946e8fa2e32dba2fa96022c18af02`.
Both arms ran through the production path (real `FileScanner` → real
`IndexingPipeline` → real `TextExtractor`) over the one frozen 18-image
snapshot. Ranks below are the independent Python scorer's output
(`score-report.txt` / `score.json`); all its integrity gates passed
(manifest + sample fingerprints match, the raw baseline is a genuinely
empty index, and every derived rank equals the stored `file_rank`).

| arm | rank1 | top3 | top5 | MRR | real rank1 | real MRR | synth rank1 | synth MRR | advisory passage | scanned | indexed | chunks |
|---|---|---|---|---|---|---|---|---|---|---|---|
| raw | 0/15 | 0/15 | 0/15 | 0.000 | 0/4 | 0.000 | 0/11 | 0.000 | 0/15 | 0 | 0 | 0 |
| image-ocr-v1 | 14/15 | 15/15 | 15/15 | 0.967 | 3/4 | 0.875 | 11/11 | 1.000 | 13/15 | 18 | 17 | 19 |

- **raw** indexes ZERO images by design — the production scanner's
  `.raw` mode excludes every image — so its 0/15 is an honest floor, not
  a bug: it quantifies that image text is unreachable without OCR. The
  raw-vs-OCR comparison is therefore one-sided by construction.
- **image-ocr-v1** discovered all 18 images, indexed 17, and left 1
  blank: the `app-icon-crystal.png` distractor OCRs to empty text (0
  chunks), which is the expected outcome, not a failure. The OCR cache
  showed hits 0 / misses 18 / ocrCalls 18 at end-of-indexing (every
  image freshly recognized).
- The one real non-rank-1 result is **q04** ("Which image is the
  Minecraft video thumbnail titled ATMOSPHERE?"), where
  `real/minecraft-atmosphere-thumbnail.jpg` landed at rank 2
  (best_score 0.7462), just behind `synthetic/titan-methane-lakes.png`
  (0.7593) — a ~0.013 margin. The Minecraft thumbnail is a sparse-text
  title image, so its OCR text is short and a semantically-adjacent
  synthetic passage (a planet's methane "atmosphere") edged it out. All
  11 synthetic targets and the other 3 real targets ranked 1.
- Process-wide RSS after indexing: raw 485 MiB, image-ocr-v1 3975 MiB.
  This is NOT an OCR-only figure — it includes the loaded 437 MB E5
  model and Vision's own allocations. Index wall 10.99 s, search 1.37 s.

The `advisory passage` column is a case-insensitive check of each query's
criteria against the pre-tokenizer OCR text, reconstructed by ordinal via
`E5BaseEmbedder.normalizeInputs`. The tokenizer truncates further to 512
tokens, so a match is necessary but not sufficient, and it never gates
file rank.

## Benchmark 2 — Throughput / cold-warm cache

Two runs, both jobs 1/4/8, cold then warm, driving `ImageOCRCache` (real
`ImageOCR`) directly — no embedder. RSS is process-wide and is NOT reset
between passes or job counts (one process), so cross-pass deltas are not
independent measurements. All RSS values are **MiB** (see the units note
below).

### 2a. Frozen 18-image sample (synthetic-heavy)

Archive:
[`runs/20260907-throughput-frozen18/`](runs/20260907-throughput-frozen18/).
All cold/warm truth checks held (cold: 18 ocrCalls / 0 hits; warm: 0
ocrCalls / 18 disk-sidecar hits). Zero recognizer failures.

| jobs | pass | img/s | wall s | peak RSS | mean RSS | 325k est |
|---|---|---|---|---|---|---|
| 1 | cold | 0.68 | 26.59 | 273 MiB | 216 MiB | 133.4 h |
| 4 | cold | 0.80 | 22.36 | 330 MiB | 313 MiB | 112.2 h |
| 8 | cold | 0.69 | 26.11 | 356 MiB | 242 MiB | 130.9 h |
| 1 | warm | 1870.96 | 0.01 | 265 MiB | 265 MiB | ~2.9 min |
| 4 | warm | 6320.87 | 0.00 | 310 MiB | 310 MiB | ~51 s |
| 8 | warm | 11779.46 | 0.00 | 204 MiB | 204 MiB | ~28 s |

### 2b. Capped real-image sample (153 images)

Archive:
[`runs/20260907-throughput-real153/`](runs/20260907-throughput-real153/).
Sample: a deterministic, unbiased selection from the user's
`/tmp/LinksDatabase` link archive, produced by
[`scripts/select-real-images.py`](scripts/select-real-images.py) — sort
every supported image by absolute path, stride step = max(1, total//150)
= 7 over 1071 found, take all stride picks (spans the whole sorted
corpus; unbiased by OCR success or rank; only unsupported formats
excluded) → 153 images across all three folders (4 Notion /
147 Notion-Addendum / 2 YouTube). Each file's source path, bytes, and
sha256 are in `real-sample-provenance.json`, whose {name, sha256} set
matches the archive's `frozen_images` exactly (verified). Zero
recognizer failures.

| jobs | pass | img/s | wall s | peak RSS | mean RSS | 325k est |
|---|---|---|---|---|---|---|
| 1 | cold | 6.85 | 22.32 | 240 MiB | 181 MiB | 13.2 h |
| 4 | cold | 10.34 | 14.80 | 267 MiB | 241 MiB | 8.7 h |
| 8 | cold | 11.27 | 13.58 | 275 MiB | 251 MiB | 8.0 h |
| 1 | warm | 3901.54 | 0.04 | 234 MiB | 233 MiB | ~83 s |
| 4 | warm | 10602.11 | 0.01 | 257 MiB | 257 MiB | ~31 s |
| 8 | warm | 19046.24 | 0.01 | 265 MiB | 265 MiB | ~17 s |

### What the throughput numbers mean

- **Cold rate is dominated by text density, not image count.** The
  synthetic images are dense, full-text renders; the real thumbnails and
  photos carry little text, so Vision recognizes far fewer regions and
  the cold rate is ~10–16× higher on the real sample (0.68–0.80 img/s
  synthetic vs 6.85–11.27 img/s real). On the real sample cold
  throughput also scales with concurrency (6.85 → 11.27 img/s from
  1 → 8 jobs); on the tiny synthetic sample it does not (the corpus is
  too small and noisy, and accurate-mode Vision is largely serialized on
  the ANE).
- **The 325k extrapolations are conditional, order-of-magnitude only.**
  Each is a linear projection of one pass's images/second. The real-153
  estimate of ~8–13 h is conditional on a similar image mix; the
  deterministic stride covers only the modest supplied folder and can
  differ from the full 325k corpus in format and text density, so it is
  NOT an established full-corpus time. The synthetic-heavy ~112–133 h is
  a valuable contrast: it is what a text-dense corpus would cost. The
  true full-corpus cost lies somewhere between, depending on the real
  mix of text density.
- **Warm figures are not a production time.** Each warm pass served from
  the on-disk sidecar in 0.008–0.039 s with only 1–2 RSS samples, so the
  warm images/second (and its 325k projection) is extremely noisy and
  must not be read as a reliable steady-state rate. It only shows that a
  populated cache skips Vision entirely (0 ocrCalls). Warm RSS is also
  not a cold-start figure — the process and Vision's caches persist from
  the cold pass.
- **Downscale caveat.** `ImageOCR` downsamples any image whose longest
  edge exceeds 4096 px before recognition, so very small text in a very
  large image can be lost. The throughput number measures speed, not
  that fidelity loss.

## Investigation of the prior throughput failure

The prior worker reported a throughput failure whose archive was lost.
Running a fresh native throughput pass on the frozen 18-image sample and
on the deterministic 153-image real sample produced **zero recognizer
failures at every job count**, so the failure did NOT reproduce on these
inputs. No `failed-pass-*.json` diagnostic was emitted by either
measured run. The original cause is therefore not established from these
runs; it may have involved a different or larger selection (the full
`/tmp/LinksDatabase` has 1071 supported images; the strided 153-image
sample may not include a file that previously failed) or the pre-fix
harness that discarded failure evidence.

Separately, the harness now retains that evidence (reviewer TH1). A
deliberate **fault-injection** — a two-file corpus with one decodable
image and one undecodable `.png` — confirms the path:
[`runs/20260907-th1-faultcheck/`](runs/20260907-th1-faultcheck/). The
`jobs=1 cold` pass wrote `failed-pass-1-cold.json` (attempted 2 /
succeeded 1 / failed 1, the failing file and its `undecodable(…)` error,
and the cache/RSS readings) BEFORE throwing, wrote NO `ocr-throughput.json`,
and the launcher propagated exit status 1. This is an expected-failure
test of the diagnostic path — it is NOT a reproduction of the original
lost failure and must not be read as such.

## Full native test suite

After rebasing onto the manager tip, the whole package suite ran green:

```
swift test -c release --disable-sandbox --disable-swift-testing -j 4
Executed 456 tests, with 6 tests skipped and 0 failures (0 unexpected)
```

The 6 skips are the opt-in heavy / perf benchmarks, each gated behind
its own environment flag (both E12 heavy tests, the E10 and E11
retrieval benchmarks, and two `VEC_PERF_TESTS` sweeps). The E12
always-on guards (`ImageOCRBenchmarkManifestTests`, 12 tests) ran and
passed inside the suite. Nothing in the E12 scope failed. Verbatim
output: [`runs/20260907-fullsuite/`](runs/20260907-fullsuite/).

## Rebase / measured-provenance mapping

Each archive records the `git_head` that was current when its benchmark
RAN — a pre-rebase commit. The branch was later rebased ONCE onto the
manager's recovery-handoff tip; the raw archives are intentionally NOT
restamped (rewriting measured provenance would be falsification). The
recorded commits map to their rebased equivalents as:

| measured run | recorded `git_head` (as run) | rebased equivalent |
|---|---|---|
| retrieval | `49b2ae8` | `b98a3da` |
| throughput (synthetic 18) | `9d39893` | `8bb14f7` |
| throughput (real 153) | `69dec5c` | `f7648b1` |

**Source-tree equivalence is confirmed:** across every original and
rebased commit above, the `Sources/` subtree hashes to
`1a413ff0a38f2557422992776c236f3120d529c1` and `Tests/` to
`3367adfc7dd3d606167ee0981242b25716cdcfbf` — byte-for-byte identical, so
the rebase changed no measurement input (engine or harness source). The
only tree difference the rebase introduced is the manager's
documentation (`plan.md`, `progress.md`), which is not an input to
either benchmark. (These subtree hashes describe the measured commits;
the later MiB-label and launcher-watchdog commits change `Tests/` and the
launcher only, never a committed archive.)

## Units correction (formatting only)

The harness byte formatter divided RSS by 1024² but labeled the result
"MB"; the correct unit is **MiB**. This is a label-only defect — no byte
value, timing, or rate changed. The raw byte counts in each run's JSON
are authoritative. The formatter and the generated summaries are now
labeled MiB; the verbatim `execution-log.txt` files retain the original
"MB" as-run. Full detail: [`runs/UNITS-CORRECTION.md`](runs/UNITS-CORRECTION.md).

## Standing caveats (unchanged from the plan)

- The synthetic subset is an easy OCR + retrieval task and inflates the
  retrieval aggregate; the real subset is a best-case, hand-picked
  sample, not representative of the thumbnail/photo-heavy real corpus.
- The raw baseline is an empty index; the raw-vs-OCR comparison is
  one-sided by construction.
- Query targets are what each image SAYS; no image assertion was
  fact-checked externally.
- RSS is a coarse, process-wide proxy sampled every ~20 ms, not an
  OCR-only allocation figure, and is not reset between passes.
- Job counts run sequentially in one process, so later job counts
  benefit from Vision/ANE warmup — a sequential-order bias.
- An accuracy improvement was a hypothesis, not a completion
  requirement. The default extraction mode stays `raw`.

## Success criteria (from the plan)

- [x] Freeze image bytes + query labels + manifest sha256 before any
  ranking; sample/rubric/harness/scorer committed first.
- [x] Retrieval uses the real scanner/pipeline; the raw baseline is a
  genuinely empty index.
- [x] Throughput records real timing, sampled/peak RSS, cold and warm
  cache statistics at 1/4/8 jobs, and a 325k extrapolation.
- [x] Independent Python scorer recomputes ranks and rejects a
  partial/corrupt/faked archive; its 8 regression tests pass.
- [x] Always-on Swift guards pass (12 tests, no model, no Vision).
- [x] Run both benchmarks on the native runtime; archive provenance and
  results; TH1 evidence-retention validated.
- [x] Write this report with plain measured results and every caveat.

## Archive index

| run | path | key result |
|---|---|---|
| retrieval | `runs/20260907-retrieval/` | image-ocr-v1 14/15 rank1, MRR 0.967; raw 0/15 |
| throughput (synthetic 18) | `runs/20260907-throughput-frozen18/` | cold 0.68–0.80 img/s → 325k ~112–133 h |
| throughput (real 153) | `runs/20260907-throughput-real153/` | cold 6.85–11.27 img/s → 325k ~8–13 h (conditional) |
| TH1 fault-injection | `runs/20260907-th1-faultcheck/` | diagnostic written before throw, exit 1 |

Each run directory holds the machine-authoritative JSON, the generated
summary, the verbatim `execution-log.txt`, and (retrieval) the
independent scorer output.
