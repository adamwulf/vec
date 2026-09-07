# E13 reader validation — pre-integration report

The standalone PDF reader is implemented and passes its native macOS test
suite. Retrieval comparison is intentionally absent: `pdf-ocr-v1` has not yet
been wired through the shared extraction mode, scanner, pipeline, and CLI, so
ranking either arm now would not test the production path.

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
regression/caching evidence only. No retrieval-quality claim will be made until
the frozen rubric is run through the integrated production path and scored by
the independent scorer.
