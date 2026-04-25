# E6.4 — e5-base bucket-width refinement at the E6.3 winner

Captured 2026-04-24. Final step of the E6 e5-base indexing-speed
tuning chain. E6.3 picked `(N=8, b=32, ane)` as the fastest legal
config; E6.4 sweeps the remaining tuning knob — `--bucket-width`,
the length-bucket key divisor in the batch-former — at that anchor
to see whether changing the default 500 buys further wallclock.

## Setup

Three points at the E6.3 winner `(concurrency=8, batch_size=32,
compute_policy=ane)`, varying only `--bucket-width`:

- `--bucket-width 300` (finer; less padding waste, more small batches)
- `--bucket-width 500` (current default; reference is the E6.3
  winner archive)
- `--bucket-width 700` (coarser; larger effective batches, more
  padding waste)

The bucket-former groups chunks for batched embedding by
`chunk.text.count / bucketWidth`; same-bucket chunks pack into the
same batch, different-bucket chunks don't. The sweep tests whether
the current `/500` divisor is still optimal for `e5-base@1200/0` on
`markdown-memory` at the new `(N, b, policy)` anchor.

Per-point archives:

- `--bucket-width 300`:
  [`benchmarks/sweep-e5-base-bucket/bucket-300/`](../benchmarks/sweep-e5-base-bucket/bucket-300/)
- `--bucket-width 500` (E6.3 winner reference):
  [`benchmarks/sweep-e5-base-speed/N8-b32-ane/`](../benchmarks/sweep-e5-base-speed/N8-b32-ane/)
- `--bucket-width 700`:
  [`benchmarks/sweep-e5-base-bucket/bucket-700/`](../benchmarks/sweep-e5-base-bucket/bucket-700/)

## Results

| bucket_width | wall_s | chps_wall | total_60 | top10_either | top10_both | bit_identical |
| ---: | ---: | ---: | ---: | ---: | ---: | :---: |
| 300 | 1018.8 | 7.9 | 38 | 9 | 5 | ✓ |
| **500** | **937.2** | **8.6** | **38** | **9** | **5** | **✓** |
| 700 |  952.1 | 8.5 | 38 | 9 | 5 | ✓ |

Wallclock deltas vs the `bucket=500` reference (the E6.3 winner):

| Comparison           | wall_s |   Δ s |   Δ % |
| -------------------- | -----: | ----: | ----: |
| bucket=300 vs 500    | 1018.8 | +81.6 | +8.7 % |
| bucket=500 (anchor)  |  937.2 |     — |     — |
| bucket=700 vs 500    |  952.1 | +14.9 | +1.6 % |

## Regression-bar check

**All three points produced TOTAL=38/60, TOP10_EITHER=9/10,
TOP10_BOTH=5/10** — byte-identical to the
[`e5-base-baseline-2026-04-24`](../benchmarks/e5-base-baseline-2026-04-24/)
reference at the rank level. T-rank and S-rank match across all 10
queries on both new sweeps:

- bucket-300 scorer output: 38/60 9/10 5/10, ranks identical to baseline
- bucket-700 scorer output: 38/60 9/10 5/10, ranks identical to baseline

`bucket-width` is a pure batching/padding knob — it shifts which
chunks pack together for `bundle.batchEncode(...)` but never changes
the embedding output for a given chunk. Bit-identical retrieval is
the expected outcome and confirms the implementation routes chunks
through the embedder cleanly at non-default values.

## Observations

### bucket=500 wins; the default already sits at the optimum

Of the three points, the current `IndexingPipeline.defaultBucketWidth
= 500` is the fastest at the E6.3 winning `(N, b, policy)` anchor.
Neither `/300` nor `/700` beats it:

- **`/300` (8.7 % slower)** — the finer bucketing creates more
  partially-filled batches. `b=32` is the flush threshold; finer
  bucket keys mean chunks of slightly-different lengths land in
  different buckets and never co-batch, so the batch-former flushes
  smaller batches more often. Larger batches amortize ANE setup
  cost; smaller batches don't. The `+8.7 %` cost is consistent with
  losing roughly one in eight chunks worth of batched ANE
  parallelism.

- **`/700` (1.6 % slower)** — coarser bucketing is essentially
  break-even with `/500`. The +14.9 s delta is below the documented
  E6.3 in-grid wallclock noise (~11.6 % across runs of identical
  config). The corpus's chunk-length distribution at `1200/0` is
  apparently already aggregated enough at `/500` that widening to
  `/700` adds padding waste roughly equal to the parallelism gain
  from larger effective batches. No clear win.

### No clear winner over the default

The 5 % defaults-update threshold (set in `plan.md` E6 §"Defaults
update rule") rules out a change in either direction:

- `/300` is slower than `/500` by 8.7 % — that's a *regression*, so
  by definition can't motivate flipping the default.
- `/700` differs by 1.6 % — well under the 5 % threshold and inside
  documented run-to-run noise. Even if a follow-up confirmed `/700`
  marginally faster, it wouldn't clear the bar.

The current `IndexingPipeline.defaultBucketWidth = 500` stays.

## Decision summary

- **Best bucket-width at `(N=8, b=32, ane)`: `bucket=500`
  (current default), 937.2 s, 8.6 chps_wall.**
- **Bit-identical retrieval on all three points** — bucket-width is
  a pure batching knob, retrieval-invariant for `e5-base`.
- **Defaults update for bucket-width: NO.** Neither `/300` nor
  `/700` clears the 5 % threshold over `/500`. `/300` is a
  regression (-8.7 %) and `/700` is within run-to-run noise
  (+1.6 %). Keep `IndexingPipeline.defaultBucketWidth = 500`.

## Reproducibility

Two new sweep invocations, sequential, against the same corpus:

```
swift run -c release vec sweep \
  --db markdown-memory --embedder e5-base \
  --sizes 1200 --overlap-pcts 0 \
  --concurrency 8 --batch-size 32 --compute-policy ane \
  --bucket-width <300|700> \
  --out benchmarks/sweep-e5-base-bucket/bucket-<300|700> --force
```

The `bucket=500` reference is the E6.3 winner archive at
[`benchmarks/sweep-e5-base-speed/N8-b32-ane/`](../benchmarks/sweep-e5-base-speed/N8-b32-ane/);
no rerun was needed for E6.4.

## Commits

- (this run) — E6.4: bucket-width refinement at N=8 b=32 ane — bucket=500 wins, no default change

## Follow-ups — E6 chain complete

E6.4 closes the E6 e5-base indexing-speed tuning chain. Across the
four steps:

- **E6.1** — CLI flags shipped (`--concurrency`, `--batch-size`,
  `--bucket-width`, `--compute-policy`).
- **E6.2** — ANE feasibility cleared for `e5-base`.
- **E6.3** — speed-grid winner: `N=8, b=32, ane` at 937.2 s,
  −13.3 % vs in-grid default. Recommends flipping
  `IndexingPipeline.defaultBatchSize` 16 → 32 and pinning default
  concurrency at 8.
- **E6.4** — `bucket-width=500` (current default) wins; no flip.

Pending manager review: apply the E6.3 defaults update
(batch_size=32, concurrency=8). The compute-policy and
bucket-width defaults stay as they are.
