# E7 — FP16 inference + CoreML compute-policy variants for e5-base

Successor to the E6 chain (E6.1 flags → E6.2 ANE feasibility → E6.3
24-point speed grid → E6.4 bucket-width → E6.5 defaults flip →
E6.6 per-model re-measure). E6 squeezed wallclock out of the
*pipeline* (concurrency, batch size, bucket width). E7 attacks the
*inference graph* itself: does forcing the BERT forward pass through
FP16 — possibly combined with a different compute-policy placement —
move e5-base wallclock without breaking the rubric?

## Hypothesis

The Apple Neural Engine and modern Apple-silicon GPU paths run
natively at FP16 (and INT8); FP32 either gets silently down-converted
or, when it's not, is the slowest path. swift-embeddings 0.0.26 sits
on top of `swift-safetensors`, which preserves the on-disk dtype when
materializing tensors via `mlTensor(forKey:)`. `intfloat/e5-base-v2`
ships with `torch_dtype: float32` in its config and a corresponding
FP32 safetensors blob — so today's e5-base inference is FP32 weights
fed into MLTensor ops on macOS 15+, with no explicit precision policy
set anywhere in our stack.

E6.2 measured ANE compute-policy at `−3.8 %` and E6.3's grid showed
ANE wins at `(N=8, b=32)` only marginally (−3.0 to −3.8 %), with the
strong suspicion that the CoreML scheduler is partially or fully
falling back to CPU regardless of policy hint — possibly because the
graph is FP32 and the ANE compiler refuses to take FP32 work.
Forcing the activation path to FP16 (via `MLTensor.cast(to: Float16.self)`
inside `meanPooledBatch`) is the single concrete lever we control
that could unblock ANE acceleration AND amortize bandwidth on the GPU
path. Industry expectation for FP16 BERT inference vs FP32 BERT
inference on Apple silicon is **10–30 %** wallclock cut with rubric
delta in single-digit-similarity-score noise (rank-level usually
unchanged for embedding-quality benchmarks).

This experiment is **not** weight quantization (FP16-quantized
weights would be a *different* experiment — separate model conversion
step, separate quality risk, separate distribution path). E7 only
flips the *inference compute precision* — weights remain whatever
the safetensors file says, and we cast at the MLTensor level.

## What's the actual default precision today?

Pre-experiment fact-check, traced through the dependency graph:

