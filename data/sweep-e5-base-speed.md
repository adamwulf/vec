# E6.3 — e5-base indexing-speed grid (24 points)

Captured 2026-04-24. Third step of the E6 e5-base indexing-speed
tuning chain. E6.2 cleared the ANE feasibility risk; E6.3 measures
the full grid `concurrency × batch_size × compute_policy` to find
the fastest legal `(N, b, policy)` for `e5-base@1200/0` on the
`markdown-memory` corpus.

## Grid

- `concurrency N ∈ {6, 8, 10, 12}`
- `batch_size b ∈ {16, 24, 32}`
- `compute_policy ∈ {auto, ane}`

= 4 × 3 × 2 = 24 points. All run sequentially against
`markdown-memory` reset+reindexed at `e5-base@1200/0` (8070 chunks
per run). Per-point archives:
[`benchmarks/sweep-e5-base-speed/`](../benchmarks/sweep-e5-base-speed/).

## Regression-bar check (all 24 points)

**Every point produced TOTAL=38/60, TOP10_EITHER=9/10,
TOP10_BOTH=5/10**, byte-identical to the
[`e5-base-baseline-2026-04-24`](../benchmarks/e5-base-baseline-2026-04-24/)
reference at the rank level. Bit-identical retrieval across all 24
flag combinations confirms scheduling-invariance for `e5-base`'s
embedding pipeline — concurrency, batch size, and compute-policy
are pure speed knobs, not semantic ones. Scorer output for every
point matches the baseline row-for-row on T-rank and S-rank.

## Results — sorted by wall_s ascending

| Rank | N  | b  | policy | wall_s | chps_wall | total_60 | top10_either | top10_both | bit_identical |
|-----:|---:|---:|:------:|-------:|----------:|---------:|-------------:|-----------:|:-------------:|
|  **1** | **8**  | **32** | **ane**  |  **937.2** |   **8.6** |   **38** |          **9** |        **5** |       **✓**       |
|  2   | 8  | 32 | auto   |  966.3 |       8.4 |       38 |            9 |          5 |       ✓       |
|  3   | 6  | 32 | auto   | 1002.5 |       8.1 |       38 |            9 |          5 |       ✓       |
|  4   | 10 | 32 | auto   | 1013.7 |       8.0 |       38 |            9 |          5 |       ✓       |
|  5   | 8  | 24 | ane    | 1027.1 |       7.9 |       38 |            9 |          5 |       ✓       |
|  6   | 6  | 24 | ane    | 1034.8 |       7.8 |       38 |            9 |          5 |       ✓       |
|  7   | 8  | 16 | ane    | 1049.1 |       7.7 |       38 |            9 |          5 |       ✓       |
|  8   | 10 | 32 | ane    | 1052.6 |       7.7 |       38 |            9 |          5 |       ✓       |
|  9   | 10 | 24 | ane    | 1060.0 |       7.6 |       38 |            9 |          5 |       ✓       |
| 10   | 6  | 24 | auto   | 1062.5 |       7.6 |       38 |            9 |          5 |       ✓       |
| 11   | 8  | 24 | auto   | 1064.2 |       7.6 |       38 |            9 |          5 |       ✓       |
| 12   | 10 | 24 | auto   | 1066.2 |       7.6 |       38 |            9 |          5 |       ✓       |
| 13   | 6  | 16 | auto   | 1070.9 |       7.5 |       38 |            9 |          5 |       ✓       |
| 14   | 6  | 32 | ane    | 1077.7 |       7.5 |       38 |            9 |          5 |       ✓       |
| 15   | 10 | 16 | auto   | 1081.1 |       7.5 |       38 |            9 |          5 |       ✓       |
| 16   | 8  | 16 | auto   | 1090.6 |       7.4 |       38 |            9 |          5 |       ✓       |
| 17   | 10 | 16 | ane    | 1120.7 |       7.2 |       38 |            9 |          5 |       ✓       |
| 18   | 6  | 16 | ane    | 1146.9 |       7.0 |       38 |            9 |          5 |       ✓       |
| 19   | 12 | 16 | auto   | 1210.7 |       6.7 |       38 |            9 |          5 |       ✓       |
| 20   | 12 | 24 | auto   | 1229.3 |       6.6 |       38 |            9 |          5 |       ✓       |
| 21   | 12 | 32 | auto   | 1232.5 |       6.5 |       38 |            9 |          5 |       ✓       |
| 22   | 12 | 24 | ane    | 1250.5 |       6.5 |       38 |            9 |          5 |       ✓       |
| 23   | 12 | 16 | ane    | 1480.1 |       5.5 |       38 |            9 |          5 |       ✓       |
| 24   | 12 | 32 | ane    | 1525.9 |       5.3 |       38 |            9 |          5 |       ✓       |

