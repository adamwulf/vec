# E6.1 — CLI flags for indexing-pipeline tuning knobs

Shipped 2026-04-24. First step of the E6 e5-base indexing-speed
tuning chain — unblocks E6.2 (ANE feasibility probe) and E6.3
(speed grid).

## What changed

Four new flags on both `vec update-index` and `vec sweep`:

| Flag               | Type   | Default | Routes to                                       |
|--------------------|--------|---------|-------------------------------------------------|
| `--concurrency`    | `Int?` | nil → `activeProcessorCount` (≈10 on M-series)  | `IndexingPipeline.init(concurrency:)` → `EmbedderPool` size |
| `--batch-size`     | `Int?` | nil → `IndexingPipeline.defaultBatchSize` (16)  | `IndexingPipeline.init(batchSize:)` → batch-former flush threshold |
| `--bucket-width`   | `Int?` | nil → `IndexingPipeline.defaultBucketWidth` (500)| `IndexingPipeline.init(bucketWidth:)` → batch-former length-bucket key divisor |
| `--compute-policy` | enum   | `auto`  | `IndexingProfileFactory.make(computePolicy:)` → each embedder's `withMLTensorComputePolicy(...)` scope |

### Defaults-preserve-behavior invariant

Every flag was wired so the no-flag path is byte-identical to
pre-E6.1 behavior. Specifically:

- `IndexingPipeline.init` now takes `bucketWidth` as an
  optional-with-default-500 parameter, and hoists the two existing
  defaults (`concurrency = activeProcessorCount`, `batchSize = 16`)
  into named constants so the CLI layer can refer to them by name.
- The batch-former uses `self.bucketWidth` in place of the former
  hardcoded `/ 500` divisor.
- All pre-E6.1 call sites (tests, `IndexingPipeline(profile:)`) keep
  working — they hit the default-valued overloads and see no
  behavior change.

### Shared `makePipeline` helper

`UpdateIndexCommand.makePipeline(profile:concurrency:batchSize:bucketWidth:)`
is now the single construction point honoring the three Int-sized
knobs. Both `UpdateIndexCommand.run` and
`SweepCommand.runGridPoint` call it. Nil from the CLI flag falls
back to the pipeline's hardcoded default; explicit values override.

### Compute-policy plumbing

**Outcome: plumbed without an upstream fork.** Research on
`jkrukowski/swift-embeddings@0.0.26`:

- `Bert.ModelBundle.encode` / `Bert.ModelBundle.batchEncode` do NOT
  accept a `computePolicy` parameter (unlike `NomicBert.ModelBundle`,
  which does — that's why the existing `NomicEmbedder` threads it
  directly via the API).
- `withMLTensorComputePolicy(_ policy: MLComputePolicy, _ body:)` is a
  scope-based CoreML helper exported by `import CoreML`. The
  policy is captured at MLTensor graph-construction time, not at
  materialization — so the caller can wrap just the model-invocation
  block (same pattern `swift-embeddings` uses internally inside
  `NomicBertModel.swift`, both `encode` and `batchEncode`).

**Solution**: each Bert-family embedder in the registry now accepts
an optional `MLComputePolicy` in its init, stores it, and wraps its
`bundle.encode` / `bundle.batchEncode` / `bundle.model(...)` call in
`withMLTensorComputePolicy(...)` when non-nil. A small helper,
`withOptionalComputePolicy(_:_:)` in `EmbedderMath.swift`, runs the
body unwrapped when policy is nil (preserving pre-E6.1 behavior
byte-for-byte) and under the scope when non-nil.

Scope of change:

- `BGEBaseEmbedder`, `BGESmallEmbedder`, `BGELargeEmbedder`,
  `GTEBaseEmbedder`, `MxbaiEmbedLargeEmbedder`, `E5BaseEmbedder` —
  wrap both single-text and batched paths in
  `withOptionalComputePolicy`.
- `NomicEmbedder` — honors the CLI override when supplied; otherwise
  keeps the existing `.cpuOnly` pin on the batched path (the macOS
  26.3+ ANE-fp16 workaround from the nomic failure cycle — see
  NomicEmbedder.swift for the incident history).
- `NLEmbedder`, `NLContextualEmbedder` — accept and ignore the
  policy (these go through Apple NaturalLanguage, not
  CoreML/MLTensor).