1. **`Bert.loadModelBundle(from:)`** in
   [`swift-embeddings/Sources/Embeddings/Bert/BertUtils.swift`](https://github.com/jkrukowski/swift-embeddings/blob/main/Sources/Embeddings/Bert/BertUtils.swift)
   reads `model.safetensors` via `Safetensors.read(at:)`, then
   constructs each weight as an `MLTensor` via
   `safetensors.mlTensor(forKey:)`. **No explicit dtype cast** is
   applied anywhere in the loader; no `MLModelConfiguration` is
   constructed (this stack uses `MLTensor`, not `MLModel` — the
   `MLModelConfiguration.computePrecision` knob therefore does not
   apply).
2. **`Safetensors.mlTensor(forKey:)`** in
   [`swift-safetensors/Sources/Safetensors/Backend/MLTensor.swift`](https://github.com/jkrukowski/swift-safetensors/blob/main/Sources/Safetensors/Backend/MLTensor.swift)
   dispatches on the safetensors header's `dtype` field via
   `tensorData.dtype.toMLTensorScalarType()`. **It preserves the
   on-disk dtype** — F32 → `Float32`, F16 → `Float16`, BF16 →
   `BFloat16` (where supported). No widening to Float32, no
   narrowing to Float16.
3. **`intfloat/e5-base-v2`'s
   [`config.json`](https://huggingface.co/intfloat/e5-base-v2/raw/main/config.json)**
   declares `"torch_dtype": "float32"`. The published
   `model.safetensors` is FP32; `mlTensor(forKey:)` therefore
   yields **`MLTensor<Float32>`** for every weight tensor.
4. **`E5BaseEmbedder.meanPooledBatch`**
   ([`Sources/VecKit/E5BaseEmbedder.swift:97-146`](../../Sources/VecKit/E5BaseEmbedder.swift))
   constructs the input-id and attention-mask tensors with
   `MLTensor(shape:scalars:)` from `[Int32]` and `[Float]`
   respectively. The default `MLTensorScalar` mapping for `Float`
   (= `Float32` on Apple silicon) is FP32. The matmul/attention
   scope therefore runs FP32 throughout, regardless of the
   `withMLTensorComputePolicy(...)` placement chosen by
   `--compute-policy`.

**Conclusion: today's e5-base inference path is FP32 end-to-end at
the MLTensor level.** The ANE-3.8 % E6.2 result is consistent with
the CoreML compiler either declining ANE for FP32 ops or running ANE
with internal FP32→FP16→FP32 round-tripping (overhead absorbing the
gains). Either way, FP16 is the unexplored lever.

## Levers available

Categorized by what we control vs what would require an upstream
change:

### Levers we control inside `E5BaseEmbedder`

- **`MLTensor.cast(to: Float16.self)`** on the input tensors before
  `bundle.model(...)`. Forces the encoder graph to materialize
  intermediate activations in FP16. Weight tensors stay FP32 (loaded
  by upstream); MLTensor will broadcast-promote on op, so this lever
  alone doesn't fully eliminate FP32 — but the *activation* path
  becomes FP16, which is the larger memory-bandwidth term.
  ([Apple docs — `MLTensor.cast(to:)`](https://developer.apple.com/documentation/coreml/mltensor/cast(to:)))
- **`MLTensor.cast(to: Float16.self)` on the masked mean-pool
  arithmetic.** Same idea, applied to the post-encoder pool so the
  reduction also runs FP16. We currently `pooled.cast(to: Float.self)`
  *before* `shapedArray(of: Float.self)` to get back to host FP32 —
  E7 keeps that final cast (host code wants `[Float]`) but moves the
  FP16 boundary upward.
- **Materialization-time scalar choice.** `pooled.shapedArray(of:
  Float16.self).scalars` would give us FP16 host scalars; we'd
  immediately widen back to `Float` for the rest of the pipeline
  (DB writer, L2 norm, similarity search all run FP32). Not a real
  lever — keep `cast(to: Float.self)` at materialization.

### Levers we control via `--compute-policy` (already exposed)

- `MLComputePolicy.cpuOnly` — forces CPU. Useful for FP16-on-CPU
  baseline (rules out CPU as the bottleneck).
- `MLComputePolicy.cpuAndGPU` — Metal GPU + CPU fallback. We have
  not yet measured this as a primary policy for e5-base; the E6.3
  grid only A/B'd `auto` vs `ane`.
- `MLComputePolicy(.cpuAndNeuralEngine)` — ANE + CPU fallback.
  Already wired (E6.1) and probed (E6.2). Hypothesis: this lever
  becomes meaningful only once the graph is FP16.
- `MLComputePolicy(.all)` — CPU + GPU + ANE. Not currently exposed
  by `ComputePolicyOption`. Out of scope for E7 (would require a
  CLI enum addition); revisit if FP16 results suggest the scheduler
  needs the union to make a smart placement.

[Apple docs — `MLComputePolicy`](https://developer.apple.com/documentation/coreml/mlcomputepolicy)
only exposes `cpuOnly` and `cpuAndGPU` as static-var factories;
`.cpuAndNeuralEngine` and `.all` go through
`MLComputePolicy(_ computeUnits: MLComputeUnits)` — same path the
E6.1 CLI mapping already uses.

### Levers that would require upstream changes (out of scope)

- **`MLModelConfiguration.computePrecision`** — `.float16` /
  `.float32` enum. Applies to compiled `MLModel` instances loaded via
  `MLModel(contentsOf:configuration:)`. swift-embeddings does NOT
  load BERT through `MLModel` — it builds the graph from scratch in
  Swift via MLTensor ops on safetensors-loaded weights. So this knob
  does not apply to the current code path. Bringing it into play
  would mean shipping a pre-compiled `.mlmodelc` of e5-base, which is
  a separate distribution decision and not part of E7.
- **FP16 safetensors weights**. We could pre-convert
  `intfloat/e5-base-v2`'s safetensors to FP16 and host them, then
  point `Bert.loadModelBundle` at the FP16 file. Halves on-disk
  weight footprint, halves the FP32→FP16 cast cost on every batch.
  But it requires either an upstream PR to swift-embeddings (allow
  per-load dtype override) or a fork. Out of scope for E7. Note as a
  potential E8 follow-up if E7's MLTensor-level cast wins.
- **INT8 quantization.** Even larger headroom (4× weight footprint
  reduction, ANE-friendly), but with measurable rubric impact for
  most embedding models. Worth its own experiment; out of scope here.

## Quality measurement protocol

Every variant in the E7 grid must be scored against the canonical
10-query rubric AFTER its wallclock run. Using `vec sweep` rather
than a bare `vec update-index` gets us this for free — `sweep` does
the index → score → archive sequence per grid point.

- **Baseline rubric for e5-base@1200/0**: `TOTAL=40/60`,
  `TOP10_EITHER=9/10`, `TOP10_BOTH=6/10` (per
  [`data/retrieval-e5-base-refine.md`](../../data/retrieval-e5-base-refine.md);
  the E6 chain shifted to a 38/60 measurement on a slightly different
  archive, see drift-guard below).
- **No-go threshold**: any variant scoring **<38/60** (i.e. >2 pts
  below the 40/60 reference) is automatically excluded from the
  defaults-flip recommendation, regardless of wallclock win. This is
  the same rubric-regression guardrail E4/E6 used.
- **Borderline**: variants at 38 or 39 with a strong wallclock win
  warrant a second-run confirmation before deciding (rubric noise on
  this corpus is ±1 pt at most due to rank-bracket discretization).
- **Score every cell with `scripts/score-rubric.py`** — script wins
  over manual counting (per `CLAUDE.md`).

## Drift guard

Per `CLAUDE.md` and the `markdown-memory corpus drift` memory: the
markdown-memory source folder is **operator-triggered**, not
continuously growing. If E7's first cell (FP32 baseline reproduction
at current defaults) produces a wallclock or rubric outside the E6.6
reference (`891.1 s`, `38/60`) by more than the E6.3 noise band
(~11.6 % wall, ±1 rubric pt), **stop and ask Adam whether he has
synced new Granola meetings into the corpus**. Do NOT treat
unexpected drift as a real finding without confirming corpus state
first. If Adam confirms a sync, re-anchor the baseline column at the
new measurement and proceed.

## Experiment grid

Suggested 6-cell grid covering the FP16 × policy plane:

| cell | precision | compute-policy | purpose |
|------|-----------|----------------|---------|
| C0   | FP32 (today) | auto (today)   | Baseline reproduction. Anchors against E6.6's 891.1 s / 38/60. Drift-guard cell. |
| C1   | FP32        | cpuOnly         | FP32-on-CPU floor. Rules out "ANE/GPU was already silently doing FP16 conversion." |
| C2   | FP32        | ane             | Reproduces E6.2/E6.3 ANE-3.8 % data point at E6.5 defaults. Anchor for the ANE-with-FP16 cell. |
| C3   | **FP16**    | auto            | Primary FP16 win-or-lose cell. Closest like-for-like swap vs C0. |
| C4   | **FP16**    | ane             | The hypothesis cell — FP16 graph + ANE policy = the combination industry suggests should give 10–30 %. |
| C5   | **FP16**    | cpuAndGPU       | FP16 on GPU. Tests whether GPU is a viable home for e5-base inference at all. |

Skipping FP16+cpuOnly (C1's question — "is CPU the floor?" — is
already answered by FP32+cpuOnly; FP16 on CPU is just slower CPU and
doesn't tell us anything useful about ANE/GPU placement).

If C4 is a clear winner (≥10 % wallclock cut, rubric ≥38), promote
to a follow-up bucket-width refinement and a defaults-flip proposal
identical in shape to E6.4 → E6.5. If C3 alone wins but C4 doesn't,
the FP16 win is precision-driven, not policy-driven, and we keep
`auto` as the default while flipping the precision lever. If neither
C3 nor C4 wins, FP16 is a no-go for e5-base; the rest of the grid
explains *why* (was it CPU-floor-dominated? was the ANE compiler
bouncing FP16 back to CPU anyway?).

## Sweep protocol

Pre-run setup (once):

1. Verify build is clean: `swift build`.
2. Confirm `markdown-memory` DB exists: `vec list`. (No `vec init`
   needed; per `CLAUDE.md` the DB is already wired to Adam's corpus.)
3. Idle cool-down ≥2 min; close non-essential apps; AC power; same
   thermal posture as E6.6 (ran on 2026-04-25/26).
4. Confirm corpus state with Adam if there's been a recent Granola
   sync (cf. drift guard).

Per-cell command (cell C0 example, FP32 + auto policy, current
defaults):

```bash
vec sweep --db markdown-memory --embedder e5-base \
  --sizes 1200 --overlap-pcts 0 \
  --compute-policy auto \
  --out benchmarks/e7-fp16/C0-fp32-auto --force
```

Cells C1–C5 vary `--compute-policy` and (for C3–C5) require an
implementation-side toggle to enable the FP16 cast in
`E5BaseEmbedder.meanPooledBatch`. **The plan does not pre-judge how
that toggle is exposed** (env var, hidden CLI flag, build-time
constant, separate `e5-base-fp16` alias) — that's an implementation
decision for the follow-up commit. The plan only commits to: every
FP16 cell is reproducible from a single archived command line, and
the FP32-vs-FP16 difference is a single `if fp16 { tensor.cast(to:
Float16.self) }`-shaped change, not a structural rewrite.

After all 6 cells run, run the scorer once per archive:

```bash
python3 scripts/score-rubric.py benchmarks/e7-fp16/C0-fp32-auto/
# … one invocation per cell directory
```

Capture results in a markdown summary table at
`data/e7-fp16-grid.md` with columns: `cell`, `precision`,
`policy`, `wall_s`, `Δ_vs_C0_pct`, `chps_wall`, `total_60`,
`top10_either`, `top10_both`, `notes`.

## Success criteria

A cell qualifies as a **winner** if either:

1. **Wallclock drop ≥10 % vs C0 with rubric ≥38/60**, OR
2. **Wallclock drop ≥15 % vs C0 with rubric ≥36/60** (allowing a
   2-pt rubric give-back if the speed win is large enough — same
   shape as the E4 pass-gate calculus).

If any cell qualifies, the follow-up is a defaults-flip proposal in
the E6.5 mold: thread the FP16 toggle through `IndexingProfile` and
`E5BaseEmbedder.init`, set the e5-base default to whichever
(precision, policy) cell won, and ship behind a single commit with
the per-model wallclock re-measurement attached. If multiple cells
qualify, prefer the one with the smaller rubric drop; tie-break on
wallclock.

If **no cell qualifies**:

- We learn that swift-embeddings' MLTensor BERT path on macOS
  26.3.1+ at 768-dim is not bandwidth-bound at FP32 the way larger
  BERT models on other stacks are. Document the finding in
  `data/e7-fp16-grid.md` and close E7 as a no-op — the
  `--compute-policy` flag stays a diagnostic; the FP16 cast does NOT
  ship.
- Note for future experimenters: a real win likely requires either
  pre-compiled `.mlmodelc` distribution (so
  `MLModelConfiguration.computePrecision = .float16` becomes
  available) or FP16 safetensors at distribution time. Both are E8+
  scope.

## Blockers / open questions

- **Is `MLTensor.cast(to: Float16.self)` actually free at graph
  construction, or does it materialize an FP16 copy?** The Apple docs
  describe `cast(to:)` as a tensor op (i.e. a graph node, lazy until
  materialization), not an eager copy. If it's eager, the cost of
  the cast itself eats some of the win and C3–C5 numbers are
  pessimistic vs a pre-loaded FP16 weight path. Verify on first
  C3 measurement: if wallclock is *worse* than C0 but rubric is
  unchanged, the cast itself is the cost.
- **Will Float16 weights silently broadcast-up to Float32 when
  multiplied by FP32 weight tensors, leaving us at FP32 anyway?**
  MLTensor's broadcast/promotion rules are not exhaustively documented
  in the public reference. If C3 shows zero wallclock delta from C0,
  this is the likely cause — the cast is a no-op in the resulting
  graph because the weight side dominates the promotion. The fix
  would be to cast each loaded weight tensor too (more invasive),
  which we'd want to test as cell C3' before declaring failure.
- **Does the masked-mean-pool produce numerically equivalent
  vectors at FP16?** The pool sums up to ~512 hidden vectors per
  row before dividing by token count. FP16's 11-bit mantissa is
  vulnerable to accumulation drift on long sums. Rubric stays the
  authoritative quality gate; if rubric drops by ≥3 pts on FP16
  cells, the fix is "do the encoder in FP16 but keep the pool in
  FP32" — a hybrid that's worth a 7th cell if needed.
- **Does swift-embeddings 0.0.26 expose any seam to override its
  internal MLTensor-construction scalar type?** Not as of v0.0.26
  (read of `Bert.loadModelBundle`). If E7 wants to pursue
  weight-side FP16 (the C3' fallback above), it would either need
  an upstream PR or a local fork — flag this to Adam before going
  down that road.
- **Does flipping FP16 affect the deterministic-rank guarantee
  E6.2/E6.3 saw across 24 ANE points?** Bit-identical retrieval at
  the rank level was a *useful* property, not a contractual one —
  E7 explicitly accepts rank-level drift as long as the
  rubric-score guardrail holds. But if the drift is asymmetric
  (FP16 helps queries 1–5, hurts 6–10), the per-query breakdown in
  `data/e7-fp16-grid.md` should call it out.

## Phase order

1. **Baseline cell C0 first** — confirms drift state and reproduces
   E6.6's 891.1 s. Single-point sweep, ~15 min wallclock.
2. **Policy-only cells C1, C2 next** — no code changes required;
   pure CLI-flag sweeps. Anchors the FP32 plane.
3. **Implementation-side FP16 toggle** — minimal change in
   `E5BaseEmbedder.meanPooledBatch`. Build, smoke-test with a
   single 1200/0 reindex against `markdown-memory`, eyeball that
   embeddings aren't all-NaN.
4. **FP16 cells C3, C4, C5** — three more sweep runs. Total grid
   ~6 × ~15 min = ~1.5 h wallclock plus rubric scoring.
5. **Write up** at `data/e7-fp16-grid.md` and add a Done entry to
   `plan.md` linking this directory.
6. **Defaults-flip proposal** (only if the success criteria fired)
   in a follow-up E7.x.

## Critical files to read before starting

- [`Sources/VecKit/E5BaseEmbedder.swift`](../../Sources/VecKit/E5BaseEmbedder.swift)
  — current `meanPooledBatch`; FP16 cast goes inside the
  `withOptionalComputePolicy` body.
- [`Sources/VecKit/EmbedderMath.swift`](../../Sources/VecKit/EmbedderMath.swift)
  — `withOptionalComputePolicy` shim. No change needed here.
- [`Sources/vec/Commands/UpdateIndexCommand.swift`](../../Sources/vec/Commands/UpdateIndexCommand.swift)
  — `ComputePolicyOption.mlPolicy` mapping. No change unless C5 needs
  an additional CLI option (it doesn't; `cpuAndGPU` is already
  spelled `gpu` in the enum).
- [`data/sweep-e5-base-speed.md`](../../data/sweep-e5-base-speed.md)
  — E6.3's 24-point grid. The (N=8, b=32) winner row is the apples-
  to-apples baseline for E7 cells (E6.5 made N=8 b=32 the default,
  so no override flags are needed in the sweep commands above).
- [`data/wallclock-2026-04-25.md`](../../data/wallclock-2026-04-25.md)
  — E6.6's per-model re-measurement. Provides the 891.1 s anchor for
  C0 drift-guard.
- [`experiments/E6.3-e5-base-speed-grid/plan.md`](../E6.3-e5-base-speed-grid/plan.md)
  — if present (the E6.3 plan may live in `plan.md` proper rather
  than its own folder; check both).
- swift-embeddings BertUtils source on GitHub:
  <https://github.com/jkrukowski/swift-embeddings/blob/main/Sources/Embeddings/Bert/BertUtils.swift>
- swift-safetensors MLTensor backend:
  <https://github.com/jkrukowski/swift-safetensors/blob/main/Sources/Safetensors/Backend/MLTensor.swift>
- HuggingFace e5-base-v2 config:
  <https://huggingface.co/intfloat/e5-base-v2/raw/main/config.json>
- Apple docs:
  - [`MLTensor`](https://developer.apple.com/documentation/coreml/mltensor)
  - [`MLTensor.cast(to:)`](https://developer.apple.com/documentation/coreml/mltensor/cast(to:))
  - [`MLComputePolicy`](https://developer.apple.com/documentation/coreml/mlcomputepolicy)
  - [`withMLTensorComputePolicy(_:_:)`](https://developer.apple.com/documentation/coreml/withmltensorcomputepolicy(_:_:))

## Risks and invariants

- **Determinism**: FP16 inference will produce different floating-
  point similarity scores than FP32; rank-level identity (E6.2/E6.3
  saw 24/24 cells bit-identical) will likely break. Rubric is the
  authoritative gate, not rank parity.
- **Cast-overhead pessimism**: a per-batch cast costs O(batch ×
  seqLen) FP32→FP16 conversions every call. If tooling can't fuse
  this with the matmul, the cast is pure overhead. Watch C3 vs C0:
  zero or negative delta on C3 = cast not paying for itself.
- **No silent-quality regression**: the 38/60 floor (or 36/60 with
  the wallclock-15 % carve-out) is the line. Below that, no flip,
  regardless of speed.
- **Single-model scope**: this experiment only targets `e5-base`. If
  it wins, the *generalization* question (does FP16 also help
  bge-base/bge-large/gte-base/mxbai-large?) is a separate sweep —
  parallel-shaped but with their own rubric baselines. Do not flip
  any other embedder's defaults from E7 alone.
- **One commit creates this plan; no code changes in this commit.**
  Per the task brief, E7 ships in stages — plan first, then a
  separate implementation commit when Adam approves the grid.
