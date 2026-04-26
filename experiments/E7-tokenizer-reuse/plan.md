# Tokenizer reuse + lifecycle optimization — Plan (E7)

Companion plan to `E7-profile-indexing` (signpost-based instrumentation).
Where the profile-indexing plan answers "where does the wall go?", this
plan answers "what about tokenization specifically can we amortize?"

The two are coupled by design: the profile plan's signposts (added
around tokenize / model-call / pool / cast scopes) are the measurement
substrate this plan uses to attribute wins to specific levers.

## Hypothesis

The `E5BaseEmbedder` (and every other Bert-family embedder) re-runs
`tokenizer.tokenizeTextsPaddingToLongest` from scratch on every
`embedDocuments` call. Per-call work that *cannot* be re-amortized:
the actual byte-pair tokenization of the input strings. Per-call work
that **can** be re-amortized: scratch-buffer allocation for the
`[Int32]` token grid and the `[Float]` attention mask, both of which
are sized as `longest * batchSize`. With E6.5 defaults
(`pool=8, batch=32, bucketWidth=500`), each worker is doing ~250–300
tokenize calls per `e5-base` reindex of markdown-memory, each
allocating two transient buffers in the 30–60 KB range — small in
isolation, but in steady state these are short-lived heap traffic
that competes with the same memory bandwidth the MLTensor encoder is
also pressuring.

Estimated savings: 5–10 % of `e5-base` wallclock at zero quality cost.
The E6.5-defaults `e5-base` baseline is **891 s** on
markdown-memory (`benchmarks/wallclock-2026-04-25/e5-base/`); a 5 %
win is ~45 s, a 10 % win is ~90 s.

## Current state — where the tokenizer lives

### Type and lifetime

`E5BaseEmbedder` is an `actor` with a single optional bundle
(`Sources/VecKit/E5BaseEmbedder.swift:40`):

```swift
private var bundle: Bert.ModelBundle?
```

`loadBundleIfNeeded()` (lines 148–155) creates the bundle exactly
once per actor instance, on first use:

```swift
private func loadBundleIfNeeded() async throws -> Bert.ModelBundle {
    if let bundle { return bundle }
    let loaded = try await Bert.loadModelBundle(
        from: "intfloat/e5-base-v2"
    )
    self.bundle = loaded
    return loaded
}
```

`Bert.loadModelBundle` (in `swift-embeddings` 0.0.26) constructs the
tokenizer once via `AutoTokenizer.from(modelFolder:tokenizerConfig:)`
and stores it on `bundle.tokenizer` as `any TextTokenizer`. The
vocab JSON is read from the on-disk HuggingFace cache once, at
bundle-load time, and reused for the bundle's lifetime. **Vocab is
not re-parsed per call.** That theoretical waste is already absent.

### How many tokenizer instances exist at runtime

The pool factory builds N independent embedder instances, one per
worker (`Sources/VecKit/IndexingPipeline.swift:834-843`):

```swift
init(factory: @Sendable () -> any Embedder, count: Int) {
    ...
    for _ in 0..<count {
        made.append(factory())
    }
    ...
}
```

At the E6.5 default `concurrency=8`, that's **8 separate
`E5BaseEmbedder` actors → 8 separate `Bert.ModelBundle` instances
→ 8 separate tokenizers**. Each tokenizer holds its own copy of
the e5-base vocab (~200K entries). No tokenizer instance is shared
across workers — the actor mailbox model would serialize all 8
workers onto the same tokenizer if we tried.

The pool's `warmAll()` (`IndexingPipeline.swift:932-940`) runs one
`embedDocument("warmup")` per instance serially, so by the time the
first real chunk arrives, every bundle has been materialized and
every tokenizer's vocab is already on the heap.

### Per-call allocation surface

The hot path on every `embedDocuments` call
(`E5BaseEmbedder.swift:97-146`) does, in order:

1. **`bundle.tokenizer.tokenizeTextsPaddingToLongest(texts, padTokenId: 0, maxLength: 512)`**
   (line 101). Inside the `swift-embeddings` default implementation,
   this:
   - allocates `[[Int32]]` of size `batchSize` to hold per-row token
     arrays;
   - finds the longest tokenized row;
   - allocates a flat `[Int32]` of `longest * batchSize` for the
     padded token grid;
   - allocates a `[Float]` of `longest * batchSize` for the attention
     mask;
   - copies each per-row token array into the flat grid, padding with
     `padTokenId` (0); and writes 1.0 / 0.0 into the mask.
   Result is a struct `(tokens: [Int32], attentionMask: [Float], shape: [Int])`.

