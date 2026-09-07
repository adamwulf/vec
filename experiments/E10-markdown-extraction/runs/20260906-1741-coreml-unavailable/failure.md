# Incomplete run: CoreML unavailable

The Python-launched release XCTest reached the raw arm after freezing nine Markdown files and fifteen queries. It then terminated with signal 5 and `CoreML/InternalErrors.swift:116: Fatal error: Encountered an internal error.` No query ranking or completed arm summary was produced. This directory is an incomplete diagnostic archive, not a scored comparison.

Two isolated probes in the same execution environment narrow the failure:

```swift
import CoreML
let result = await (MLTensor([Float(1), Float(2), Float(3)]) + Float(1))
    .shapedArray(of: Float.self)
print(result.scalars)
```

This fails with the same CoreML error, without any model or corpus. Wrapping tensor construction in `withMLTensorComputePolicy(.cpuOnly)` also fails. A separate `MTLCreateSystemDefaultDevice()` probe returns `nil`. These observations suggest an execution-environment restriction; they do not establish a defect in E5 or Markdown extraction.

The frozen manifest preserves the corpus, model, query, build, and settings hashes from before the failure. No corpus bodies or scratch databases are included. The source remained clean at launch. Retry with a fresh output directory once CoreML execution is available; do not score or resume this partial archive.
