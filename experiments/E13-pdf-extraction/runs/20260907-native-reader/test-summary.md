# Native PDF reader validation

- Host: macOS 26.6.2 (Build 25G83), 10 active processors.
- Native verification tip: `773f969`.
- Benchmark tip: clean worktree at `fe2c348`; reader/cache/benchmark files are
  byte-identical to rebased commit `142a73e`.
- Command: `swift test --disable-sandbox --filter PDFOCRReaderTests`.
- Result: 12 tests discovered; 11 executed; the opt-in benchmark skipped;
  zero failures.
- Real Vision fixture timings reported by vec-builder:
  - native/raster duplicate: 0.475 s;
  - crop plus rotation: 0.112 s;
  - native/image/mixed/blank/multipage: 0.784 s.
- Deterministic single-flight test: 0.059 s.
- Unchanged E12 control `ImageOCRTests/testRenderedPNGBaselineRecognizesWords`
  also passed in the same native environment.

No OCR test was silently skipped. The single skipped test was the separately
invoked opt-in throughput benchmark.
