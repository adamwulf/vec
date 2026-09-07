# TH1 fault-injection validation (NOT a measurement)

This directory is **not** a throughput measurement. It is a deliberate
fault-injection that validates reviewer TH1's requirement: on a genuine
recognizer failure the throughput harness must retain the failing
filenames/counts in a partial per-pass diagnostic **before** it throws,
and it must never fold a failing pass into a published rate.

## What was run

A two-file corpus was OCR'd through `testImageOCRThroughputBenchmark`
(via `scripts/run-benchmark.swift throughput`):

- `valid.png` — a copy of a known-decodable synthetic sample image.
- `corrupt.png` — a text file with a `.png` extension, so ImageIO
  cannot decode it and `ImageOCR` throws `ImageOCRError.undecodable`.

## Result (expected FAILURE)

The `jobs=1 cold` pass logged:

```
[e12-ocr] jobs=1 cold FAILED: 1/2 recognizer failure(s); partial
diagnostic saved to failed-pass-1-cold.json. This pass is INVALID for
extrapolation.
```

then threw `E12HarnessError` naming `corrupt.png: undecodable(…)`, the
XCTest reported 1 failure, and the launcher propagated exit status 1.
No `ocr-throughput.json` was written — a failing pass produces no
measurement archive, only the diagnostic.

`failed-pass-1-cold.json` (committed here) shows `images_attempted: 2`,
`images_succeeded: 1`, `images_failed: 1`, and the failing file with its
error string, plus the cache/RSS readings observed up to the failure.
The absolute path inside the `error` field points at the ephemeral
scratch snapshot the harness froze for the run.

## Relationship to the real runs

The real measurement runs (`20260907-throughput-frozen18`,
`20260907-throughput-real153`) had **zero** recognizer failures, so this
path did not trigger there. This artifact exists only to prove the path
works.
