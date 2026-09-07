# E13 — Opt-in mixed-content PDF extraction

Status: READER IMPLEMENTED AND NATIVELY VALIDATED; SAMPLE AND RUBRIC FROZEN
BEFORE RANKING. Shared `pdf-ocr-v1` mode/scanner/pipeline integration is still
pending. No retrieval ranks have been observed or recorded. Reader-only native
test and cost results are recorded in [`report.md`](report.md).

## Question

Can an opt-in PDF extraction mode retain authoritative embedded text while
also making raster-only text on image-only and mixed pages retrievable, without
duplicating text that Vision recognizes from the PDF text layer?

## Fixed design

- `raw` retains the existing embedded-text-only PDF behavior and remains the
  default. `pdf-ocr-v1` is the only arm that renders pages for Vision.
- PDFKit's embedded text is authoritative. Every page is OCR'd, including a
  page that already has native text. Exact normalized token sequences suppress
  OCR copies; uncertain or distinct OCR text is retained.
- Native lines and novel OCR observations are interleaved using crop/rotation-
  aware normalized page geometry. When PDFKit character bounds cannot fully
  reconstruct native text, the lossless fallback is native text first followed
  by proven-novel OCR additions.
- Rasterization is page-at-a-time inside an autorelease pool. The default
  reader-wide page-operation limit is one, and the longest edge is capped at
  4096 pixels at a requested 144 dpi.
- Page sidecars live under the DB cache directory's `pdf-ocr-cache/`. Keys bind
  PDF SHA-256, PDF extraction version, Vision request revision, page number,
  dpi, and pixel cap. Blank successes are cached; failures are not.

## Frozen synthetic sample specification

The test-time generator in `PDFOCRReaderTests` defines seven logical fixtures:

1. native-only embedded text;
2. image-only raster text;
3. mixed native+raster text on the same page, with distinct target words;
4. blank PDF;
5. multipage PDF with page-specific targets;
6. non-default crop box plus 90-degree page rotation;
7. the same passage present as native text and raster text.

The retrieval harness must render these fixtures to a scratch snapshot, hash
the actual PDF bytes, and write `frozen-input-manifest.json` **before** the
first arm or query runs. Generated PDF bytes are not committed because CoreText
font/PDF serialization can vary by OS; the archived run bytes and hashes are
authoritative. The fixture semantics and query labels are frozen in
[`queries/rubric-queries.json`](queries/rubric-queries.json) before ranking.

## Synthetic limitations

This is deliberately a modest correctness-oriented sample. Its text is clean,
high-contrast, horizontal English rendered with CoreText. It does not estimate
accuracy on photographed documents, handwriting, damaged scans, compression,
multicolumn academic papers, tables, forms, or non-Latin scripts. Rotation and
crop coverage proves geometry plumbing for one controlled case, not arbitrary
PDF layout quality. Rankings must be reported as synthetic-only and must not be
generalized to a real corpus.

## Frozen retrieval rubric

- Arms: `raw` and `pdf-ocr-v1`; only extraction mode differs.
- Profile: the same pinned local `e5-base@1200/0` used by E10-E12; no network.
- Seven answered queries cover native-only, image-only, both halves of a mixed
  page, multipage provenance, rotated/cropped raster text, and duplicate
  overlap. Blank behavior is a non-query completeness assertion.
- Primary metric: target file rank (rank-1, top-3, MRR). Page provenance and
  passage criteria are mandatory integrity gates, not a substitute for rank.
- [`scripts/score-pdf-rubric.py`](scripts/score-pdf-rubric.py) independently
  derives ranks from archived scores and rejects partial, drifted, non-finite,
  incorrectly ordered, or page-provenance-free archives.

## Required archive

Each final run directory must contain:

- the frozen PDF bytes and `frozen-input-manifest.json` (path, bytes, SHA-256);
- an exact copy of the query manifest and its SHA-256;
- build provenance (git HEAD/dirty state, `Package.resolved` SHA-256, Swift,
  OS, host, core count) and resolved render/OCR/profile settings;
- exact commands and complete logs;
- per-arm summaries and per-query result groups;
- independently generated score output;
- cold/warm reader throughput with wall time, sampled process RSS, and
  `PDFOCRCacheStatistics` on the bounded six-page sample.

## Success criteria

- [x] PDF-specific reader, renderer, geometry merge, dedup, and page sidecar
  cache implemented without changing E12 ImageOCR/cache files.
- [x] Always-on deterministic tests cover cache hits, content/render keying,
  blank caching, failure retry, page-operation bound, ordering, and dedup.
- [x] Real Vision tests render native/image/mixed/blank/multipage/rotation-crop/
  duplicate fixtures and assert words without availability skips.
- [x] Sample semantics, query labels, and independent scorer frozen before any
  ranking.
- [ ] Shared mode/scanner/extractor/pipeline/CLI wiring merged by the manager.
- [x] Native runtime: real Vision tests pass; bounded cold/warm throughput,
  RSS, and cache counters archived in
  [`runs/20260907-native-reader/`](runs/20260907-native-reader/).
- [ ] After integration only: run both retrieval arms, independently score,
  document results/caveats, and complete external review.
