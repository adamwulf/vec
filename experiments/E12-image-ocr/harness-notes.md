# E12 harness notes

Operator notes for the E12 image-OCR harness
(`Tests/VecKitTests/ImageOCRBenchmarkTests.swift`). This file documents HOW
to run it and WHY it is built this way. It is not the experiment plan or
report — the manager owns `plan.md` and any `report.md`.

The harness reuses the E10/E11 discipline (freeze-before-ranking, preflight,
strict partial-failure handling, coalesced search, ordinal passage audit,
sample-manifest anti-drift gate, drift-FAILS-not-warns) and adds two
image-specific pieces: a production-path raw-vs-OCR retrieval comparison and
a direct `ImageOCRCache` throughput/cold-warm/RSS benchmark. No `Sources/`
code is changed by this harness.

## Two benchmarks

Both are HEAVY and opt-in behind `VEC_E12_BENCHMARK=1`; a normal
`swift test` skips them and runs only the cheap always-on guards.

### 1. Retrieval — `testImageOCRRetrievalBenchmark`

One corpus snapshot, one embedder (`e5-base@1200/0`), one geometry, two
`TextExtractor` arms, all through the PRODUCTION path:

| arm            | scanner mode   | what it indexes                                   |
|----------------|----------------|---------------------------------------------------|
| `raw`          | `.raw`         | NOTHING — the production `FileScanner(.raw)` excludes every image |
| `image-ocr-v1` | `.imageOCRV1`  | every image, OCR'd by the pipeline via `TextExtractor(ocrCacheDirectory:)` |

The raw arm is EXPECTED to index zero images. That is the honest baseline —
image text is unreachable without OCR — not a bug, and it is never faked:
the harness runs the real `FileScanner(directory:textExtraction:)` and lets
it return an empty set. A text-less image (e.g. the app-icon distractor)
OCRs to blank → zero chunks → the pipeline records `.skippedUnreadable`;
the harness counts that as a legitimate BLANK, not a failure. To make sure a
blank is never confused with a failed read, the harness then asserts that
`VectorDatabase.allIndexedFiles()` contains EVERY scanned image (a blank
image is still `markFileIndexed`, but a transient read error is NOT, so it
would be missing) and contains no file that was not scanned; the per-file
re-extraction loop additionally re-opens every scanned file and THROWS on a
genuine read error. Both a genuine failure and a contaminated DB abort.

Documents embed through the batch pipeline; queries through
`E5BaseEmbedder.embedQuery`. Only the extraction mode differs; no inference
change.

### 2. Throughput / cold-warm cache — `testImageOCRThroughputBenchmark`

Drives `ImageOCRCache` directly (real `ImageOCR` recognizer) so it can
report authoritative statistics and needs NO embedder/model. The corpus is
FROZEN into a sha256-pinned snapshot before any timing, and every pass OCRs
that snapshot, so cold and warm (and every job count) read byte-identical
inputs, recorded in the archive's `frozen_images`. For each job count in the
sweep (default 1, 4, 8):

- **cold**: a fresh cache directory + a fresh `ImageOCRCache` instance; every
  image is OCR'd (for N distinct-byte images: misses = N, ocrCalls = N,
  hits = 0);
- **warm**: the SAME directory read by a FRESH `ImageOCRCache` instance whose
  resident LRU starts empty, so every result is served from the on-disk
  sidecar (hits = N, misses = 0, ocrCalls = 0). This measures ONLY the
  disk-cache-hit path. It is NOT a fresh OS process: process RSS and Vision's
  own internal caches PERSIST across the cold pass, the warm pass, and every
  job count in this single test process, so warm RSS is not a cold-start
  figure.

Concurrency is driven in the harness: each image's `recognizeText(in:)` (a
sync throwing call) runs on a concurrent `DispatchQueue` bounded by a
`DispatchSemaphore(value: jobs)`. Each call's success/failure is tracked;
ANY recognizer error THROWS (a blank OCR result is a success), so a swallowed
error can never inflate the rate — attempted/succeeded/failed are archived.
Job counts run SEQUENTIALLY (1, then 4, then 8) in one process, so later
iterations benefit from Vision/ANE warmup and OS caches primed by earlier
ones (a sequential-order bias), and with the tiny default corpus (18 frozen
images) the per-pass rate is noisy — point `VEC_E12_OCR_CORPUS_DIRECTORY` at
a larger frozen corpus for a stabler estimate. Each pass records wall-clock,
images/second (over succeeded), the cache statistics, RSS
(before/peak/after/mean, peak = max(before, sampledPeak, after)), and a
LINEAR extrapolation to a target corpus (default 325,000 images).

## Environment contract