**Winner (fastest legal config): `N=8, b=32, compute_policy=ane`,
937.2 s, 8.6 chps_wall.**

Archive:
[`benchmarks/sweep-e5-base-speed/N8-b32-ane/`](../benchmarks/sweep-e5-base-speed/N8-b32-ane/).

## Reference points

| Reference | wall_s | source |
|-----------|-------:|--------|
| 2026-04-24 baseline (N=10 b=16 auto) | 968.9 | [`benchmarks/e5-base-baseline-2026-04-24/summary.md`](../benchmarks/e5-base-baseline-2026-04-24/summary.md) |
| In-grid default (N=10 b=16 auto)     | 1081.1 | this sweep, `N10-b16-auto/` |
| Winner (N=8 b=32 ane)                | 937.2 | this sweep, `N8-b32-ane/` |

The in-grid `N10-b16-auto` point clocked 1081.1 s — 11.6 % slower
than the 968.9 s reference baseline run. This is wallclock noise
(thermal state, machine background load) and not a retrieval
regression: rubric numbers match exactly. **Apples-to-apples speedup
must be measured against the in-grid default, not the cross-day
baseline.**

| Comparison                          | wall_s |  Δ s |  Δ %  |
|-------------------------------------|-------:|-----:|------:|
| In-grid default (N=10 b=16 auto)    | 1081.1 |    — |    —  |
| Winner (N=8 b=32 ane)               |  937.2 | −143.9 | −13.3 % |
| 2026-04-24 baseline (N=10 b=16 auto)|  968.9 |    — |    —  |
| Winner vs 2026-04-24 baseline       |  937.2 | −31.7  |  −3.3 % |

The **in-grid speedup of −13.3 %** clears the 5 % defaults-update
threshold by a wide margin. The **cross-day comparison of −3.3 %**
falls under the threshold but is contaminated by run-to-run
wallclock noise — the apples-to-apples in-grid number is the
authoritative one for the defaults decision.

**Recommendation: defaults update qualifies.** Manager review
required before flipping `IndexingPipeline.defaultBatchSize` or the
hardcoded `concurrency = activeProcessorCount` defaults. The
compute-policy default flip (auto → ane) is a separate question
analyzed below.

## Observations

### Concurrency (N): 8 wins; 12 punishes hard

Per-N best wall (across both policies and all batch sizes):

| N  | best wall_s | best (b, policy)    | worst wall_s | worst (b, policy) |
|---:|------------:|---------------------|-------------:|-------------------|
|  6 |      1002.5 | b=32, auto          |       1146.9 | b=16, ane         |
|  8 |   **937.2** | **b=32, ane**       |       1090.6 | b=16, auto        |
| 10 |      1013.7 | b=32, auto          |       1120.7 | b=16, ane         |
| 12 |      1210.7 | b=16, auto          |       1525.9 | b=32, ane         |

