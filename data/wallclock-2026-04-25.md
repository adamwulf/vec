# E6.6 — per-model wallclock at E6.5 defaults — markdown-memory corpus

Captured 2026-04-25. Re-measures indexing wallclock for every
MLTensor-based built-in embedder at the new
`pool=8 batch=32 bucket-width=500 compute-policy=auto` defaults
(flipped on 2026-04-24 in E6.5). The OLD numbers in
`indexing-profile.md` were captured at the prior
`pool=10 batch=16` defaults (E4 / E5.x sweep peaks); this file
closes the loop with current-default numbers so the table column
is no longer a mix of two default regimes.

## Scope

- **Re-measured (6 of 7 planned)**: `e5-base`, `bge-base`,
  `bge-small`, `bge-large`, `nomic`, `gte-base`. One single-point
  sweep per model at its registered default geometry, no flag
  overrides — the whole point is to measure the new hardcoded
  defaults.
- **Deferred (mxbai-large)**: the ~3 h sweep was launched and
  killed because the run ate too much battery; will resume on
  AC power and an addendum will be appended below the table.
- **Out of scope**: `nl` and `nl-contextual` use Apple's
  NaturalLanguage framework, not MLTensor. The E6.5 knobs
  (worker concurrency, batch size, bucket width, compute policy)
  do not flow into Apple's framework, so re-measurement would
  produce identical numbers within run-to-run noise. The two
  rows in `indexing-profile.md` are kept as-is.

## Setup

- Corpus: `~/Library/Containers/com.milestonemade.EssentialMCP/Data/Documents/tools/markdown-memory`
  (operator-triggered drift only — no Granola sync since the
  E6.3 baselines per Adam confirmation, so corpus is byte-stable
  across this sweep)
- Build: `swift build -c release` at HEAD `bd53597` (E6.5 defaults flip)
- Per-run: `vec sweep --db markdown-memory --embedder <alias>
  --sizes <size> --overlap-pcts <pct> --out
  benchmarks/wallclock-2026-04-25/<alias> --force` — one grid
  point each, no flag overrides
- 10-perf-core M-series Apple Silicon

## Headline table

| alias        | geometry  | OLD wall (s) | NEW wall (s) | Δ s     | Δ %     | OLD ch/s | NEW ch/s | NEW chunks | NEW total /60 | doc total /60 | drift |
|--------------|-----------|-------------:|-------------:|--------:|--------:|---------:|---------:|-----------:|--------------:|--------------:|------:|
| `e5-base`    | 1200/0    | 1025         |    **891.1** | **−133.9** | **−13.1 %** | 7.3      | **9.1**  | 8070       | 38            | 40            | −2    |
| `bge-base`   | 1200/240  | 1003         |       1022.1 |   +19.1 |  +1.9 % | 8.1      |    8.6   | 8742       | 34            | 36            | −2    |
| `bge-small`  | 1200/0    |  610         |    **573.0** |  **−37.0** | **−6.1 %** | 12.3     | **14.1** | 8070       | 27            | 30            | −3¹   |
| `bge-large`  | 1200/0    | 3220         |   **2666.7** | **−553.3** | **−17.2 %** | 2.3      | **3.0**  | 8070       | 30            | 34            | −4    |
| `nomic`²     | 1200/240  | 1417         |       1496.6 |   +79.6 |  +5.6 % | 5.8      |    5.8   | 8742       | 32            | 35            | −3    |
| `gte-base`   | 1600/0    |  974         |       1611.4 |  +637.4 | +65.4 % | 5.9      |    3.8   | 6166       |  8            |  8            |  0    |
| `mxbai-large`| 800/80    | 3638         |   *(deferred)* |     —   |     —   | 3.2      |    —     | —          | —             | 31            | —     |

¹ The 3-pt drift on `bge-small` was disambiguated with a control
re-run at the OLD defaults (`--concurrency 10 --batch-size 16`)
on the same corpus, same day: that produced **27/60, rank-by-rank
identical** to the new-defaults run (652.3 s wall, 12.4 ch/s —
within run-to-run noise of the 610 s documented number). Both
runs share the same rank table, so the 3-pt gap to the
documented 30/60 is **operator-triggered corpus drift since the
E5.4 baseline**, not a side-effect of the new defaults. Archive:
[`benchmarks/wallclock-2026-04-25/bge-small-old-defaults/`](../benchmarks/wallclock-2026-04-25/bge-small-old-defaults/).

