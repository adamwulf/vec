# E12 — Opt-in image OCR before embedding

Status: sample, rubric, harness, and scorer FROZEN and committed
(2026-09-07). Rankings are NOT yet run — they wait on the engine
(`ImageOCR` + `TextExtractor(ocrCacheDirectory:)`) and pipeline
(`IndexingPipeline(ocrConcurrency:)`) landing on `agent/image-ocr` and
compiling, after which this worker rebases and runs the two benchmarks on
its native runtime. This file records the pre-run design; a `report.md`
with measured results and limitations follows the run.

## Question

Does OCR-indexing raster images (via the opt-in `image-ocr-v1` extraction
mode) make the text INSIDE images retrievable, and what does that OCR cost
in wall-clock and memory at 1/4/8 concurrent jobs, cold vs warm cache? This
is a general image-format capability with the existing default embedder. It
recognizes no particular app, screenshot tool, or directory layout.

## Fixed scope

- Existing default embedder and character splitter; no new models,
  reranking, summaries, or keyword retrieval. Profile pinned at
  `e5-base@1200/0` (real `intfloat/e5-base-v2`), the same local bundle
  E10/E11 used; no network.
- Raw extraction stays the default and, per the engine change, the raw
  scanner indexes NO images. Image OCR is opt-in via `image-ocr-v1` (and
  its canonical `markdown-v1+…` / `vtt-v1+…` combinations). This worker
  owns only the E12 experiment tree and
  `Tests/VecKitTests/ImageOCRBenchmarkTests.swift`; it changes no
  `Sources/`, `Package.swift`, `README.md`, or the root `plan.md`.
- Two measurements, both opt-in XCTests behind `VEC_E12_BENCHMARK=1`:
  1. **Retrieval** (`testImageOCRRetrievalBenchmark`) — the PRODUCTION path
     (real `FileScanner(textExtraction:)` → real `IndexingPipeline` → real
     `TextExtractor(ocrCacheDirectory:)`), two arms over one frozen image
     snapshot:
     - `raw` — the production scanner excludes every image, so the index is
       EMPTY (the honest baseline: image text is unreachable without OCR);
     - `image-ocr-v1` — every image is discovered, OCR'd, and indexed.
     Only the extraction mode differs; no inference change.
  2. **Throughput / cost** (`testImageOCRThroughputBenchmark`) — drives
     `ImageOCRCache` (real `ImageOCR` recognizer) at 1/4/8 concurrent jobs,
     cold then warm, recording authoritative `ImageOCRCacheStatistics`
     (hits/misses/ocrCalls), wall-clock, sampled + peak RSS, and a linear
     extrapolation to a 325k-image corpus.

## The frozen sample (18 images)

`sample/manifest.json` pins each image's sha256; `freeze-sample.py --check`
re-verifies every hash and the sampling invariants.

- **6 real images** copied from the user's local `/tmp/LinksDatabase` link
  archive (per-file `source_path` recorded):
  - 4 text-bearing TARGETS: an FBI Jan-6 charges bar chart
    (`fbi-jan6-charges-chart.png`, "1,575 total charges through Jan. 2025");
    an operational-transformation sequence diagram
    (`ot-sequence-diagram.png`, Client A / Server / Client B, Insert /
    Delete, "abcd" → "xad"); a fractional-indexing steps diagram
    (`fractional-index-steps.png`, "Insert Obj2 between Obj3 & Obj4"); and a
    Minecraft "ATMOSPHERE / BDOUBLEO" thumbnail
    (`minecraft-atmosphere-thumbnail.jpg`).
  - 2 DISTRACTORS: a dense code-editor syntax showcase
    (`code-editor-showcase.png`) and a near-text-less app icon
    (`app-icon-crystal.png`), which is EXPECTED to OCR to blank.
- **12 synthetic CoreText-rendered images** (`generate-synthetic-images.swift`):
  11 distinct-topic TARGETS (sourdough, Titan, espresso, Roman aqueduct,
  waggle dance, Li-ion runaway, coral bleaching, tea ceremony, Everest,
  Fermat, Antikythera) and 1 unlabeled distractor (knitting gauge). The
  committed PNG bytes are authoritative; the generator is a reproduction
  aid only (PNG bytes are not guaranteed bit-identical across macOS / font
  versions).

`queries/rubric-queries.json` freezes 15 answered queries (4 real-target +
11 synthetic-target), each with advisory passage criteria drawn from what
each image SAYS. No query wording or label changes after ranking.

### Selection bias (documented on purpose)

Real targets were hand-picked for legible, text-dominant, mutually-distinct
content. That is deliberately unlike the real image corpus, which is mostly
thumbnails, photos, and icons with little or no text. So:
- the synthetic subset is an easy OCR + retrieval task and inflates the
  aggregate;
- the real subset is a best-case, not a representative, sample;
- the raw baseline is an empty index, so a raw-vs-OCR file-rank comparison
  is one-sided by construction — it quantifies that image text is invisible
  without OCR, nothing more.

## Success criteria

- [x] Freeze image bytes + query labels + manifest sha256 BEFORE any
  ranking; commit sample, rubric, harness, and scorer first.
- [x] Retrieval benchmark uses the REAL scanner/pipeline; the raw baseline
  is a genuinely empty index (never faked).
- [x] Throughput benchmark records real timing, sampled/peak RSS, cold and
  warm cache statistics at 1/4/8 jobs, and a 325k extrapolation.
- [x] Independent Python scorer recomputes ranks from archived groups,
  rejects partial/corrupt/faked archives, and reports real-vs-synthetic
  subsets; its regression tests pass.
- [x] Always-on Swift guards (no model, no Vision) cover manifest
  preflight, the sample-manifest anti-drift verifier, the `ImageOCR`
  extension set, and OCR-cache hit/miss accounting via an injected fake.
- [ ] Run both benchmarks on the native runtime after the engine + pipeline
  merge; archive provenance and results; obtain independent review.
- [ ] Write `report.md` with plain measured results and every caveat.

An accuracy improvement is a hypothesis, not a completion requirement. The
default stays `raw`.

## Provenance and archive layout

Each retrieval run archives `frozen-input-manifest.json` (corpus + model +
manifest hashes, `run_identity`, build id incl. git HEAD / dirty /
`Package.resolved` sha256, OS / cores / host, resolved settings),
`sample-manifest.json` (byte copy), `execution-command.txt` (exact command
+ resolved provenance + memory-measurement scope), `comparison.json`,
`summary.md`, and per-arm `arm-summary.json` + per-query `<arm>/q*.json`.
Each throughput run archives `ocr-throughput.json`, `ocr-throughput.md`, and
`execution-command.txt`. Runs live under `runs/<timestamp>/`.

See [`harness-notes.md`](harness-notes.md) for how to run and why the
harness is built the way it is.