2. **Two MLTensor scalar copies** (lines 115–120) wrap the freshly
   allocated `[Int32]` and `[Float]` into MLTensors — these copy
   the scalars *again* into MLTensor's backing storage.

3. **Two MLTensor results materialize back to Float** (line 145):
   `await pooled.cast(to: Float.self).shapedArray(of: Float.self).scalars`.
   The tensor scope ends; the buffers from steps 1–2 fall out of scope
   and become garbage.

So per call, per worker, with `batch=32` and `longest≈300` (e5-base
on markdown-memory), the steady-state transient allocation is roughly:
- `[Int32]` × 2 (tokenizer-side `tokens` + MLTensor copy): 2 × 32 ×
  300 × 4 B ≈ **75 KB** twice ≈ 150 KB churn.
- `[Float]` × 2 (mask + MLTensor copy): same shape, 4 B element ≈
  150 KB churn.
- Per-row `[[Int32]]` from BPE tokenization: bounded by the input
  texts; small relative to the above.

Total: ~300 KB of short-lived heap per batch, per worker. Across
8 workers running ~250 batches each, that's ~600 MB of allocate-and-
free traffic over the run. Whether this actually *costs* 5–10 % of
wallclock depends on whether the Swift runtime's allocator and L2
cache absorb it cheaply — that's exactly what the profile-indexing
signposts will tell us.

## What's wasteful — measurable vs theoretical

**Measurable waste** (worth attacking):

- **MLTensor copy of tokenizer output.** `MLTensor(shape:scalars:)`
  with a freshly allocated `[Int32]` does a copy. We then immediately
  drop the `[Int32]`. If MLTensor exposes a `shape:scalarsNoCopy:` or
  takes ownership, we save one copy per call. (Open question — see
  Blockers.)

- **Per-call `[Int32]` / `[Float]` re-allocation.** The shape is
  `longest * batchSize`. With length-bucketed batching (E4.B3) and
  `bucketWidth=500`, "longest" within a bucket is bounded — for
  bucket `b`, longest text length is `< (b+1) * bucketWidth`, so
  longest *token* length is bounded too (e5 BERT averages ~0.75
  tokens per character on English markdown, capped at 512 by the
  tokenizer). Pre-allocating per-bucket scratch buffers sized to
  `(b+1) * bucketWidth * 0.75` for tokens and reusing them across
  calls cuts the allocation traffic to zero in steady state.

- **Vocab is loaded 8× into RAM.** Each of the 8 worker actors holds
  a private copy of the e5-base vocab (~200K BPE merges, plus
  config). For e5-base specifically that's modest (~10 MB × 8 ≈ 80
  MB), but bge-large / mxbai-large have larger vocabs and the same
  multiplier applies.

**Theoretical waste** (likely *not* worth attacking):

- **Vocab re-parsing per call.** Already absent — `loadModelBundle`
  parses once at bundle init.

- **Tokenizer re-instantiation per call.** Already absent — bundle is
  cached on the actor (`E5BaseEmbedder.swift:148-155`).

- **BPE merge work itself.** This is the actual tokenization
  computation. There's no obvious algorithmic improvement at this
  layer; chunks differ run-to-run, so we can't memoize.

## Levers

Each lever is independently shippable and independently measurable.
Order is "easiest to validate first."

### L1 — Pre-allocate scratch buffers per actor

State on the actor:

```swift
private var tokenScratch: [Int32] = []
private var maskScratch: [Float] = []
```

Reuse them across calls; only grow when `longest * batchSize` exceeds
current capacity. Requires a tokenizer-side change (or a custom
tokenize helper) so the scratch buffers can be filled in place
instead of allocated fresh. Saves the ~300 KB / batch / worker churn
identified above.

**Estimated lift**: 1–3 %.

### L2 — Avoid the MLTensor scalar copy

If `MLTensor(shape:scalars:)` always copies, this lever is just an
artifact of the swift-embeddings tokenizer returning Swift arrays
rather than MLTensors. A tokenizer that built `MLTensor` directly
would skip step 2 entirely. Two paths:

- L2a — write a thin `tokenizeIntoMLTensor` shim that calls into the
  same BPE merge code but appends into pre-allocated MLTensor-backed
  buffers (if the swift-embeddings/MLTensor APIs allow this).
- L2b — keep the Swift-array intermediate but use
  `MLTensor(shape:scalarsNoCopy:)` *if it exists*. This is the cheap
  variant; needs API verification (see Blockers).