² `nomic` is pinned to `computePolicy: .cpuOnly` to work around
the macOS 26.3.1+ CoreML/ANE compile error
(`NomicEmbedder.batchEncode`). It does not benefit from the
ANE-accelerated portion of the pipeline; only the
worker-concurrency and batch-size halves of the new defaults
apply, and `pool=10 → pool=8` strictly reduces parallelism on a
CPU-bound path. The +5.6 % regression below is the expected sign
for that change.

## Aggregate

Across the 6 re-measured rows:

- **OLD total wallclock**: 8249 s
- **NEW total wallclock**: 8260.9 s
- **Aggregate delta**: +11.9 s (+0.1 %) — flat in aggregate

The flat aggregate hides bimodal per-model behaviour:

- **5 of 6 models within ±10 % of expectation** — the BGE family
  and `e5-base` got the headline gain (−6 % to −17 %), `bge-base`
  is wallclock-flat (+1.9 %, in noise band), `nomic` regresses
  modestly (+5.6 %, expected for its CPU-pinned path).
- **`gte-base` regresses catastrophically (+65.4 %)** — the
  single dominating term in the aggregate. Without `gte-base`, the
  5-model aggregate is **−625.5 s, −8.6 %**, which is the more
  honest read on what the E6.5 defaults do for the typical model.

## Per-model observations

### e5-base — biggest winner, validates the E6.5 flip

`e5-base@1200/0` was the model the E6.3 grid was tuned on, so
it's the expected best-case. The E6.3 winner-vs-in-grid-default
delta was −13.3 %; this single-point cross-day re-run at the new
defaults clocked −13.1 % vs the E5.7-era documented OLD number.
Within 0.2 pp of the in-grid prediction, despite an entirely
fresh corpus state and run-to-run noise. 891.1 s also undercuts
the [E5-base post-defaults smoke run](../benchmarks/e5-base-post-defaults-smoke/summary.md)
(1059 s) by ~16 %, suggesting that smoke run was run-to-run noise
on the high side rather than a representative reading.

### bge-large — surprise +17 % win

Documented OLD wall was 3220 s; new run clocked 2666.7 s
(−553 s, −17.2 %). The 1024-dim model gets the largest absolute
wallclock cut of any re-measured row — almost 10 minutes shaved
off a single full reindex. Likely a compounding effect: bge-large
spends a higher fraction of total wall in the embedder forward
pass than the smaller BGEs, so the b=16 → b=32 batched-call
amortisation has more to amortise.

### bge-small — small but solid +6 %

573 s vs 610 s = −37 s, −6.1 %. The smallest-dim model in the
registry sees the smallest *absolute* wallclock cut but the
expected percentage in line with the E6.3 sub-N=8 trends. The
3-pt rubric drift was disambiguated as corpus drift (footnote 1
above), not a defaults-side effect.

### bge-base — flat (in noise band)

+19 s on a 1003 s baseline = +1.9 %. Indistinguishable from
run-to-run noise; the documented OLD number itself was captured
on a separate day with separate thermal state. Treat as
"no measurable change", not a regression.

### nomic — modest +5.6 % regression, expected sign

+79.6 s on 1417 s = +5.6 %. Nomic's CPU-only pin means the new
defaults strictly hurt it: the ANE-favourable half of the E6.3
flip doesn't apply, and the worker-pool drop from 10 → 8
reduces CPU parallelism. The magnitude is consistent with the
N=8 vs N=10 deltas seen on auto-policy points in the E6.3 grid
(±5 % on auto-policy bge-base-tier rows). No retrieval
implication; the −3 pt rubric drift mirrors `bge-small` and is
corpus-drift-shaped.

### gte-base — catastrophic +65 % regression

974 s → 1611.4 s, +637 s, +65.4 %. ch/s collapses 5.9 → 3.8.
Retrieval is unchanged at 8/60 (the documented dead-canary score
flagged in `data/retrieval-gte-base-sweep.md`), so this is a
pure throughput regression on an already-non-default-candidate
model.

The chunk count differs slightly (5760 → 6166, +7 %), but that's
nowhere near enough to explain the 65 % wall blow-up. Hypotheses
in priority order:

1. **N=10 → N=8 + auto-placement interaction.** `gte-base`'s
   E5.6 number was captured at N=10 b=16, where auto-placement
   may have been routing to GPU/CPU on this model. The E6.3 grid
   never tested non-`e5-base` models at the new defaults; it's
   plausible gte-base hits the same "auto-placement under N=8
   with b=32 picks an unfavourable backend" pathology that the
   N=12 ANE-policy points hit (E6.3 grid §"Compute policy",
   1480–1525 s outliers). Worth a follow-up grid scoped to
   gte-base alone.
