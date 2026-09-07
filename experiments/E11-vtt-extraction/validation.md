# E11 validation and review

## Automated validation

The final feature passed all 24 focused tests: 8 CLI extraction-mode tests,
5 extraction/scanner tests, and 11 normalizer tests. All 40 profile tests
also pass. Manager post-merge validation covered Markdown, WebVTT, CLI modes
and profiles: 120 tests, 1 expected opt-in benchmark skip, 0 failures.

```bash
swift test --disable-sandbox --disable-swift-testing -j 4 --filter 'VTT|Markdown|TextExtractionModeTests|IndexingProfileTests'
```

Full suites ran on clean main and the final integrated feature with real
model inference available. Both worktrees were clean before and after
testing; neither run modified production code or tests.

| Revision | Total tests | Passed | Skipped | Failed cases | Failed assertions |
| -------- | ----------- | ------ | ------- | ------------ | ----------------- |
| Clean main `c885586` | 354 | 349 | 3 | 2 | 6 |
| Feature `cf6d271` | 372 | 368 | 3 | 1 | 5 |

A manager comparison of every serial XCTest outcome confirmed that **all
349 tests passing on main also pass on the feature branch**, all 18 added
tests pass, and no main test is missing. Three expanded CLI tests were
renamed; their explicit old-to-new mappings are recorded in
[test-comparison.json](test-comparison.json). The three skipped tests are
unchanged: `ConcurrencySweepTests.testConcurrencySweep_syntheticCorpus`,
`MarkdownRetrievalExperimentTests.testMarkdownExtractionRetrievalBenchmark`,
and `ThreeStagePipelineTests.testThreeStage_hugeFirstFile`. They require
the existing opt-in performance/benchmark environment flags.

## Pre-existing baseline failures

Clean main commit: `c885586e206795982b2766ad3ccd30242c1ddd24`
(`Merge agent vector-db work`). Reviewer `agent-0222ace2` checked out
this commit detached in its own worktree and verified a clean status
before and after running this exact command:

```bash
swift test --disable-sandbox --disable-swift-testing -j 4 --xunit-output /tmp/vtt-handler-main-tests.xml > /tmp/vtt-handler-main-tests.log 2>&1
```

The run exited 1 after 270.143 seconds of tests. The exact failing methods:

- `VecKitTests.IndexingProfileTests.testFactoryDefaultAliasIsKnown`:
  one assertion expected `bge-base`, although the shipped factory
  already defaults to `e5-base`. E11 corrects only the stale assertion
  in commit `e135671`; it does not change the factory.
- `VecKitTests.TrademarkTranscriptFixtureTests.testBatchedEmbedMatchesSingleEmbedForAllBuiltIns`:
  five single-versus-batch cosine assertions below the existing 0.9999
  threshold, detailed below.

| Embedder | Comparison | Clean-main and feature cosine |
| -------- | ---------- | ----------------------------- |
| gte-base | Long target | 0.7817819987924215 |
| gte-base | Short, padded/masked target | 0.732244066070525 |
| e5-base | Long target | 0.864954483364585 |
| mxbai-large | Long target | 0.9225200688996962 |
| mxbai-large | Short, padded/masked target | 0.8659779075969087 |

Reviewer `agent-99c0b73c` tested the exact integrated feature commit
`cf6d2718092bdbd6eb106239be69e06099e4b523` with:

```bash
swift test --disable-sandbox --disable-swift-testing -j 4 --xunit-output /tmp/vtt-handler-feature-tests.xml > /tmp/vtt-handler-feature-tests.log 2>&1
```

That run also exited 1. Its only failing method is the same parity method;
the manager verified all five assertion values match the clean-main log
exactly. The stale default assertion passes. Subsequent closeout changes
are documentation and the comparison artifact only.

The serial XCTest runner did not emit the requested xUnit files; the
serial logs are the authoritative comparison inputs. An additional feature
run with `--parallel` produced XML and confirmed the same single failing
test case, but that run was not used for the main/feature comparison.

**This is not a clean full-suite pass.** Per the user's scope decision,
inference fixes belong to a separate task. No inference/embedding source
was changed, and no failing parity assertion was weakened or skipped.
Forcing CPU execution in a temporary diagnostic did not resolve these
five failures; the underlying cause remains unresolved by E11.

## Review decisions and limits

Two independent reviewers approved the implementation and follow-up fixes:
`agent-99c0b73c` checked parsing, overlap safety, Unicode, malformed input
and source locations; `agent-0222ace2` checked CLI integration,
persistence, backward compatibility, discovery, tests and documentation.

Review led to a scanner-to-extractor regression, handling of indented
timing lines, and precise source mapping when a line-based chunk includes
a leading blank separator. All follow-up tests pass.

Zero-duration cues remain invalid, and blocks with two or more identifier
lines before timing remain invalid. Keeping the bounded cue grammar
avoids guessing which arbitrary metadata lines are speech. Valid cues with
one identifier, headerless cues, and missing blank cue separators are
supported. Source locations cover an entire source passage when the
chunker subdivides it; they are coarse locations, not per-word alignment.

No retrieval-accuracy or speed benchmark has been run on the target
caption corpus. Raw remains the default.
