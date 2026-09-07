# E11 validation and review

## Automated validation

The integrated feature passed 23 focused tests: 8 CLI extraction-mode
tests, 5 extraction/scanner tests, and 10 normalizer tests. Coverage
includes all four modes, profile persistence and every mode mismatch,
scanner discovery, normalization before chunking, both splitters, three
line-ending styles, source ranges, speakers, entities, rolling overlap,
malformed blocks, and a 5,000-word rolling cue.

The full suite ran with real model inference available:

```bash
swift test --disable-sandbox --disable-swift-testing -j 4
```

That run executed 370 tests, skipped 3 opt-in performance/benchmark tests,
and reported six assertions in two existing test cases. These are the
same failures recorded before E11 in the E10 review notes:

- The default-profile assertion expected `bge-base` although the factory
  already defaults to `e5-base`. E11 corrects that stale assertion without
  changing the factory. All 40 profile tests pass after the correction.
- Single/batch embedding parity failed five comparisons against the
  existing cosine threshold of 0.9999: GTE long 0.7818 and short 0.7322,
  E5 long 0.8650, MXBAI long 0.9225 and short 0.8660. These inference
  paths are unchanged by the caption feature. Investigation is pending;
  no parity assertions have been weakened or skipped.

This is not a clean full-suite pass. No retrieval-accuracy or speed
benchmark has been run on the target caption corpus.

## Review decisions

Two independent reviewers approved the integrated feature: one checked
parsing, overlap safety, Unicode, malformed input and source locations;
the other checked CLI integration, persistence, backward compatibility,
scanner discovery, tests and documentation.

Their follow-up observations led to a scanner-to-extractor regression,
handling of indented timing lines, and a more precise source mapping
when a line-based chunk includes a leading blank separator. The latter
two changes are awaiting follow-up review and test validation.

Two suggested malformed-input extensions are deliberately deferred:
zero-duration cues remain invalid, and blocks with two or more identifier
lines before timing remain invalid. Keeping the bounded cue grammar
avoids guessing which arbitrary metadata lines are speech. Valid cues
with one identifier, headerless cues, and missing blank cue separators
are already supported. Tests explicitly cover zero/backwards duration
rejection. Source locations cover an entire source passage when the
chunker subdivides it; they are coarse locations, not per-word alignment.