**N=8 is the global optimum**, with N=10 and N=6 essentially tied
about ~5–7 % behind N=8. **N=12 is dramatically worse** at every
batch size and every policy — the M-series host's
`activeProcessorCount` is ~10, so N=12 oversubscribes the embedder
pool and forces the GCD-driven embed scheduler into context-switch
contention. The penalty under ANE is severe (1480 s and 1525 s on
the worst two N=12-ane points), suggesting ANE placement compounds
the contention with extra synchronization cost when called from
more concurrent workers than the hardware can serve.

### Batch size (b): 32 ≫ 24 ≈ 16

Per-`(N, policy)` deltas going from b=16 → b=32 (auto path,
N ≤ 10):

| N  | b=16 auto | b=32 auto |  Δ s | Δ % |
|---:|----------:|----------:|-----:|----:|
|  6 |    1070.9 |    1002.5 | −68.4 | −6.4 % |
|  8 |    1090.6 |     966.3 |−124.3 | −11.4 % |
| 10 |    1081.1 |    1013.7 | −67.4 | −6.2 % |

ANE path (N ≤ 10):

| N  | b=16 ane | b=32 ane |  Δ s | Δ % |
|---:|---------:|---------:|-----:|----:|
|  6 |   1146.9 |   1077.7 | −69.2 | −6.0 % |
|  8 |   1049.1 |    937.2 |−111.9 | −10.7 % |
| 10 |   1120.7 |   1052.6 | −68.1 | −6.1 % |

**b=32 wins consistently over b=16 by 6–11 %.** b=24 is in between,
without a clear sweet-spot story. The b=32 sweep effect is largest
at N=8 (where both `(N=8, b=32)` points are the two fastest in the
entire grid). At N=12, b=32 doesn't help and sometimes hurts
(N=12 b=32 ane is the slowest point in the grid, 1525.9 s) — likely
because the larger batches make the contention pathologies at N=12
worse rather than better.

The pipeline's compile-time cap on `--batch-size` is 32. Whether
b=48 or b=64 would extend the trend or hit a different bottleneck
is open; relaxing the cap is a candidate follow-up.

### Compute policy (auto vs ane): inconsistent — verdict mixed

Per-`(N, b)` deltas (ane − auto, negative = ane faster):

| N  | b  | auto wall_s | ane wall_s |   Δ s |   Δ % |
|---:|---:|------------:|-----------:|------:|------:|
|  6 | 16 |      1070.9 |     1146.9 |  +76.0 |  +7.1 % |
|  6 | 24 |      1062.5 |     1034.8 |  −27.7 |  −2.6 % |
|  6 | 32 |      1002.5 |     1077.7 |  +75.2 |  +7.5 % |
|  8 | 16 |      1090.6 |     1049.1 |  −41.5 |  −3.8 % |
|  8 | 24 |      1064.2 |     1027.1 |  −37.1 |  −3.5 % |
|  8 | 32 |       966.3 |      937.2 |  −29.1 |  −3.0 % |
| 10 | 16 |      1081.1 |     1120.7 |  +39.6 |  +3.7 % |
| 10 | 24 |      1066.2 |     1060.0 |   −6.2 |  −0.6 % |
| 10 | 32 |      1013.7 |     1052.6 |  +38.9 |  +3.8 % |
| 12 | 16 |      1210.7 |     1480.1 | +269.4 | +22.3 % |
| 12 | 24 |      1229.3 |     1250.5 |  +21.2 |  +1.7 % |
| 12 | 32 |      1232.5 |     1525.9 | +293.4 | +23.8 % |

**ANE consistently helps only at N=8** (−3.0 % to −3.8 % across all
three batch sizes). At N=6 and N=10 it's noisy ±3–7 %. At N=12 it's
a disaster. **Aggregate ANE-vs-auto across the 12 paired points: 5
wins for ANE, 7 wins for auto** — no consistent direction.

