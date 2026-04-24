# E6.2 — e5-base ANE feasibility probe

Shipped 2026-04-24. Second step of the E6 e5-base indexing-speed
tuning chain. Answers the question left open by E6.1: does e5-base's
custom mean-pool graph compile and run under a forced ANE compute
policy, or does it hit the same `"Incompatible element type for ANE"`
failure that pinned `NomicEmbedder` to `.cpuOnly` on macOS 26.3.1+?

## Outcome: ANE compiles and runs cleanly for e5-base.

Single-point sweep at the default geometry with `--compute-policy ane`:

```
vec sweep --db markdown-memory --embedder e5-base \
  --sizes 1200 --overlap-pcts 0 \
  --compute-policy ane \
  --out benchmarks/e6-2-ane-probe --force
```

| metric         | baseline (auto) | ANE probe | match |
|----------------|----------------:|----------:|:-----:|
| chunks         |            8070 |      8070 |   ✓   |
| `TOTAL`        |           38/60 |     38/60 |   ✓   |
| `TOP10_EITHER` |            9/10 |      9/10 |   ✓   |
| `TOP10_BOTH`   |            5/10 |      5/10 |   ✓   |
| wall_s         |           968.9 |     932.4 |   −   |
| chps_wall      |             8.3 |       8.7 |   −   |

**No crash, no "Incompatible element type for ANE" failure, no garbage
embeddings.** The sweep ran to completion and produced a well-formed
`q01..q10.json` archive + `summary.md`.

**Per-query target ranks are bit-identical across all 10 queries**
between the ANE probe and the `e5-base-baseline-2026-04-24` reference.
Raw `scripts/score-rubric.py` output matches row-for-row on every
query — same T rank, same S rank, same subtotal. Bit-identical
retrieval at the rank level; small float drift in the underlying
similarity scores is possible (routine CoreML/MLTensor numerical
non-determinism per E6.1) but doesn't affect rank assignment.

**Wallclock speedup is modest: 36.5 s cut, ~3.8 %.** 968.9 s → 932.4 s.
Not dramatic, but real and in the expected direction. The chps_wall
metric rises 8.3 → 8.7.

### Why ANE worked here but not for nomic

The nomic failure mode was specific to `NomicBert.ModelBundle.batchEncode`
feeding an attention mask into a graph that CoreML's ANE compiler then
rejected as `"Incompatible element type for ANE: expected fp16, si8,
or ui8"`. `E5BaseEmbedder` takes a different code path:

- Nomic: `bundle.batchEncode(...)` from `swift-embeddings`, which
  constructs tokens + attention mask tensors internally and feeds
  both into the graph. ANE-incompatible element type on macOS 26.3.1+.
- e5-base: `bundle.model(inputIds:attentionMask:)` — the raw model
  call, wrapped in `withOptionalComputePolicy(computePolicy)` in
  `E5BaseEmbedder.meanPooledBatch`. The same tensor shapes and types
  that tripped nomic's batched path appear here, but the graph
  constructed around `bundle.model(...)` + the explicit masked mean
  pool clearly compiles for ANE on this macOS build without
  incompatible-element-type errors.

It's also possible the ANE scheduler is quietly falling back to CPU
for some subgraph and running most of the work on CPU anyway —
consistent with the modest 3.8 % speedup rather than the 30-50 %
headroom one might hope for from true ANE acceleration. The
E6.3 ANE-vs-auto A/B will surface that: if ANE and auto run at the
same wallclock at every `(N, b)` point, the compiler is likely
choosing the same placement regardless of the policy hint.

### Reproducibility

- Build: `swift build` passed (E6.1 flags already merged, no
  additional code changes for this probe).
- Command: `swift run -c release vec sweep --db markdown-memory --embedder e5-base --sizes 1200 --overlap-pcts 0 --compute-policy ane --out benchmarks/e6-2-ane-probe --force`
- Archive: [`benchmarks/e6-2-ane-probe/e5-base-1200-0/`](../benchmarks/e6-2-ane-probe/e5-base-1200-0/)
- Summary: [`benchmarks/e6-2-ane-probe/summary.md`](../benchmarks/e6-2-ane-probe/summary.md)
- Baseline reference: [`benchmarks/e5-base-baseline-2026-04-24/e5-base-1200-0/`](../benchmarks/e5-base-baseline-2026-04-24/e5-base-1200-0/)

Scorer parity (both runs scored with `scripts/score-rubric.py`): row-
for-row identical T/S ranks on all 10 queries. See the table above.

## E6.3 grid-shape decision: 24-point grid with ANE variants.

The probe clears the ANE-feasibility risk. E6.3 should run the full
24-point grid as originally scoped:

  `batch_size ∈ {16, 24, 32}` × `concurrency ∈ {6, 8, 10, 12}` × `policy ∈ {auto, ane}`

= 3 × 4 × 2 = 24 points. At ~932–969 s per point the total wallclock
is ~6.5 h, within the overnight budget. The `{auto, ane}` A/B at
each `(batch_size, concurrency)` point is what lets us tell whether
`--compute-policy ane` is a real acceleration knob or a no-op that
the scheduler was already picking.

If the A/B shows ANE consistently matching or beating auto, the
default compute policy should flip to ANE in a later step (not part
of E6.3 scope — defaults-update rule gates on ≥5 % wallclock win).

If the A/B shows auto consistently matching ANE, we've measured the
compiler's placement choice indirectly (it's already using ANE, or
ANE adds no value over CPU/GPU fallback at these batch sizes), and
the `--compute-policy` flag stays as a diagnostic / opt-in knob
rather than a new default.

A CPU-only 12-point fallback grid was the alternative if ANE failed.
Not needed now.

## Commits

- (this run) — E6.2: e5-base ANE feasibility probe — compiles, 3.8 % wall cut

## Follow-ups

- E6.3 (indexing-speed grid for e5-base) — runs the 24-point grid
  above.
- E6.4 (bucket-width refinement) — uses the `--bucket-width` flag at
  the E6.3 winner.