`IndexingProfileFactory.make(alias:chunkSize:chunkOverlap:computePolicy:)`
captures the policy into the factory closure so the pool's fresh
sibling instances all carry the same runtime placement preference.
`computePolicy` is deliberately NOT rolled into
`IndexingProfile.identity` — it's a runtime preference, not a
semantic property of stored vectors, and must not affect
persistence / config.json round-tripping.

`IndexingProfileFactory.resolve(identity:computePolicy:)` gained a
matching argument. Default nil keeps existing callers intact.

### Enum mapping

`MLComputePolicy` only exposes `.cpuOnly` and `.cpuAndGPU` as
direct static factories on macOS 15 / iOS 18; the ANE placement has
to go through the `MLComputePolicy(_ computeUnits: MLComputeUnits)`
initializer. The CLI enum maps:

| CLI        | MLComputePolicy                              |
|------------|----------------------------------------------|
| `auto`     | nil (no `withMLTensorComputePolicy` wrap)    |
| `cpu`      | `.cpuOnly`                                   |
| `ane`      | `MLComputePolicy(.cpuAndNeuralEngine)`       |
| `gpu`      | `.cpuAndGPU`                                 |

## Regression-bar check

Baseline anchor:
[`benchmarks/e5-base-baseline-2026-04-24/e5-base-1200-0/`](../benchmarks/e5-base-baseline-2026-04-24/e5-base-1200-0/)

Post-flag smoke run (default flags, current E6.1 binary):
[`benchmarks/e5-base-postflag-smoke/e5-base-1200-0/`](../benchmarks/e5-base-postflag-smoke/e5-base-1200-0/)

`scripts/score-rubric.py` output for both:

| metric        | baseline | post-flag smoke | match |
|---------------|---------:|----------------:|:-----:|
| `TOTAL`       |    38/60 |           38/60 |   ✓   |
| `TOP10_EITHER`|     9/10 |            9/10 |   ✓   |
| `TOP10_BOTH`  |     5/10 |            5/10 |   ✓   |

Per-query target ranks (transcript.txt, summary.md) are identical
across all 10 queries. **Regression bar passed.** Raw similarity
scores in the `q<NN>.json` archives drift by ~1e-7 at the
floating-point tail between runs — routine CoreML/MLTensor
numerical non-determinism that doesn't affect rank assignment or
bracket scoring. Some non-target file orderings also drift (same
cause), but target-file ranks are identical on every query, which
is what the scorer consumes.

## Flag-probe run

Non-default flag values smoke test. Archive:
[`benchmarks/e5-base-flag-probe/e5-base-1200-0/`](../benchmarks/e5-base-flag-probe/e5-base-1200-0/)

Invocation:

```
vec sweep --db markdown-memory --embedder e5-base \
  --sizes 1200 --overlap-pcts 0 \
  --concurrency 6 --batch-size 24 --bucket-width 300 \
  --out benchmarks/e5-base-flag-probe --force
```

Outcome:

| metric     | default-flag smoke | flag-probe |
|------------|-------------------:|-----------:|
| chunks     |               8070 |       8070 |
| wall_s     |             1573.9 |     1680.6 |
| chps       |                5.1 |        4.8 |
| total_60   |                 38 |         38 |
| top10_either |               9 |          9 |
| top10_both |                  5 |          5 |

**Process completed cleanly at non-default values; archive
well-formed; rubric score lands in the expected range.** Chunk
count is identical (8070) — chunking isn't touched by the three
pipeline knobs. The wallclock difference (1680 s vs 1573 s)
reflects the lower concurrency=6 vs ~10 activeProcessors default
setting; not a claim about optimum, just that the knob moves the
dial as expected. No rubric-score drift is *required* at non-
default knobs (different embed-task-completion order could have
produced small rank shifts), but on this run every per-query
target rank happened to match the default-flag smoke run —
strengthens confidence the flags don't route bogus inputs into the
pipeline.

Different concurrency / batch-size / bucket-width routes chunks
through the embed pool differently, so minor rubric drift is
expected in principle. Primary goal of this run was
"process doesn't crash, emitted archive is well-formed, score is
in the expected rubric range" — all three met.

## Commits

- `675de8f` — E6.1: add --concurrency / --batch-size / --bucket-width / --compute-policy flags

## Follow-ups

- E6.2 (ANE feasibility probe for e5-base) — run
  `--compute-policy ane` against the default geometry. Flag is
  plumbed; this probe can start as soon as E6.1 merges.
- E6.3 (indexing-speed grid) — depends on E6.2's ANE outcome.
- E6.4 (bucket-width refinement) — uses the `--bucket-width` flag
  at the E6.3 winner.
