# Multi-core Embedding — Experiment Plan (v2)

Agent: `agent-c54ba5da` (2026-04-20). v2 addresses review feedback from
`agent-1425fc4c` (experiment design) and `agent-3d0359b5` (concurrency).

## Problem

Reindex at bge-base@1200/240 reports `util=199%` with `workers=10` —
roughly 2 workers' worth of embed occupancy despite spawning 10. Both
`BGEBaseEmbedder` and `NomicEmbedder` are declared `public actor`; the
`EmbedderPool` wrapping them holds exactly **one** instance (see
`IndexingPipeline.swift:179`: `EmbedderPool(embedder: profile.embedder)`).
Each actor has its own mailbox and serializes calls into it — with
one instance, all 10 workers contend on that one mailbox.

Observed on the closest-to-baseline bge-base run (1200/360, same
architecture): `wall=2828s, embed=6738s (sum), p50_embed=6.57s,
p95_embed=26.4s`. The p95/p50 ratio of ~4× is classic mailbox queueing.

## What `util%` actually measures

`util%` (`IndexingPipeline.swift:777-783`,
`UpdateIndexCommand.swift:541-550`) is:

    util% = Σ per-chunk embed()-wall-clock / (wall × workerCount) × 100

So it's **embed-pool occupancy**, not CPU/core utilization. A worker
blocked inside `encode()` waiting on a serialized GPU queue looks
identical to a worker saturating a CPU core. This means util% alone
cannot distinguish "10 cores hot" from "10 workers all waiting on
the same GPU." **Every verification run must cross-check with
per-thread CPU% sampling (`top -l 3 -pid $(pgrep vec)` or `ps -M -p
$(pgrep vec)`).**

## Goal

Raise actual *core utilization* (confirmed via `top`/`ps`) toward
`workerCount × 100%` (target ≥600% on this 10-core machine) without
regressing retrieval quality. util% is the primary throughput gauge
but is only valid in combination with the per-thread CPU sample.

## Verification protocol

Run exactly once at baseline, then once per experiment:

1. **Idle cool-down**: let the machine idle ≥2 min since the last
   reindex so MLX weight cache + thermal state resets.
2. **Pin worker count**: assert `ProcessInfo.processInfo.activeProcessorCount == 10`
   in the log header (or pass a `--workers 10` flag if it exists).
   Record if it differs.
3. `vec reset markdown-memory --force`.
4. `time vec update-index --verbose 2>&1 | tee .reindex-multicore-<iter>.log`.
5. **During the run, in a second terminal**, capture three samples
   of `top -l 1 -pid $(pgrep -n vec) -stats cpu,mem,rsize` spaced
   ~30 s apart. Record the `cpu` column values (>600% target).
6. Parse the `[verbose-stats]` line: `wall, embed, util, p50_embed,
   p95_embed`. Also record `time`'s real wall-clock.
7. **Rubric replay** (retrieval regression guard):
   - Run the 10 bean-counter queries against the fresh index.
   - Score with `.score-rubric.py` committed in this repo.
   - Require **total ≥ 37/60 AND top-10_either ≥ 8/10** (allows ±2 pt
     rubric noise around the 39/60, 9/10 baseline).
8. **Determinism check** (catch silent ordering regressions):
   - Re-run the 10 queries against the same index without reindexing.
   - Diff top-20 `"file"` entries between the two runs. Any diff =
     non-determinism bug; surface before declaring the experiment
     complete.
9. One-line row in the results table below.

Baseline row (row 0) is **required to be re-measured fresh** at
1200/240 before E0/E1. The existing ~2520s/200% number is from the
phase D sweep and was at 1200/360, not 1200/240 — different chunk
count, not a clean comparison.

## Experiment ordering

The v1 plan listed E1 → E2 → E3. Reviewer 2 noted that E2's original
hypothesis ("actor hops themselves are serialization points") is
incorrect — hops are per-actor microseconds, not a global pool lock.
If E1 plateaus below target, the more likely causes are:
- MLX internal thread contention (E3's territory),
- memory-bandwidth saturation,
- cooperative-pool width vs requested worker count.

Revised order: **E0 → E1 → E3 → E2** (if still needed). E2 becomes a
complexity-reduction refactor, not a throughput fix.

### E0 — Diagnostic: confirm mailbox contention

**Cheapest and must run first** — ~1 h total including rerun.

**Goal.** Prove that the embed bottleneck today really is the single
actor's mailbox, not some downstream issue (MLX lock, memory BW, or
already-saturated cores masked by a broken stat).

