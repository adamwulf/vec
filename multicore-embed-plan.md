# Multi-core Embedding — Experiment Plan

Agent: `agent-c54ba5da` (2026-04-20)

## Problem

Reindex at bge-base@1200/240 reports `util=199%` with `workers=10` — we
get roughly 2 cores of embed throughput despite spawning 10 workers.
Both `BGEBaseEmbedder` and `NomicEmbedder` are declared `public actor`,
so every `embed()` call serializes through the embedder's actor mailbox.
The `EmbedderPool` wrapping them holds exactly **one** instance (see
`IndexingPipeline.swift:179`: `EmbedderPool(embedder: profile.embedder)`),
so all 10 workers contend for the same actor.

Observed on the 1200/360 bge-base run: `wall=2828s, embed=6738s (sum),
p50_embed=6.57s, p95_embed=26.4s`. The p95/p50 ratio of 4× is classic
actor-mailbox queueing.

## Goal

Raise embed stage utilization from ~200% toward `workerCount × 100%`
(ideally ≥600% on this 10-core machine) without changing retrieval
quality. Verification is empirical: rerun `vec update-index --verbose`
and read `util=N%` from `[verbose-stats]`, cross-checked with `top`
during the run.

## Verification protocol (baseline + every iteration)

1. `vec reset markdown-memory --force`
2. `time vec update-index --verbose 2>&1 | tee .reindex-multicore-<iter>.log`
3. Capture the `[verbose-stats]` line — `wall`, `embed`, `util`,
   `p50_embed`, `p95_embed`. Also record wall-clock from `time`.
4. Run the 10 bean-counter queries against the fresh index, score, and
   confirm total ≥ 37/60 and top-10 ≥ 8/10 (vs current 39/60, 9/10 —
   allow ±2 pt rubric noise; retrieval MUST NOT regress materially).
5. One-line row in the results table below: iter, change, wall, util,
   p50, p95, rubric total, top-10.

Baseline to beat: **1200/240 @ 39/60, 9/10, wall≈2520s, util≈200%.**

A fix is "successful" if `util` rises ≥2× and rubric holds steady.

## Experiments (run in order; stop at first that hits the target)

### E1 — Pool of N embedder instances (cheapest, most-likely win)

**Hypothesis.** `BGEBaseEmbedder` is a Swift `actor`, which serializes
calls into its mailbox. `Bert.ModelBundle` (the underlying
swift-embeddings type) is declared `Sendable` (verified:
`BertModel.swift:371`), so concurrent `encode()` calls on the same
bundle should be safe — but we never get there because the actor hop
happens first.

**Change.** In `IndexingPipeline`, replace the single-embedder
`EmbedderPool` with a pool of `workerCount` independently-constructed
embedder instances. Each worker acquires one instance, runs `embed`,
returns it. Bundle load is cached per instance via `loadBundleIfNeeded`,
but all instances share the same model cache on disk, so the N-way
warmup cost is mostly RAM, not download.

Implementation sketch:
- `EmbedderPool` becomes a bounded pool backed by an `AsyncSemaphore`
  or a simple actor holding an array of instances.
- Constructor takes a factory `@Sendable () -> any Embedder` so the
  pipeline can mint N copies from the profile's alias.
- `IndexingProfile.make` already returns a fresh embedder each call
  (per phase 3b), so we can reuse that plumbing — `IndexingProfile`
  gains a `makeSibling()` method, or `IndexingPipeline` accepts a
  factory closure.

**Risk.** Memory. 10× bge-base weight tensors ≈ 10 × ~440 MB on-disk
(MLX compresses, but we should measure RSS after warmup). If the
machine is memory-bound, reduce `workerCount` or fall back to E2.

**Exit criterion.** util ≥ 600% OR RSS > 6 GB after warmup (back off).

### E2 — Strip actor isolation, make embedder a struct (if E1 still bottlenecks)

**Hypothesis.** Even with N instances, the embedder still pays an
actor hop per call. If E1 shows util plateauing below the theoretical
cap, the hops themselves may be serialization points on the global
cooperative thread pool.

**Change.** Convert `BGEBaseEmbedder` / `NomicEmbedder` from `actor`
to a `struct` (or `final class`) that holds the lazily-loaded
`ModelBundle` behind an `OSAllocatedUnfairLock` (or a simple
`NSLock`-protected load-once). `Bundle.encode` is already thread-safe
per the Sendable declaration, so after the lock-protected load, the
hot path is lock-free.

**Risk.** The `bundle = nil → loaded` transition is a mutation.
Needs careful atomic publication (dispatch_once-style
`LockIsolated<Bundle?>`).

**Exit criterion.** util ≥ 800% OR complexity is judged not worth it.

### E3 — Measure & tune MLX internal parallelism (if E1/E2 still leave cores idle)

**Hypothesis.** The ~200% we see today already includes MLX/BNNS
auto-parallelism for a single inference. If MLX uses N threads per
call, stacking 10 concurrent calls could oversubscribe the scheduler
and hurt throughput.

**Change.** Probe for an `MLX.setThreadCount(1)` (or env var) knob; if
one exists, pin MLX to 1 thread per inference so outer parallelism is
purely the worker count. Compare.

**Risk.** Per-call latency rises. Net throughput may still win, but
only measure this if E1/E2 didn't already saturate.

**Exit criterion.** Net throughput wins vs E1+E2 best.

## Review cycle

Each experiment lands on its own commit. After each commit, run the
`review-cycle` skill with 2 focused reviewers:

- **Correctness / concurrency**: ensure Sendable guarantees hold, no
  data races on the lazy-load path, no leaked instances.
- **Architecture / regression**: ensure the change is minimal, follows
  existing `IndexingPipeline` structure, and no existing tests loosen
  their invariants.

Only move to the next experiment after the current one is merged with
both reviewers approving. If E1 hits the utilization target, skip E2
and E3.

## Results table

One row per iteration; append as we go.

| # | experiment | wall (s) | util | p50 | p95 | rubric | top-10 | notes |
|---|------------|----------|------|-----|-----|--------|--------|-------|
| 0 | baseline bge-base@1200/240 (from phase D) | ~2520 | ~200% | 6.6s | 26.5s | 39/60 | 9/10 | single-actor embedder |

## Out of scope

- Re-doing the retrieval parameter sweep (settled in phase D at
  1200/240; multicore work is pure throughput).
- Replacing `EmbedderPool` with a dispatch of work across the pool
  rather than acquire/release (the acquire/release pattern is fine
  once the pool holds N).
- Switching backends (MLX ↔ CoreML ↔ ONNX) — outside scope.
