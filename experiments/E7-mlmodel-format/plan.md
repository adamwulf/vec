# E7 — CoreML model format & backend variants for e5-base wallclock

Goal: cut e5-base wallclock ≥10 % on `markdown-memory` while keeping
the rubric ≥38/60 (current default = 40/60 at `e5-base@1200/0`,
~937 s post-E6.3 defaults flip — see `plan.md` "Current state").

PLAN ONLY. No code changes, no sweeps in this commit. The plan lays
out what we'd test if/when we promote it to E7.x execution slots.

---

## 1 · Premise check: what format does swift-embeddings actually produce?

**Answer: neither MLProgram nor NeuralNetwork. There is no `.mlmodel`,
`.mlpackage`, or `.mlmodelc` file in the e5-base inference path at
all.**

`Bert.loadModelBundle(from: "intfloat/e5-base-v2")` (called from
[`Sources/VecKit/E5BaseEmbedder.swift:150-152`](../../Sources/VecKit/E5BaseEmbedder.swift))
resolves to swift-embeddings 0.0.26's
[`Bert/BertUtils.swift` `loadModelBundle`](https://github.com/jkrukowski/swift-embeddings/blob/0.0.26/Sources/Embeddings/Bert/BertUtils.swift),
which:

```swift
public static func loadModelBundle(
    from modelFolder: URL,
    loadConfig: LoadConfig = LoadConfig()
) async throws -> Bert.ModelBundle {
    let tokenizer = try await AutoTokenizer.from(...)
    let weightsUrl  = modelFolder.appendingPathComponent(loadConfig.modelConfig.weightsFileName)
    let configUrl   = modelFolder.appendingPathComponent(loadConfig.modelConfig.configFileName)
    let config      = try Bert.loadConfig(at: configUrl)
    let model       = try Bert.loadModel(weightsUrl: weightsUrl, config: config, loadConfig: loadConfig)
    return Bert.ModelBundle(model: model, tokenizer: TokenizerWrapper(tokenizer))
}
```

`Bert.loadModel` reads **safetensors** (`Safetensors.read(at:
weightsUrl)`) and wires the weights into a `Bert.Model` built from
`MLTensorUtils.linear / embedding / layerNorm` calls — i.e. it
constructs an `MLTensor` computation graph at runtime, not an
`MLModel`. `Bert.Model` itself
([BertModel.swift](https://github.com/jkrukowski/swift-embeddings/blob/0.0.26/Sources/Embeddings/Bert/BertModel.swift))
is a plain `struct` of layer structs whose `callAsFunction(inputIds:tokenTypeIds:attentionMask:)`
returns `(sequenceOutput: MLTensor, pooledOutput: MLTensor)`. There is
no `MLModel.compileModel(at:)`, no `MLModelConfiguration`, no
`computeUnits` setter — the only knob exposed today is the task-local
`MLComputePolicy` we already wrap via `withOptionalComputePolicy(...)`
in `E5BaseEmbedder.meanPooledBatch` (E6.1 work, lines 114–143).

That makes the original framing of this experiment ("MLProgram vs
NeuralNetwork", "modelDisplayName", "MLModelConfiguration knobs")
**not directly applicable** to the current code path. The
`MLProgram`/`NeuralNetwork` choice is a property of compiled CoreML
model files; MLTensor graphs are JIT-compiled from Swift each time
they're constructed inside `withMLTensorComputePolicy`. This is a
much bigger lever than a config flip — we'd need to *replace* the
swift-embeddings inference path, not tune it.

The plan below therefore reframes the levers around what's actually
reachable: the MLTensor graph compile cache, the precision passed
into the graph, and (the big one) an opt-out path that converts
e5-base to a packaged `.mlpackage` we load via `MLModel`.

---

## 2 · What does the ANE actually want?

From [`MLComputePolicy`](https://developer.apple.com/documentation/coreml/mlcomputepolicy)
and [`withMLTensorComputePolicy(_:_:)`](https://developer.apple.com/documentation/coreml/withmltensorcomputepolicy(_:_:)):

> Calls the given closure within a task-local context using the
> specified compute policy to influence what compute device tensor
> operations are executed on.

`MLComputePolicy` is a *hint* the runtime considers when placing each
op — there is no Apple-documented requirement that the underlying
graph be MLProgram for ANE eligibility. But on packaged CoreML models
(`MLModel(contentsOf:configuration:)` with
[`MLModelConfiguration.computeUnits`](https://developer.apple.com/documentation/coreml/mlmodelconfiguration)
= `.all` or `.cpuAndNeuralEngine`) the ANE path is widely reported
(Apple WWDC '22 "Optimize machine learning for Metal" / WWDC '23
"Improve Core ML integration with async prediction") to require:

- **MLProgram model type** (the modern, MIL-based representation;
  NeuralNetwork is the legacy proto-based one and exposes a smaller
  ANE op set).
- **Float16 weights and activations.** ANE is FP16-native; FP32
  weights either fall back to GPU/CPU or get implicitly cast at load
  time (with the cast eating a chunk of any speedup).
- Static shapes preferred. Dynamic shapes can run on ANE in current
  CoreML but with reduced op coverage.

E6.2's probe (`data/e6-2-ane-probe.md`) showed the MLTensor path
under `.computePolicy(.cpuAndNeuralEngine)` ran clean and saved 3.8 %
wall — the modesty of that win is consistent with the scheduler
falling back to CPU/GPU for many subgraphs. We don't currently know
which ops actually dispatched to ANE; powermetrics or a CoreML
performance report would tell us, but neither is wired in.

---

## 3 · Levers (reachable variants, ordered by cost)

### Lever A — MLTensor input precision: feed FP16 instead of FP32 (cheap)

Inside `meanPooledBatch` we currently build:

```swift
let inputIds       = MLTensor(shape: ..., scalars: batchTokenize.tokens)         // Int32
let attentionMask  = MLTensor(shape: ..., scalars: batchTokenize.attentionMask)  // Float32
```

`tokens` are integer ids — already small. `attentionMask` is
`[Float]` (FP32). Cast it to `Float16` before passing to the model so
the multiply against `sequenceOutput` doesn't force an FP32
materialization, and the masked sum stays in FP16 until the final
`pooled.cast(to: Float.self).shapedArray(...)` materialization for
output. Cost: ~5 lines. Risk: the mean-pool denominator (token
counts) might lose precision in FP16 — token counts up to 512 fit
exactly in FP16's 11-bit mantissa, so this is safe.

Question this opens: do the model weights themselves materialize as
FP32 or FP16 inside `MLTensorUtils.linear`? Need to read
[`MLTensorUtils`](https://github.com/jkrukowski/swift-embeddings/tree/0.0.26/Sources/MLTensorUtils)
to see how weights are wrapped (likely `MLTensor(shape:scalars:)` —
also FP32 by default). If yes, cast each weight tensor at load time
or fork swift-embeddings to do so. The fork would be very small —
single file edit in `BertModel.swift` weight constructors.

### Lever B — Cache the MLTensor graph between batches (cheap, possibly already done)

`withMLTensorComputePolicy` is a task-local context; the compiled
MIL/Metal kernels for the BERT graph are constructed inside that
closure on every `meanPooledBatch` call. CoreML caches compiled
kernels by graph identity, but the graph identity depends on tensor
shapes — and our `seqLen` varies per batch (we pad-to-longest, not
pad-to-512). That likely defeats the cache for the worker pool's
heterogeneous batches.

Variant B1: **pad to fixed seqLen=512 always** so the graph is shape-
identical across all batches. Cost: per-batch FLOPs go up (we do work
on padding tokens that the mask zeros out anyway). Whether this is a
net win depends on the cache-hit savings vs the wasted compute. Worth
measuring but risk of a wallclock regression is real.

Variant B2: **pad to a fixed bucket grid** (256 / 384 / 512 token
buckets) so we have at most 3 distinct graph shapes — limits cache
churn while not paying full pad cost. Couples with the existing
`--bucket-width` knob from E6.4 but at the seqLen/token level rather
than the chunk-character level. Could share infrastructure.

### Lever C — Convert e5-base to a packaged `.mlpackage` (expensive, biggest upside)

This is the only lever that actually puts the MLProgram-vs-
NeuralNetwork question in play. Plan:

1. Use `coremltools` (Python) on a separate machine to convert
   `intfloat/e5-base-v2` from HF safetensors → `.mlpackage` with:
   - `model_format=mlprogram`
   - `compute_precision=ct.precision.FLOAT16`
   - Static input shape `[1, 512]` (one variant) or several enumerated
     shapes (another variant).
   - Mean-pool + L2-normalize folded into the graph (so we don't have
     to do them in Swift).
2. Ship the `.mlpackage` either bundled in the binary (large — ~440 MB
   for the FP32 e5-base, ~220 MB FP16) or downloaded once on first
   use into `~/.vec/_models/`.
3. Add an `MLPackageE5BaseEmbedder` that loads via
   `MLModel(contentsOf: url, configuration: cfg)` with `cfg.computeUnits
   = .all`, then calls `MLModel.prediction(from:)` per batch. Old
   `E5BaseEmbedder` stays as a fallback / for anyone who wants to
   tweak the pool math in Swift.
4. Pre-compile the .mlpackage to `.mlmodelc` at first load via
   `MLModel.compileModel(at:)` and cache the path on disk so cold
   starts after the first one skip the JIT step.

Open knobs to sweep on this variant:
- `compute_precision` ∈ `{FLOAT16, FLOAT32}` (the FP16 vs FP32 A/B
  on the same packaging).
- `compute_units` ∈ `{.all, .cpuAndNeuralEngine, .cpuAndGPU,
  .cpuOnly}` (analogous to today's `--compute-policy` flag but for
  packaged models).
- Static-shape `[1,512]` vs flexible shape enumeration.

Cost: substantial. Adds a Python toolchain step, a binary asset
question, a new embedder type, and forks the inference path. Only
worth it if Levers A/B don't hit the ≥10 % bar.

### Lever D — INT8 weight quantization on the packaged model (high risk)

Once we have a `.mlpackage` (Lever C), `coremltools.optimize.coreml.
linear_quantize_weights(...)` can drop weights from FP16 → INT8 with
per-channel scales. Apple's WWDC '24 "Bring your machine learning
and AI models to Apple silicon" reports 1.3–2× ANE throughput wins
on small transformers, with quality cost typically <1 % on
classification but unmeasured for retrieval embeddings.

**Quality risk is real for embeddings.** A 0.5 % cosine-similarity
shift is invisible on classification accuracy but can rerank our
rubric's tight clusters. Treat this as a *separate sub-experiment*
gated on Lever C shipping and on careful rubric replay. Likely
disposition: investigate, but expect to bench it if rubric drops
below 38/60.

### Lever E — Compile cache on disk (cheap, possibly small)

If we ever ship Lever C, `MLModel.compileModel(at:)` produces an
`.mlmodelc` directory we can stash next to the source `.mlpackage`.
Subsequent loads point `MLModel(contentsOf:)` at the cached
`.mlmodelc` and skip recompilation. Saves cold-start time, not steady-
state wallclock — likely <1 % of a 937 s reindex but a real UX win
for short jobs.

---

## 4 · Quality guard

Every variant scores the canonical 10-query rubric via
`scripts/score-rubric.py` against `markdown-memory`. Pass gate:

- **TOTAL ≥38/60** (current baseline 40/60 — the −2 budget is the
  same one E6.x experiments operated under).
- **No worse than −1 on `TOP10_BOTH`** (currently 6/10).
- **Bit-identical T/S ranks** are a *soft* expectation for FP16-only
  changes (Lever A). Float drift is allowed; rank changes are flagged
  for inspection.

If any variant misses the gate, archive the run, do not flip a
default, and continue to the next lever.

---

## 5 · Experiment protocol

### Pre-flight: confirm the corpus is stable

Per CLAUDE.md, ask Adam whether he's synced new Granola meetings
since the last `markdown-memory` baseline. If yes, re-take the
baseline before starting any lever's A/B. If no, the existing
post-E6.3 baseline (~937 s, 40/60) is the comparison point.

### Per-lever sweep recipe

Each lever's "ON" run uses the exact same `vec sweep` invocation as
its baseline; the only thing that changes is the embedder build /
config. One sweep point per variant, at the current default geometry:

```bash
swift run -c release vec reset --db markdown-memory --force
# build with the variant's flag/build setting
swift run -c release vec sweep --db markdown-memory \
    --embedder e5-base \
    --sizes 1200 --overlap-pcts 0 \
    --compute-policy ane \
    --out benchmarks/e7-<lever>-<variant> --force
```

Capture in each per-lever directory:
- `benchmarks/e7-<lever>-<variant>/e5-base-1200-0/` — full archive
  (q01..q10.json + summary.md).
- A `commits.md` row recording: lever, variant, wall_s, chps_wall,
  TOTAL, TOP10_either, TOP10_both, ranking-diff vs baseline.

Wallclock measurement uses the same in-pipeline `[verbose-stats]`
line E6.x relies on; no need to reintroduce `time` wrappers. Single-
point sweeps are sufficient since we're A/B-ing one geometry, but if
a lever shows a >10 % win we should re-measure twice for noise-band
confirmation (E6.6 found wallclock noise ±1 %).

### Lever ordering

1. **Lever B1** (pad to 512) — cheapest, no fork, isolates the
   graph-cache hypothesis.
2. **Lever A** (FP16 attention mask + cast) — also cheap, isolates
   the precision hypothesis.
3. **Lever B2** (bucket-pad seqLen) only if B1 was a win and A
   didn't already saturate the headroom.
4. **Lever C** (convert to .mlpackage) — only if A+B together miss
   the 10 % bar. Big lift, separate sub-plan when promoted.
5. **Lever E** (compile cache) — folded into Lever C work; not a
   standalone variant.
6. **Lever D** (INT8) — only after Lever C ships and only with an
   explicit go-ahead on quality risk.

---

## 6 · Success criteria

- **Primary**: at least one lever delivers ≥10 % wallclock cut
  (i.e. wall ≤ ~843 s on the ~937 s baseline) with rubric ≥38/60.
- **Secondary**: identify whether the MLTensor graph compile-cache
  hypothesis (Lever B) is real, independent of whether the win is
  ≥10 %. If B1 cuts >2 % wall, the hypothesis is confirmed and
  motivates B2 / future bucket work.
- **Defaults flip**: if a lever ships, follow the existing
  defaults-update rule (≥5 % wallclock win → flip default; document
  in `plan.md` Done table; record measurement noise band).

---

## 7 · Blockers / open questions

1. **Does swift-embeddings expose any knob for FP16 weights or graph
   shape pinning?** (Looks like no — `LoadConfig` only carries
   tokenizer + weight filename. Confirm by reading
   `Sources/Embeddings/Common/LoadConfig.swift` or equivalent at the
   0.0.26 tag.) If no knob exists, Levers A and B require either a
   local fork of swift-embeddings or a copy of the relevant
   `BertModel.swift` paths into our `Sources/VecKit`. Our preference
   is the latter — vendoring keeps the dependency clean.

2. **Where does the existing JIT-compile cost actually land?** We
   don't currently log per-batch graph-construction time vs per-batch
   inference time. Without that split, the Lever B "graph cache"
   hypothesis is speculative. A one-line `Date()` instrumentation
   inside `meanPooledBatch` (around the `withOptionalComputePolicy`
   call vs around the `await pooled.cast(...).shapedArray(...)`)
   would tell us. Worth doing as a 5-minute prelude before any Lever B
   sweep.

3. **What's the `coremltools` story?** We don't currently ship a
   Python toolchain alongside `vec`. Lever C's converted `.mlpackage`
   would be produced once on a dev machine and committed/distributed,
   not regenerated on the fly. Decide: bundle in repo? Download on
   first use? Out of scope for the plan, in scope for Lever C
   execution.

4. **Will MLProgram + FP16 + ANE actually beat MLTensor + FP16 + ANE
   on this graph shape?** Apple's general guidance says yes; we have
   no first-party data on the e5-base BERT graph specifically. The
   only honest answer is "measure", which is exactly what Lever C
   exists to do. If Lever C ships at parity with Lever A+B, the
   complexity tax isn't worth it and we revert.

5. **Is there a way to inspect which ops dispatched to ANE on the
   current MLTensor path?** `MLComputePlan` (CoreML 18+) gives a
   per-op device assignment for `MLModel`-loaded models. There's no
   equivalent introspection API for MLTensor graphs that we know of.
   This is an indirect motivation for Lever C: a packaged model is
   *inspectable* via `MLComputePlan` in a way the current path is
   not. Worth asking Apple via DTS if Lever A+B succeed and we want
   to understand why.

6. **Does the corpus drift gate (CLAUDE.md) need its own opening
   step?** Yes — see §5 "Pre-flight". Listed here for completeness.