**Change (temporary, do NOT commit).** Patch `EmbedderPool.acquire`
to log each waiter's queue-wait time and log the count of in-flight
calls. Rerun one reindex, parse the log, compute mean queue-wait per
worker.

**Signal we're looking for.**
- Queue-wait >50% of per-call wall → actor mailbox IS the bottleneck;
  proceed with E1.
- Queue-wait <10% of per-call wall → mailbox is NOT the bottleneck;
  E1 won't help. Re-plan (likely E3 first, or investigate MLX).
- In between → run E1 anyway but temper expectations.

**Artifacts.** Results row 0a ("E0 diagnostic"). No code commit.
Patch stays on a scratch branch or just un-committed in the worktree
for the duration of E0.

### E1 — Pool of N independent embedder instances

**Hypothesis (corrected).** Each actor has its own mailbox and runs
on Swift's cooperative thread pool independently. One actor = one
mailbox = one-at-a-time. **N actor instances = N mailboxes = real
parallelism, bounded by thread-pool width (~`activeProcessorCount`).**
The per-call actor-hop overhead is microseconds; `encode()` is
hundreds of ms, so hops will not plateau us below core count.

**Safety argument.**
- `BGEBaseEmbedder` (and `NomicEmbedder`) remain `actor`s in E1 —
  each instance owns its own `Bert.ModelBundle` and never shares it.
  So the safety story is "per-instance isolation," not
  "`ModelBundle: Sendable` lets us share one bundle." (The Sendable
  conformance is still nice — it's the safety net if someone later
  wants one shared bundle — but E1 does not depend on it.)
- Each actor serializes its own `loadBundleIfNeeded()` via actor
  isolation automatically. No extra synchronization needed.

**Change.**
1. Turn `EmbedderPool` into a bounded pool over an array of N
   instances. Each `acquire()` hands out a unique, currently-idle
   instance; `release()` marks it available. Implementation: an
   `AsyncStream`-backed queue, or a simple actor holding an array
   of instances + an `AsyncSemaphore`-equivalent (continuation-based
   waiter queue).
2. Pipeline constructor takes `concurrency: Int` and a factory
   `@Sendable () -> any Embedder` (the profile's alias mints fresh
   embedders today — we extend that to mint N).
3. `IndexingProfile` gains either `makeSibling()` or a `factory`
   closure accessible from the pipeline.
4. **Critical: update `warmAll()` to iterate all N instances**, in
   serial. This preserves the H5 invariant (no parallel cold-load
   memory-bandwidth contention) AND serially populates the
   HuggingFace on-disk cache, which prevents N-way concurrent cache
   writes on first-run-ever machines.
5. Enforce one-worker-per-instance: the pool MUST NOT hand the same
   instance to two workers simultaneously. A busy-flag array +
   waiter queue, or an `AsyncSemaphore` gating acquire into a
   ring-buffer index, is sufficient. One-line bug otherwise.

**Risk.** Memory. 10× `Bert.ModelBundle` for bge-base ≈ 10 × ~440 MB
on disk; RAM footprint will be measured from `top`'s `rsize` column.
If RSS after warmup > 6 GB, back off `concurrency`.

**Exit criteria (tightened).**
- **Pass**: `util ≥ 600%` AND per-thread CPU sample confirms ≥6
  cores active AND rubric holds AND determinism check passes.
- **Insufficient**: `util < 400%` after E1 → proceed to E3.
- **Back off**: RSS > 6 GB → reduce `concurrency` to fit.

### E3 — MLX internal thread pinning (run before E2 per review)

**Hypothesis.** The ~200% util we measure today may already include
MLX's per-call internal parallelism (BNNS/Metal dispatches N threads
internally). If each of our 10 workers also triggers N internal MLX
threads, we oversubscribe the cooperative pool and gain nothing.

**Change.** Probe for MLX thread-count knobs (`MLX.setThreadCount`,
env var like `MLX_METAL_NUM_THREADS`, `MLX_CPU_NUM_THREADS`, or
similar). If found, pin to 1 internal thread so outer parallelism is
purely worker-count-driven. Compare vs E1 best.

