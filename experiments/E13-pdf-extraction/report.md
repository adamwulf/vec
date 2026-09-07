# E13 PDF extraction validation

The opt-in `pdf-ocr-v1` path is implemented through the production scanner,
extractor, indexing pipeline, and CLI. On the frozen seven-PDF synthetic
sample, it recovered all raster-only evidence while retaining the native-only
results. The default `raw` arm remained embedded-text-only.

## Production pipeline before/after

The native release run used the real pipeline
(`FileScanner` → `TextExtractor` → `IndexingPipeline` → `VectorDatabase`) and
the same pinned local E5 model in both arms. The independent scorer read the
frozen rubric and archived query result groups after both arms completed.

| Metric | `raw` before | `pdf-ocr-v1` after |
|---|---:|---:|
| Target file rank 1 | 3/7 (42.9%) | 7/7 (100%) |
| Target file top 3 | 5/7 (71.4%) | 7/7 (100%) |
| Mean reciprocal rank | 0.571 | 1.000 |
| Correct target page present | 4/7 (57.1%) | 7/7 (100%) |
| Required passage present | 3/7 (42.9%) | 7/7 (100%) |
| PDFs indexed / blank / failed | 4 / 3 / 0 | 6 / 1 / 0 |
| Chunks | 8 | 13 |
| Index wall time | 0.542 s | 1.932 s |

The OCR arm was 3.57× the indexing wall time on this tiny sample (+1.390 s).
It made eight Vision calls—one per PDF page, including the blank page—and
recorded eight misses during indexing. A subsequent audit extraction produced
eight cache hits and zero additional OCR calls. The image-only and rotated/
cropped PDFs changed from blank to indexed; the intentionally blank PDF stayed
blank. The mixed page's native and raster queries both ranked first, the raster
evidence on page 2 of the multipage fixture carried page 2 provenance, and the
duplicate-overlap fixture retained one authoritative passage rather than an
OCR duplicate.

The tracked-clean native run at `6b30005` is archived under
[`runs/20260907-native-retrieval-final/`](runs/20260907-native-retrieval-final/),
including generated PDFs and hashes, environment/model provenance, the exact
command and complete test/scorer logs, per-arm summaries, and every query
result. The scorer initially treated retrieval of the correct file from a
wrong page as an invalid archive; that was corrected to report a correct-page
miss while still rejecting every PDF-page match without integer provenance.
The manifest's `git_dirty: true` reflects only the harness-created, untracked
`.agents/` directory; the runner verified zero modified or staged tracked files.

## Native tests

At code-equivalent native tip `773f969`, vec-builder ran:

```text
swift test --disable-sandbox --filter PDFOCRReaderTests
```

Result: 12 tests discovered, 11 executed, one opt-in benchmark skipped, zero
failures. This included all three real Vision tests:

- mixed native/image, image-only, native-only, blank, and multipage provenance;
- native+raster duplicate suppression;
- reopened 90-degree rotation and non-default crop-box assertions followed by
  real OCR of the distinct rotated raster phrase.

It also included deterministic tests for disk/resident cache reuse, PDF-content
and render-setting key invalidation, blank caching, retry after failure,
geometric interleaving, sequence-safe dedup, reader-wide resource bounds, and
same-page single-flight. The unchanged E12 PNG positive control also passed in
the native runtime. By contrast, this Codex session could not initialize
Vision; the matching E12 control failure is retained separately under
[`runs/20260907-codex-vision-blocked/`](runs/20260907-codex-vision-blocked/).

## Bounded reader cost

The opt-in release benchmark ran from clean native worktree HEAD `fe2c348`.
Its PDF reader/cache/benchmark files are byte-identical to rebased commit
`142a73e` (verified with `git diff --exit-code`); later tip `773f969` adds only
the deterministic single-flight test. The benchmark rendered one frozen
six-page synthetic PDF at 144 dpi with a 4096-pixel longest-edge cap and one
maximum concurrent page operation. It processed the exact same 65,875-byte PDF
(`sha256 56efe94ff3e4bac68973e3f5abba2741bc4b79adf88a73eeb328db68a0c3ae8f`)
on both passes.

| Pass | Wall time | Throughput | Cache hits | Misses | OCR calls | Peak process RSS |
|---|---:|---:|---:|---:|---:|---:|
| Cold | 1.236 s | 4.85 pages/s | 0 | 6 | 6 | 159,596,544 B (152.2 MiB) |
| Warm | 0.00210 s | 2,863.85 pages/s | 6 | 0 | 0 | 139,018,240 B (132.6 MiB) |

The meaningful cache result is categorical: the fresh warm reader loaded all
six page sidecars and made zero Vision calls. The warm rate is dominated by
timer granularity and this tiny synthetic sample; it is not a credible corpus
throughput estimate. RSS is process-wide sampled RSS, not isolated renderer
allocation. The cold peak includes XCTest, PDFKit, Vision, and framework/model
initialization. Full JSON and the exact command are archived in
[`runs/20260907-native-reader/`](runs/20260907-native-reader/).

## Limitations

All PDF fixtures are synthetic, clean, high-contrast, horizontal English.
They do not represent photographed documents, handwriting, damaged scans,
compression artifacts, complex tables/forms, multicolumn papers, or non-Latin
scripts. The six-page benchmark is deliberately bounded and is useful for
regression/caching evidence only. The seven-query retrieval result is a
correctness check, not an accuracy estimate for a real corpus. Its wall times
are same-process, single-run measurements and include different work by design;
they are not statistically stable performance estimates. The arm-summary RSS
snapshots include XCTest, model/framework state, and prior work, so the bounded
reader benchmark above is the defensible memory measurement.
