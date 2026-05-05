# E9 — implementation report

## Live verification on `markdown-memory`

Pre-fix (commit before E9):

```
$ swift run vec update-index --db markdown-memory
Update complete: 0 added, 196 updated, 0 removed (18 skipped: 18 unreadable).

# 24 "non-English content detected" warnings on stderr (granola/*)
```

Identical output every back-to-back run (deterministic
reprocessing of the same 196 + 18 files).

Post-fix (commit b2e9adc, run on 2026-05-05):

```
# First run after the fix lands. The 196 ULP-drifted files now
# count as `unchanged`; the 18 zero-chunk files still get
# extracted (because they don't yet have a completion record),
# but they get one this time.
$ swift run vec update-index --db markdown-memory
Update complete: 0 added, 0 updated, 0 removed (18 skipped: 18 unreadable).

# Second run, immediately after. The 18 now have completion
# records → no extraction.
$ swift run vec update-index --db markdown-memory
Update complete: 0 added, 0 updated, 0 removed.
```

Zero non-English warnings on either run. Acceptance criteria 1
and 3 from the plan are met against the production corpus.

## Tests added

- `Tests/VecKitTests/UpdateCategorizerTests.swift` — 8 boundary
  tests for the new `categorizeForUpdate` helper, including a
  1000-iteration property test that pushes random APFS-grade
  mtimes through the same `Date → timeIntervalSince1970 → Date`
  round-trip the SQLite codec uses and asserts none of them
  trigger a re-index.
- `Tests/VecKitTests/E9ZeroChunkAndUnreadableTests.swift` — 4
  pipeline integration tests covering the empty-file completion
  record, whitespace-only file completion record, permission-denied
  retry (`chmod 000`), and the file-count visibility shift.
- `Tests/CLITests/UpdateIndexLogTests.swift` —
  `testSecondRunOnMixedCorpus_isFullyNoOp` end-to-end pin: the
  second `update-index` run on a mixed `normal + empty + whitespace`
  corpus reports `added=0, updated=0, removed=0,
  skippedUnreadable=[], unchanged=3`. Catches user-visible
  regressions in the summary line wiring, not just internal state.

All 13 new tests pass; 55+ pre-existing relevant tests still
pass. Two pre-existing failures (`testFactoryDefaultAliasIsKnown`,
`testBatchedEmbedMatchesSingleEmbedForAllBuiltIns`) are unrelated
to E9 — they were failing on `main` before the branch.

## Commits

- `0f50257` — initial plan
- `53840d1` — plan revision after review-cycle 1
- `b2e9adc` — implementation
- (final tweaks for review-cycle 2 in subsequent commit)