**Risk.** Per-call latency could rise (each inference loses internal
parallelism). Net throughput may still win.

**Exit criteria.** Wall-clock reduction ≥10% vs E1 best OR util
≥800%.

### E2 — Strip actor isolation (complexity-reduction, not throughput fix)

**Hypothesis (corrected).** Actor hops are not global serializers,
so removing them will not materially speed up a well-pooled
embedder. E2 is therefore motivated as a **structural simplification**
— collapsing the pool-of-N design into a single thread-safe
`final class` embedder — only if the pool-of-N adds ongoing
complexity costs we want to escape.

**Change.** Convert `BGEBaseEmbedder` / `NomicEmbedder` from
`public actor` to `public final class ... : @unchecked Sendable`
with an `OSAllocatedUnfairLock<Bert.ModelBundle?>` protecting the
lazy-loaded bundle.

**Correct lock discipline (not "lock-free"):**
- Reads of the bundle MUST take the lock. Using
  `OSAllocatedUnfairLock<Bundle?>.withLock { $0 }` for both read and
  write sides is clean, cheap (uncontended after load), and race-free.
- Alternative: `Atomic<Bundle?>` from swift-atomics, acquire-release
  ordering on reads. More code, same correctness.
- **Do NOT** describe the post-load path as "lock-free" — that would
  be a data race under Swift 6 / weak memory models.
- `final class ... : @unchecked Sendable` must be justified by the
  lock-protected bundle; document the invariant inline.

**Safety — `Bert.ModelBundle.encode` is safe to call concurrently
on the same bundle:**
- `Bert.ModelBundle` is `public struct ... Sendable` (verified at
  swift-embeddings' `BertModel.swift:371`).
- `encode(_:maxLength:)` is non-mutating; it reads the model weights
  and tokenizer state only.
- `TextTokenizer` protocol requires `Sendable`.
- So one bundle shared across N callers is safe; E2 eliminates the
  need for N bundles, reducing RAM.

**Protocol boundary note.** `Embedder: Sendable` today works for
both `actor` and `final class` implementors because methods are
`async throws` and non-isolated. No protocol change needed.

**Exit criteria.** LOC-touched ≤ 200 (i.e., actually simpler than
the pool) AND util / wall do not regress vs E1+E3 best.

## Interactions

- **E1 and E2 are substitutes**: if E2 lands, a pool of 1 is fine
  (the thread-safe bundle is enough). If we ship E1, E2 is just
  cleanup and can be deferred.
- **E1 and E3 are compounds**: N external workers × 1 internal MLX
  thread is the design-intent combination.
- **Ship decision rule**: if E1 alone hits util ≥ 600% and target
  wall-clock, stop. If E1 is short, add E3. Only reach for E2 if
  the pool-of-N carries operational complexity (memory, warmup
  sequencing) that we want to retire.

## Review cycle

Each experiment lands on its own commit. After each commit, run the
`review-cycle` skill with 2 focused reviewers:

- **Correctness / concurrency**: Sendable, data races, per-instance
  isolation, lazy-load publication, warmup sequencing.
- **Architecture / regression**: minimal, follows existing pipeline
  structure, tests green, determinism preserved.

Only move to the next experiment after the current one merges with
both reviewers approving. E0 does not ship code, so its "review" is
just a sanity-check of the diagnostic conclusion.

## Results table

One row per iteration; append as we go. Baseline is the first real row.

| # | experiment | wall (s) | util | p50 | p95 | top-CPU | RSS | rubric | top-10 | determ | notes |
|---|------------|----------|------|-----|-----|---------|-----|--------|--------|--------|-------|
| _ | baseline (fresh, 1200/240) | TBD | TBD | TBD | TBD | TBD | TBD | ≥37/60 | ≥8/10 | pass | required before E0 |

## Out of scope

- Re-doing the retrieval parameter sweep (settled in phase D at
  1200/240).
- Replacing `EmbedderPool` with a work-dispatcher pattern (queue →
  worker) instead of acquire/release — the acquire/release pattern is
  fine once the pool holds N and tracks per-instance busy state.
- Switching backends (MLX ↔ CoreML ↔ ONNX).
- Making the corpus size variable across iterations — corpus is
  fixed at the markdown-memory snapshot on disk for the duration of
  the experiment block. If the corpus changes mid-run, note in the
  row and retire prior rows.
