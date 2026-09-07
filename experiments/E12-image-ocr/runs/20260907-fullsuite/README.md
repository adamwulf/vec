# Full native test suite (RELEASE)

Verbatim output of the whole package test suite, run after rebasing onto
the manager tip, to confirm the E12 harness changes broke nothing.

Command (no `VEC_E12_*` set, so the heavy benchmarks skip):

```
swift test -c release --disable-sandbox --disable-swift-testing -j 4
```

## Result

```
Executed 456 tests, with 6 tests skipped and 0 failures (0 unexpected)
in 298.617 seconds
```

**0 failures.** The 6 skips are the opt-in heavy / perf benchmarks, each
gated behind its own environment flag (never run in a plain suite):

- `ImageOCRRetrievalExperimentTests.testImageOCRRetrievalBenchmark` (VEC_E12_BENCHMARK)
- `ImageOCRRetrievalExperimentTests.testImageOCRThroughputBenchmark` (VEC_E12_BENCHMARK)
- `MarkdownRetrievalExperimentTests.testMarkdownExtractionRetrievalBenchmark` (VEC_E10_BENCHMARK)
- `VTTRetrievalExperimentTests.testVTTExtractionRetrievalBenchmark` (VEC_E11_BENCHMARK)
- `ConcurrencySweepTests.testConcurrencySweep_syntheticCorpus` (VEC_PERF_TESTS)
- `ThreeStagePipelineTests.testThreeStage_hugeFirstFile` (VEC_PERF_TESTS)

The E12 always-on guards (`ImageOCRBenchmarkManifestTests`, 12 tests)
ran and passed as part of this suite. Nothing in the E12 scope failed.

See `execution-log.txt` for the full run.
