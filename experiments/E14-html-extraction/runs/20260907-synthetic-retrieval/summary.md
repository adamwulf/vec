# E14 synthetic HTML retrieval result

Run identity:
`044e61f25d831e53a91e013fe56deb68d9b029f4acf6e969266766f3d42f6860`

## Result

| Metric (six answered queries) | Raw | html-v1 | Change |
| --- | ---: | ---: | ---: |
| Rank-1 recall | 6/6 (100%) | 6/6 (100%) | 0 percentage points |
| Top-3 recall | 6/6 (100%) | 6/6 (100%) | 0 percentage points |
| Top-5 recall | 6/6 (100%) | 6/6 (100%) | 0 percentage points |
| MRR | 1.000 | 1.000 | 0.000 |
| Required-content audit | 6/6 (100%) | 6/6 (100%) | 0 percentage points |
| Boilerplate-absence audit | 2/6 (33.3%) | 6/6 (100%) | +66.7 percentage points |

There is no measured retrieval-recall improvement on this deliberately small,
easy synthetic corpus: raw extraction already ranked every target first. The
positive result is lossless cleanup on the frozen checks. `html-v1` preserved
all required content while removing all audited navigation/form/script/sidebar
noise; raw passed only the two cases with no exclusion strings.

The boilerplate no-answer trap changed from `executable-only.html` at 0.719448
under raw to `structural.html` at 0.708706 under `html-v1`. This is descriptive,
not an absence pass: cosine similarity has no calibrated rejection threshold.

## Scope and caveats

- Seven files are synthetic behavioral fixtures derived from the supplied
  `freezedry-helper` examples, not a representative sample of saved websites.
- Six queries have answers and two are no-answer probes. With seven files,
  top-5 is weak and top-10 would be vacuous; rank-1 and MRR are most useful.
- Every fixture fits within 1,200 characters, so both arms use one whole-file
  embedding. The direct harness matches that production extraction geometry
  while shared `TextExtractionMode`/pipeline wiring is still pending.
- The experiment measures text-only `html-v1`. It does not claim an OCR recall
  effect because the frozen HTML sample contains no meaningful raster fixture.
- SwiftSoup structural selection is not Mozilla Readability and does not claim
  its class weighting, link-density analysis, or broad-site accuracy.
- The independent scorer derived file rank from archived finite scores,
  rejected incomplete/inconsistent archives, and recomputed content and
  boilerplate audits from archived primary text.
