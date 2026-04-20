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
5. **During the run, in a second terminal**, capture ≥5 samples
   spaced across the run (every ~300 s). Each sample is an averaged
   3-second window, not an instantaneous tick:
   `top -l 3 -s 1 -pid $(pgrep -n vec) -stats cpu,mem,rsize`. Record
   the `cpu` column (target ≥600% for pass) and peak `rsize`.
   **GPU/ANE caveat**: on Apple Silicon, MLX work that runs on
   Metal GPU or the ANE does NOT appear in `top`'s per-process CPU%.
   If bge-base inference is GPU/ANE-bound, a perfectly parallel
   workload could read low on CPU% while running at full throughput.
   For runs where `top` CPU% looks low but wall-clock improved, also
   capture `sudo powermetrics --samplers cpu_power,gpu_power -n 5 -i
   1000` windows to see GPU activity. (Note the MLX backend the
   embedder uses in the log — it determines which tool to trust.)
6. Parse the `[verbose-stats]` line: `wall, embed, util, p50_embed,
   p95_embed`. Also record `time`'s real wall-clock.
7. **Rubric replay** (retrieval regression guard):
   - Run the 10 bean-counter queries against the fresh index.
   - Score with `.score-rubric.py` committed in this repo.
   - Require **total ≥ 37/60 AND top-10_either ≥ 8/10** (allows ±2 pt
     rubric noise around the 39/60, 9/10 baseline).
8. **Determinism checks** (catch silent ordering regressions — two
   separate passes, both required):
   - **Query-side**: re-run the 10 queries against the *same* index
     without reindexing. Diff top-20 `"file"` entries between the
     two runs. Any diff = query non-determinism bug.
   - **Indexing-side**: reindex the corpus a second time with the
     same config, then run the 10 queries. Diff top-20 against the
     first reindex. This is the check that matters for E1 —
     concurrent workers can insert chunks in different orders across
     runs, and cosine-tie-breaking can swap results even when
     embeddings are identical. Budget: one extra ~40 min reindex per
     experiment.
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

**Instrumentation point (must be at the embedder, not the pool).**
Today's `EmbedderPool.acquire()` (`IndexingPipeline.swift:667`) is a
no-op that returns the singleton embedder immediately — no queueing
happens inside the pool. The actual serialization point is the
**embedder actor's own mailbox**: when a worker calls
`embedder.embedDocument(…)`, the compiler inserts an implicit hop
onto the `BGEBaseEmbedder` actor; if another worker already holds
the actor, this call waits. Patching `EmbedderPool.acquire` to
measure queue-wait would therefore return ~0% and falsely reject
the mailbox hypothesis. The correct place to measure is at the
**callsite in the pipeline**, spanning the `await
embedder.embedDocument(…)` call — `t_call_wall`. Also capture
`t_encode_wall` from inside the embedder (before/after the tensor
encode call). Mailbox queue wait is `t_call_wall - t_encode_wall`.

**Change (temporary, do NOT commit).**
1. In `IndexingPipeline`'s per-chunk task, wrap the
   `embedder.embedDocument` call to record `t_call_wall`.
2. Temporarily add a `embedDocumentTimed` entry point on the
   embedder that returns `(vector, encodeSeconds)` so we can
   capture `t_encode_wall` from inside the actor.
3. Log `(t_call_wall, t_encode_wall)` per chunk; post-process for
   mean/median queue-wait ratio across all chunks.

**Signal we're looking for (thresholds tightened per observed util).**
- If all 10 workers queue on one mailbox, prediction is queue-wait
  ≈ (N-1)/N × per-call ≈ 90% of per-call wall. Observed util=199%
  (≈2 effective workers) implies actual queue-wait ≈ 80%.
- **Pass (proceed with E1)**: queue-wait ≥ 70% of `t_call_wall`.
- **Reject (mailbox not the bottleneck)**: queue-wait ≤ 30%. Investigate
  MLX internal locking / memory BW instead; likely skip E1 and run E3.
- **Ambiguous (30-70%)**: run E1 but note the measurement; partial
  result expected.

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
4. **Critical: update `warmAll()` to iterate all N instances**,
   strictly serially (`for instance in pool { await
   instance.warmup() }` — each `await` completes before the next
   starts). This preserves the H5 invariant (no parallel cold-load
   memory-bandwidth contention) AND serially populates the
   HuggingFace on-disk cache, which prevents N-way concurrent cache
   writes on first-run-ever machines. The pipeline's `run()` already
   awaits `pool.warmAll()` before the first worker dispatches
   (`IndexingPipeline.swift:204`), so there's no acquire-before-warmup
   race to design around.
5. Enforce one-worker-per-instance: the pool MUST NOT hand the same
   instance to two workers simultaneously. A busy-flag array +
   waiter queue, or an `AsyncSemaphore` gating acquire into a
   ring-buffer index, is sufficient. One-line bug otherwise.

**Risk.** Memory. 10× `Bert.ModelBundle` for bge-base ≈ 10 × ~440 MB
on disk; RAM footprint will be measured from `top`'s `rsize` column.
If RSS after warmup > 6 GB, back off `concurrency`.

**Exit criteria (tightened, no gaps).**
- **Pass (ship E1, stop)**: `util ≥ 600%` AND (per-thread CPU ≥6
  cores OR GPU activity ≥60% via `powermetrics` if GPU-bound) AND
  rubric ≥37/60 AND top-10 ≥8/10 AND both determinism checks pass.
- **Partial (proceed to E3 as compound)**: `400% ≤ util < 600%`.
  Keep E1's code; E1+E3 is the design-intent combination.
- **Insufficient (proceed to E3, consider reverting E1)**: `util <
  400%` → mailbox wasn't the only bottleneck. Try E3 first.
- **Back off**: RSS > 6 GB after warmup → reduce `concurrency` and
  retest.

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

**Exit criteria.** Wall-clock reduction ≥10% vs E1 best is the
**primary** signal — throughput is the goal. `util` climbing is a
secondary consistency check; it can rise without wall dropping if
tail-latency files still dominate. Require wall-clock win to ship.

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
- `TextTokenizer` protocol is declared `public protocol
  TextTokenizer: Sendable` (verified at
  swift-embeddings' `TextTokenizer.swift:4`).
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

Columns:
- `wall` — `[verbose-stats] wall=` in seconds.
- `util` — `[verbose-stats] util=` (pool occupancy, not CPU%).
- `p50`/`p95` — per-chunk embed wall-clock.
- `top-CPU` — peak CPU% from `top` sample during run.
- `GPU%` — peak GPU from `powermetrics` (blank if CPU-bound).
- `RSS` — peak resident-size from `top -stats rsize`.
- `qwait` — E0 only; mean `(t_call_wall - t_encode_wall) /
  t_call_wall`, expressed as %.
- `rubric`/`top-10` — bean-counter score (must be ≥37/60 and ≥8/10).
- `determ` — pass/fail across both determinism checks.

| # | experiment | wall | util | p50 | p95 | top-CPU | GPU% | RSS | qwait | rubric | top-10 | determ | notes |
|---|------------|------|------|-----|-----|---------|------|-----|-------|--------|--------|--------|-------|
| 0 | baseline fresh bge-base@1200/240 | TBD | TBD | TBD | TBD | TBD | TBD | TBD | n/a | TBD | TBD | TBD | must re-measure; do not reuse 1200/360 numbers |
| 0a | E0 diagnostic (instrumented) | TBD | TBD | TBD | TBD | TBD | TBD | TBD | TBD | n/a | n/a | n/a | no code commit; patch reverted after measure |

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
