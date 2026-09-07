# E12 independent review sign-off — 2026-09-07

Both reviewers gave unconditional approval of assembled commit `bcaf3e0`.
Later completion-note changes do not change the reviewed implementation,
tests, measured archives, or report.

| Reviewer | Primary scope | Final verdict |
|---|---|---|
| `agent-7f25b85a` | Correctness, formats, persisted mode, scanner/extractor routing, cache, provenance | APPROVED — no remaining findings |
| `agent-b48d8418` | Concurrency, bounded memory, meaningful tests, experimental claims | APPROVED — no open items |

Both independently ran the scorer and verified the archive fingerprints,
empty raw baseline, 17 nonblank images plus one blank completion, 19 chunks,
hit@1 14/15, hit@5 15/15, and MRR 0.967. They checked the throughput arithmetic,
cache accounting, failure diagnostics, source-tree equivalence across the
rebase, and report links and caveats. The correctness reviewer also rebuilt
the full test target successfully after the final test correction.

Validation consists of the [456-test native full suite](runs/20260907-fullsuite/README.md)
(zero failures, six opt-in skips), separately executed E12 retrieval and
throughput benchmarks, eight independent scorer regression tests, and the
later [36-test native OCR suite](runs/20260907-imageocrtests/README.md)
(zero failures). The last run covers the added real blank PNG/JPEG fixtures;
the earlier full-suite log predates that addition. The final `Sources/` and
`Tests/` trees match the runner's validated tree byte-for-byte.

Findings fixed during the review cycle:

- Added direct LRU eviction/touch/disk-fallback coverage and a deterministic
  single-flight test that proves all duplicate requests actually waited.
- Added a timeout to the concurrency rendezvous test, documented per-job
  memory, corrected the per-file ordering comment and narrowed the DB-error
  test's stated guarantee.
- Retained per-image failure diagnostics before aborting a throughput run;
  a separate corrupt-image fault injection verifies this path. The lost
  initial run's failure cause remains unknown.
- Corrected MiB labels without changing raw values, preserved execution
  logs, and added bounded termination escalation for the benchmark launcher.
- Removed unsupported throughput bounds and ANE causal claims; distinguished
  curated retrieval targets from the stride-selected throughput sample,
  excluded embedding/DB work from OCR estimates, and omitted noisy warm-cache
  projections from report tables.
- Attributed retrieval RSS to the embedding pool plus Vision and kept it
  distinct from OCR-only throughput process RSS.
- Added real blank PNG/JPEG coverage, fixed its initial `ExtractionResult`
  assertion compile error in a separate commit, and verified the corrected
  test alongside positive recognition controls on the native runtime.

No production source changed after the measured runs or the full-suite run.
The final review required no benchmark reruns or changes to frozen labels.