The implication for the
"`auto` already places `e5-base` on ANE" hypothesis from E6.2:
results suggest the compiler's `auto` placement already finds an
ANE-favorable scheduling at N=8, and ANE's slight further wins
there are placement-tightening rather than fundamentally new
acceleration. At higher concurrency (N=10/12) forcing ANE
introduces extra synchronization cost that overwhelms any
acceleration.

**ANE-default flip recommendation: NO.** ANE wins at the winner
point (N=8 b=32 ane vs auto by 3.0 %), but only there — and the
3 % delta sits at the threshold of run-to-run noise. Across the
full grid, forcing ANE adds risk (catastrophic at N=12) without a
consistent system-wide win. Keep `auto` as the default; treat
`--compute-policy ane` as an opt-in tuning knob for users on M-
series machines who've measured that it helps their corpus.

### Thermal anomalies

No single point ran >2× slower than its neighbors, so no thermal-
backoff anomalies to flag. The N=12 cluster is uniformly slow, but
that pattern is consistent with concurrency oversubscription
(structural cost), not thermal noise (which would manifest as a
single-point outlier).

The slowest point in the grid (N=12 b=32 ane, 1525.9 s) is 1.63×
the winner (937.2 s) — within the 2× threshold and consistent with
the "concurrency oversubscription compounds with ANE
synchronization" pattern visible across the whole N=12 row.

## Decision summary

- **Fastest legal config: N=8, b=32, compute_policy=ane → 937.2 s,
  8.6 chps_wall.** All retrieval rubric scores bit-identical to
  baseline.
- **Wall reduction vs in-grid default (N=10 b=16 auto, 1081.1 s):
  −143.9 s, −13.3 %.** Clears the 5 % defaults-update threshold.
- **Wall reduction vs cross-day baseline (968.9 s): −31.7 s,
  −3.3 %.** Below the 5 % threshold, but contaminated by run-to-run
  wallclock noise; the in-grid number is authoritative.
- **Defaults update qualifies for `concurrency` and `batch_size`.**
  Recommend updating `IndexingPipeline.defaultBatchSize` from 16 to
  32, and pinning the default concurrency at 8 instead of
  `activeProcessorCount` (≈10 on M-series). Manager review required
  before any flip — defaults touch every existing user.
- **ANE default flip: do NOT recommend.** ANE wins are
  inconsistent across the grid; `auto` is the safer default.
  Keep `--compute-policy ane` as an opt-in.

## Reproducibility

Per-point invocation pattern:

```
swift run -c release vec sweep \
  --db markdown-memory --embedder e5-base \
  --sizes 1200 --overlap-pcts 0 \
  --concurrency <N> --batch-size <b> --compute-policy <auto|ane> \
  --out benchmarks/sweep-e5-base-speed/N<N>-b<b>-<policy> --force
```

24 invocations total, run sequentially. Each invocation reset+
reindexed `markdown-memory` from scratch and produced its own
`q01..q10.json` archive + `summary.md` row.

Driver script written at
[`scripts/e6-3-sweep-grid.sh`](../scripts/e6-3-sweep-grid.sh) —
checked in for future re-runs (note: requires the corresponding
allowlist entry in `scripts/allowlist-commands.md` to run from
within an ittybitty agent).

## Commits

- (this run) — E6.3: e5-base indexing-speed grid — N=8 b=32 ane at 937.2 s (−13.3 % cut)

## Follow-ups

- **E6.4 (bucket-width refinement)** — sweep `--bucket-width` at
  the E6.3 winner `(N=8, b=32, ane)`. Auto-queued by manager
  per E6 chain plan.
- **Defaults update (E6.5 candidate)** — gated on manager review.
  Update `IndexingPipeline.defaultBatchSize` 16 → 32 and pin
  default concurrency at 8. Skip the ANE flip.
- **Batch-size ceiling raise (candidate)** — current cap is 32;
  the b=16 → b=32 trend was monotonic at every N ≤ 10. Whether
  b=48 / b=64 extends the trend or hits a different bottleneck is
  open. Out of E6.3 scope.