**Estimated lift**: 1–4 %.

### L3 — Bucket-width-keyed scratch pools

Combine L1 with the existing batch-former buckets. The
`IndexingPipeline.bucketWidth = 500` (default per E6.4) means each
bucket carries chunks within ~500 chars of each other. Allocate one
scratch pair per active bucket, sized to `(bucket_id + 1) *
bucketWidth * 0.75 * batchSize`. Across runs the bucket shape
stabilizes; we converge to a small set of long-lived buffers.

**Caveat**: scratch-pool ownership doesn't sit naturally on the
embedder actor (the embedder doesn't know about buckets). Cleaner
factoring is for the *batch-former* to attach a scratch handle to
each `BatchWork`, but that crosses module lines. Worth doing only
if L1 alone shows < 3 %.

**Estimated lift**: marginal vs L1 (≤ 1 %) — L1 already amortizes
the largest allocation; L3 only avoids the occasional resize.

### L4 — Share one tokenizer across the 8 workers

If `any TextTokenizer` is `Sendable` and stateless w.r.t. its
tokenize methods (which the protocol requires — see Blockers), we
could replace 8 per-actor tokenizers with one shared instance,
queried from each actor. Saves 7× vocab RAM and reduces cold-page
pressure. **Does NOT save wallclock** unless tokenization itself is
contending for memory bandwidth at steady state — and the actor-
mailbox concurrency model would serialize all 8 workers' tokenize
calls onto the shared instance, which could regress.

**Estimated lift**: 0 % (RAM-only; possibly a regression on wall).
Listed for completeness; **defer unless RAM becomes a constraint**.

### Out of scope

- Switching tokenizer implementations (e.g. a hand-rolled BPE).
  Bigger surface, real correctness risk, and the vocab-load is
  already amortized.
- Tokenizing on the GPU. Not feasible with the current
  swift-embeddings API.

## Validation strategy

Each lever is gated by the same three questions, in order:

1. **Did the targeted scope actually shrink?** Measured via
   signposts added by the companion plan
   (`E7-profile-indexing`). The relevant signpost intervals:
   - `tokenize` — wraps `bundle.tokenizer.tokenizeTextsPaddingToLongest`
     (`E5BaseEmbedder.swift:101-102`).
   - `mltensor-build` — wraps the two `MLTensor(shape:scalars:)`
     constructions (lines 115-120).
   - `model-call` — wraps `bundle.model(...)` (line 126).
   - `materialize` — wraps `await pooled.cast(...).shapedArray(...).scalars`
     (line 145).
   The lever passes step 1 if its targeted scope's summed time drops
   by ≥ the per-lift estimate, run-to-run-noise considered (see
   §Experiment protocol for noise band).

2. **Did wallclock drop by an amount consistent with the scope shrink?**
   If the scope shrank by 200 ms total but wall stayed flat, the
   work moved sideways into another scope (e.g. allocator pressure
   relocated to MLTensor's own scratch path) — net-zero, not a real
   win. Reject.

3. **Did vector quality stay byte-identical?** See §Quality guard
   below. Mandatory.

## Quality guard

Tokenizer changes — even pure allocation rearrangements — must
produce **byte-identical token sequences** for every input. Any
divergence here means the lever silently changed embeddings, which
trashes retrieval quality and invalidates every prior measurement.
Since float embeddings depend non-linearly on token IDs, even a
single off-by-one in special-token handling propagates everywhere.

### Verification step (run before any wallclock measurement)

Add a one-shot test target `Tests/VecKitTests/TokenizerEquivalenceTests.swift`
that:

1. Loads a sample of 500 chunks from the markdown-memory corpus
   (deterministic seed; reuse the rubric query files for stability).
   Mix of lengths from 50 to 2000 chars to exercise the padding path.
2. Tokenizes each chunk through the **OLD** path
   (`bundle.tokenizer.tokenizeTextsPaddingToLongest`) at
   `batch=32, padTokenId=0, maxLength=512`.
3. Tokenizes the same chunks through the **NEW** path (post-lever).
4. Asserts:
   - `shape` arrays are element-wise equal.
   - `tokens: [Int32]` arrays are element-wise equal at every index
     (not just `==` — print the first divergence index on failure).
   - `attentionMask: [Float]` arrays are bit-identical
     (`memcmp`-equivalent on the underlying `[Float]`).
5. Runs again with `batch=1` and `batch=8` to cover the smaller-
   batch paths the pipeline takes near corpus boundaries.

If any assertion fails, the lever is reverted, no exceptions. The
test runs in CI for any PR touching `E5BaseEmbedder.swift` or
`Sources/VecKit/*Tokenizer*`.

### A quieter sanity check at the embedding level

After the tokenizer test passes, compare a small embedding sample:
embed 50 chunks via `embedDocuments` on OLD vs NEW; assert each
output vector is bit-identical (they must be — same tokens →
same MLTensor inputs → same model output → same Float bits, modulo
GPU-driver non-determinism we already accept). This is belt-and-
suspenders against any non-tokenizer regression slipped in
alongside.

## Experiment protocol

All wallclock measurements use the same shape as
`data/wallclock-2026-04-25.md` (E6.6) so results are directly
comparable to the recorded `e5-base` baseline of **891 s**.

### Per-lever measurement recipe

```bash
# Build at HEAD with lever applied
swift build -c release

# Sweep one grid point at the E6.5 defaults
vec sweep --db markdown-memory --embedder e5-base \
  --sizes 1200 --overlap-pcts 0 \
  --out benchmarks/e7-tokenizer-<lever>/ --force
```

Record three runs back-to-back per lever (idle cool-down ≥ 2 min
between runs to match E6.6 conditions) — wallclock variance on this
host runs ~1–2 % between adjacent runs. The lever passes only if the
median of three runs beats the baseline by more than the 95th-
percentile run-to-run variance, which empirically on this host is
~3 % on `e5-base`. Anything inside that band is "in noise" and
counts as a non-result.

### Baseline replay (sanity)

Before measuring the first lever, re-run the baseline at HEAD on
the current corpus to confirm we still hit 891 s ± 3 %. If the
corpus has drifted (Granola sync; per CLAUDE.md instructions, ask
Adam before treating an unexpected delta as real), record the
new baseline and use it as the comparator.

### Per-lever wallclock comparison

| run | command | expected wall |
|-----|---------|--------------:|
| baseline | `vec sweep ... --embedder e5-base` (HEAD) | 891 s |
| L1 | same, with L1 applied | ≤ 864 s (−3 %) |
| L1+L2 | same, both applied | ≤ 846 s (−5 %) |
| L1+L2+L3 | same, all three applied | ≤ 837 s (−6 %) |

Each row also records: the signpost-attributed time in `tokenize`,
`mltensor-build`, `model-call`, `materialize` (from the companion
profile-indexing plan); the rubric `total /60` from
`scripts/score-rubric.py`; and the per-chunk wall (`total / 8070`).

### Rubric guard

After each lever's wallclock measurement, run the rubric:

```bash
vec sweep --db markdown-memory --embedder e5-base \
  --sizes 1200 --overlap-pcts 0 --rubric \
  --out benchmarks/e7-tokenizer-<lever>/ --force
python3 scripts/score-rubric.py benchmarks/e7-tokenizer-<lever>/
```

Expected: 38/60 (the E6.6-recorded `e5-base` total). Any deviation
of more than ±0 (we expect *bit-identical*) is a hard fail and the
lever is reverted regardless of wallclock improvement.

## Success criteria

A lever **ships** if and only if:

1. Median-of-3 wallclock improves by **≥ 3 %** over baseline (or
   over the previous lever's confirmed result, when stacking).
2. `python3 scripts/score-rubric.py` returns **bit-identical**
   per-query ranks vs baseline (38/60 on the current corpus, every
   query at the same rank).
3. `TokenizerEquivalenceTests` passes on a 500-chunk sample at
   `batch ∈ {1, 8, 32}`.

A **stack** of levers (L1+L2, L1+L2+L3) ships if median-of-3
combined wallclock improves by **≥ 5 %** over baseline AND every
prior gate still holds.

Anything below these thresholds is a non-result. **Do not ship for
its own sake** — the simpler code is the per-call-allocate version;
keep it unless we earn the complexity with measured wins.

## Blockers / open questions

1. **Does `MLTensor(shape:scalars:)` always copy?** L2 hinges on
   this. Apple's MLTensor docs are sparse; need to read the swift-
   embeddings issue tracker and the MLTensor headers to confirm.
   If a no-copy variant exists, L2 is straightforward; if not,
   L2 collapses to "rewrite the tokenizer to build MLTensors
   directly" which is a much bigger change and might not be worth
   it for ~1–4 %.

2. **Is `any TextTokenizer` actually thread-safe across simultaneous
   calls?** The protocol declares `Sendable` (per
   `swift-embeddings` 0.0.26 `Sources/Embeddings/Tokenizer/TextTokenizer.swift`)
   which is the necessary condition for L4. But the concrete
   implementation (`TokenizerWrapper` around `swift-transformers`
   `AutoTokenizer`) may hold mutable internal state under the hood.
   L4 is deferred anyway, but if RAM ever becomes a forcing function,
   we need to read `TokenizerWrapper`'s impl before assuming safety.

3. **Does the swift-embeddings tokenizer expose any "fill-in-place"
   API?** The default protocol implementation of
   `tokenizeTextsPaddingToLongest` allocates fresh arrays. L1 needs
   either:
   - a new method that takes pre-allocated `inout [Int32]` /
     `inout [Float]` buffers and a row count, OR
   - a rewrite of the tokenize call inside `E5BaseEmbedder` that
     calls `tokenizer.tokenizeText(_:maxLength:)` per row and packs
     into our own scratch buffers. The second path avoids upstream
     changes; the first is cleaner but blocks on jkrukowski merging
     a PR.

4. **Per-actor scratch buffers and Swift `actor` reentrancy.** Each
   `embedDocuments` call is a single suspension point on the actor
   (the `await pooled.cast(...).shapedArray(...)` materialization).
   Swift actors are reentrant — another `embedDocuments` call could
   land between the suspension and resume on the same actor. If
   that ever happens (it shouldn't, because `EmbedderPool` is
   strict one-worker-per-instance — see
   `IndexingPipeline.swift:798-808`), the scratch buffer would
   alias and corrupt. The pool invariant makes this safe today;
   the L1 lever should still add a precondition guarding the
   invariant explicitly so a future pool refactor can't break it
   silently.

5. **Does L1 generalize to BGE / mxbai / gte / nomic?** All five
   Bert-family embedders use the same per-call alloc pattern (see
   `BGEBaseEmbedder.swift:46`, `MxbaiEmbedLargeEmbedder.swift:65`).
   If L1 works on e5-base, the same lever should drop into each.
   But E6.6 showed wildly different per-model wallclock responses
   to the E6.3 grid (e5-base −13 %, gte-base +65 %); per-model
   confirmation is mandatory before flipping defaults across the
   family. **Scope of this experiment**: e5-base only. Other
   models become an E7.x follow-up only if e5-base earns ≥ 5 %.

6. **Is the win there at all?** This whole plan rests on the
   assumption that 300 KB/batch of allocation churn is contributing
   meaningfully to a 891-s wallclock. Step zero — **before any
   lever** — is the companion E7-profile-indexing run, which will
   tell us what fraction of e5-base wallclock is *actually* spent
   in `tokenize` + `mltensor-build` vs `model-call`. If the
   tokenize+build scopes together are < 3 % of wall, **abandon
   this experiment**: there is no 5 % win to be had at the
   tokenizer layer, and the bottleneck is elsewhere.

## File-by-file diff checklist (when implementing, not in this commit)

- `Sources/VecKit/E5BaseEmbedder.swift` — add `tokenScratch` /
  `maskScratch` actor state; rewrite the tokenize call site
  (lines 101–102) to use scratch buffers; add precondition on
  one-worker-per-actor.
- `Tests/VecKitTests/TokenizerEquivalenceTests.swift` — new file,
  per the §Quality guard recipe.
- `experiments/E7-tokenizer-reuse/report.md` — created at the end
  with measured per-lever wallclock and the lever-ship decisions.
- `experiments/E7-tokenizer-reuse/commits.md` — SHAs and per-run
  benchmark dirs.
- `plan.md` — Done entry on completion.

This commit covers **only** the plan file. No code changes.

## Critical files to read before starting implementation

- `Sources/VecKit/E5BaseEmbedder.swift` — actor + tokenize call site.
- `Sources/VecKit/IndexingPipeline.swift` — pool factory
  (`EmbedderPool.init`, lines 834-843), one-worker-per-instance
  invariant (lines 798-808), batch-former (lines 429-467) for L3.
- `swift-embeddings` 0.0.26 `Sources/Embeddings/Tokenizer/TextTokenizer.swift`
  — protocol + default implementation that does the per-call
  allocations.
- `swift-embeddings` 0.0.26 `Sources/Embeddings/Bert/BertModel.swift`
  + `BertUtils.swift` — `loadModelBundle` and `AutoTokenizer.from`
  call site, to confirm vocab is loaded once.
- The companion `E7-profile-indexing/plan.md` — for the signpost
  scopes this plan validates against.
- `data/wallclock-2026-04-25.md` and
  `benchmarks/wallclock-2026-04-25/e5-base/` — the 891-s baseline
  this plan compares to.