| variable                      | benchmark   | meaning |
|-------------------------------|-------------|---------|
| `VEC_E12_BENCHMARK`           | both        | set to `1` to enable; otherwise both heavy tests skip. |
| `VEC_E12_MODEL_DIRECTORY`     | retrieval   | absolute path to the pinned local `e5-base-v2` bundle. Default `/private/tmp/vec-e10-model/f52bf8ec8c7124536f0efb74aca902b2995e5bcd`. FAILS (never downloads) if absent. |
| `VEC_E12_MODEL_REVISION`      | retrieval   | revision string stamped into provenance (default: the model dir leaf). |
| `VEC_E12_CORPUS_DIRECTORY`    | retrieval   | corpus root (default `experiments/E12-image-ocr/sample`); must hold the images and `manifest.json`. |
| `VEC_E12_CONCURRENCY`         | retrieval   | pipeline embed concurrency (default 8). |
| `VEC_E12_OCR_CONCURRENCY`     | retrieval   | pipeline OCR concurrency (default 4); affects extract-stage speed only, not correctness. |
| `VEC_E12_OUTPUT_DIRECTORY`    | retrieval   | archive dir (default: a fresh temp dir); refuses a non-empty dir. |
| `VEC_E12_MANIFEST`            | retrieval   | override the query manifest path. |
| `VEC_E12_OCR_CORPUS_DIRECTORY`| throughput  | image corpus for the OCR sweep (default: the frozen sample). Point it at a LARGER real corpus (e.g. `/tmp/LinksDatabase`) for a stabler 325k extrapolation. |
| `VEC_E12_OCR_JOBS`            | throughput  | comma-separated job counts (default `1,4,8`). |
| `VEC_E12_TARGET_COUNT`        | throughput  | extrapolation target (default `325000`). |
| `VEC_E12_OCR_OUTPUT_DIRECTORY`| throughput  | archive dir for the throughput run. |
| `VEC_E12_SCRATCH_DIRECTORY`   | both        | scratch root for the snapshot + throwaway DBs / cache dirs (default: a fresh temp dir). |

The model default (`~/Documents/huggingface`) is outside the harness's
writable roots, so the retrieval benchmark never downloads: it loads the
pinned bundle via the internal `E5BaseEmbedder(modelDirectory:)` seam and
FAILS if the directory is missing.

## Anti-drift gates (before any ranking)

1. The frozen snapshot copies ONLY image files (`ImageOCR.supportedExtensions`)
   into scratch — `manifest.json` and any non-image file are excluded.
2. `sample/manifest.json` is REQUIRED; its `{path,bytes,sha256}` set must
   EXACTLY equal the frozen snapshot (and, when present, `real_files +
   synthetic_files` must sum to the count). A copy is archived and its sha256
   is bound into provenance + `run_identity`.
3. The frozen image count must equal `corpus.expected_image_files` (18) — a
   mismatch FAILS (the sample is a fixed committed corpus; E10-style warnings
   do not apply).

## RSS / memory-measurement scope (state it in the report)

RSS is process-wide (`mach_task_basic_info` for the whole test process,
including Vision's own caches and any resident OCR-cache entries and, in the
retrieval benchmark, the loaded embedder). The throughput sampler runs on a
background thread at a fixed 20 ms interval, so a spike shorter than the
interval can be missed; the reported peak is `max(before, sampledPeak,
after)`. Crucially, RSS is NOT reset between the cold pass, the warm pass, or
successive job counts — they share one process, so cross-pass RSS deltas are
not independent measurements. These are coarse proxies, NOT OCR-only
allocation figures. The retrieval benchmark records only before/after
indexing RSS (not OCR-isolated); it also snapshots the OCR-cache counters at
the end of indexing (before the audit re-extraction adds hits) and again
after the audit, both in the arm summary.

## Large-image downscale caveat

`ImageOCR` downscales any image whose largest side exceeds
`maxPixelDimension` (4096) before recognition, so small text in a very large
image can be lost. The throughput number measures speed, not that fidelity
loss; the report must acknowledge it.

## Running

```bash
# Retrieval (needs the pinned E5 model):
VEC_E12_BENCHMARK=1 \
VEC_E12_MODEL_DIRECTORY=/private/tmp/vec-e10-model/<rev> \
VEC_E12_OUTPUT_DIRECTORY="$PWD/experiments/E12-image-ocr/runs/$(date +%Y%m%d-%H%M%S)-retrieval" \
swift test --disable-sandbox --disable-swift-testing -c release -j 4 \
  --filter VecKitTests.ImageOCRRetrievalExperimentTests/testImageOCRRetrievalBenchmark

# Throughput (no model; point at a large real corpus for a stabler estimate):
VEC_E12_BENCHMARK=1 \
VEC_E12_OCR_CORPUS_DIRECTORY=/tmp/LinksDatabase \
VEC_E12_OCR_OUTPUT_DIRECTORY="$PWD/experiments/E12-image-ocr/runs/$(date +%Y%m%d-%H%M%S)-throughput" \
swift test --disable-sandbox --disable-swift-testing -c release -j 4 \
  --filter VecKitTests.ImageOCRRetrievalExperimentTests/testImageOCRThroughputBenchmark

# Cheap always-on guards (no gate, model, corpus, or Vision):
swift test --disable-sandbox --disable-swift-testing --filter ImageOCRBenchmarkManifestTests
```

`--disable-sandbox` matches the parent dependency-resolve flag;
`--disable-swift-testing` avoids the release-runner `--test-bundle-path`
issue (this benchmark is XCTest-only) and makes the heavy run faster.

**Do not run the benchmarks until the engine (`ImageOCR` +
`TextExtractor(ocrCacheDirectory:)`) and pipeline (`ocrConcurrency`) have
merged into `agent/image-ocr` and this branch is rebased onto it** — until
then the harness references API that does not yet exist on this branch and
will not compile. The frozen inputs and cheap tests are committed first,
before any ranking, on purpose.

## Independent scorer

`scripts/score-image-rubric.py <run-dir>` recomputes file rank from the
archived groups (stable best_score-descending), rejects a partial, corrupt,
inconsistent, or FAKED archive (incl. a non-empty raw baseline or a
fingerprint mismatch), and reports aggregate plus REAL-vs-SYNTHETIC subset
metrics. It is self-contained (no cross-experiment import).
`scripts/test-score-image-rubric.py` is its regression suite (missing query,
target-rank calculation, invalid ordering, stored-vs-derived mismatch,
fingerprint corruption, faked baseline).
