# Native retrieval run summary

- Code: tracked files clean at `6b30005`. The manifest's `git_dirty: true`
  reflects only the harness-created, untracked `.agents/` directory.
- XCTest: `testPDFOCRRetrievalBenchmark` passed in 4.293 seconds with zero
  failures.
- Raw arm: seven processed, four indexed, three blank, zero failed, eight
  chunks, 0.541566375 seconds.
- `pdf-ocr-v1` arm: seven processed, six indexed, one blank, zero failed,
  thirteen chunks, 1.932029667 seconds, eight cache hits, eight misses, and
  eight Vision calls.
- Independent score: raw rank-1 3/7, top-3 5/7, MRR 0.571, correct-page 4/7,
  passage 3/7; `pdf-ocr-v1` rank-1 7/7, top-3 7/7, MRR 1.000,
  correct-page 7/7, passage 7/7.