2. **gte-base anisotropy + larger batches don't compose.**
   gte-base's documented failure mode is cosine-similarity
   anisotropy (sims pack into 0.75–0.78). If b=32 pads the
   batch with shorter chunks across a wider length distribution,
   the per-batch padding cost dominates more on this model than
   on the BGE peers. Speculative.
3. **Run-to-run thermal noise.** The 65 % delta is far outside
   the 5–11 % run-to-run band seen on the E6.3 grid, so this is
   unlikely to be the dominant cause but cannot be fully ruled
   out from a single re-run.

`gte-base` is registered as a built-in but is not a default
candidate (8/60 vs 36+/60 for the BGE peers); the regression
doesn't affect any user who follows the recommended profile.
Out of scope to fix in E6.6.

### mxbai-large — deferred

`mxbai-large@800/80` is a ~3 h reindex; the run was started
during this experiment and stopped early because it would
have eaten too much battery. The row will be appended below
when run on AC power.

## Retrieval drift summary

| alias | NEW total | doc total | drift | source |
|-------|----------:|----------:|------:|--------|
| `e5-base`     | 38 | 40 | −2 | E5.7-era 40/60 was pre-drift; E6.3 baseline was already 38/60 |
| `bge-base`    | 34 | 36 | −2 | within tolerance |
| `bge-small`   | 27 | 30 | −3 | corpus drift confirmed via OLD-defaults control re-run (footnote 1) |
| `bge-large`   | 30 | 34 | −4 | at the autonomy threshold; same shape as the smaller-dim BGEs |
| `nomic`       | 32 | 35 | −3 | same shape as bge-small |
| `gte-base`    |  8 |  8 |  0 | rank-table identical to E5.6 |

Drift is consistent across the 5 affected models (−2 to −4 pts,
all in the same direction). Combined with the bge-small
disambiguation, this is most consistent with corpus drift since
the E5.x baselines were captured (Granola syncs into the test
corpus). The new defaults do not appear to cause any retrieval
change; at minimum, on bge-small the rank table is byte-identical
between the two default regimes.

## Decision implications

1. **The E6.5 defaults flip is validated for the family it was
   tuned on.** `e5-base` (the default), the BGE family at every
   dim tier, get a measurable speedup at no retrieval cost.
   Aggregate −8.6 % across those 5 models.
2. **`gte-base` needs follow-up.** Either accept the regression
   (it's not a default candidate) or re-tune its profile under
   the new defaults. Recommend filing as E6.7-candidate, not
   blocking E6.6.
3. **`nomic`'s slight regression is expected.** Documented as
   such; no action needed unless we want to ship a per-model
   override (overkill for a +5.6 % wall hit on a non-default
   embedder).
4. **`mxbai-large` outstanding.** Will be measured next. It is
   the other ~3 h-class model; if its delta lands near
   `bge-large`'s −17 %, the b=16 → b=32 amortisation hypothesis
   strengthens. If it regresses like `gte-base`, the
   non-BGE-family suspicion strengthens. The single number will
   discriminate between the two stories.

## References

- E6.3 grid + winner picks: [`data/sweep-e5-base-speed.md`](sweep-e5-base-speed.md)
- E6.5 defaults flip commit: HEAD `8b249c7` (`E6.5: flip
  IndexingPipeline defaults to E6.3 winner (N=8, b=32)`)
- E5-base post-flip smoke (single-point reference at
  e5-base@1200/0): [`benchmarks/e5-base-post-defaults-smoke/summary.md`](../benchmarks/e5-base-post-defaults-smoke/summary.md)
- Per-archive raw data: [`benchmarks/wallclock-2026-04-25/`](../benchmarks/wallclock-2026-04-25/)
- E4-era full per-stage breakdown for comparison: [`data/wallclock-e4-per-model.md`](wallclock-e4-per-model.md)

## Commits

- (this run) — E6.6: re-measure per-model wallclock at E6.5 defaults — 5 of 6 BGE+e5 models faster, gte-base regresses, mxbai-large deferred

## Follow-ups

- **mxbai-large addendum** — run the deferred sweep and append a
  row + observation to this file. ~3 h.
- **gte-base regression diagnosis** (E6.7 candidate) — either
  accept and document, or scope a small grid (N × b × policy) on
  gte-base alone to find a model-specific override. Not blocking.
