# E7 — Profile Indexing Pipeline (Find e5-base Wallclock Hotspots)

## Purpose

E6.1 → E6.6 cut `e5-base` reindex wallclock from ~1025 s to **891 s**
on the canonical `markdown-memory` corpus (8070 chunks at
`e5-base@1200/0`, E6.5 defaults `pool=8 batch=32 bucket-width=500
compute-policy=auto`). Every gain so far has come from
parameter-space tuning — concurrency, batch size, bucket width,
compute policy. Further gains require knowing **where the 891 s is
actually spent**.

The pipeline has at least seven plausible cost centers:

1. Text extract (file read + RecursiveCharacterSplitter chunking).
2. Per-chunk tokenization (`bundle.tokenizer.tokenizeTextsPaddingToLongest`).
3. Per-batch tensor construction (`MLTensor(shape:scalars:)` × 2 — ids + mask).
4. Per-batch CoreML compute (`bundle.model(...)` forward pass under
   `withMLTensorComputePolicy`).
5. Per-batch pool + L2-normalize (mask broadcast, multiply, sum,
   divide, then per-row Float math in `unpackAndReinterleave`).
6. Per-batch tensor materialization (`pooled.cast(...).shapedArray(...)`).
7. Per-file DB write (`unmarkFileIndexed` + `replaceEntries` +
   `markFileIndexed` against SQLite).

Today's `IndexingStats` collapses this into three buckets per file:
`extractSeconds`, `embedSeconds` (a per-file *embed span*, not summed
worker time), `dbSeconds`. That granularity is too coarse for hotspot
hunting — the embed span is dominated by everything between (2) and
(6), with no way to attribute time to any one of them.

E7 instruments the pipeline at the granularity needed to answer:
**"What single change, if any, would shave ≥5 % off the 891 s
wallclock?"** Output is a per-span breakdown table; no defaults
flip. Any optimization work that follows this experiment is its own
E7.x or E8.x.

## Scope and non-scope

**In scope:**
- Add Apple `os.signpost` instrumentation to `IndexingPipeline.run`
  and `E5BaseEmbedder.meanPooledBatch` (and possibly
  `E5BaseEmbedder.embedDocuments`) so a profiled run captures every
  meaningful span.
- A console / file post-processor that tabulates per-span totals
  (sum, count, mean, median, p95) and percent-of-wall.
- One canonical run at the E6.5 defaults against `markdown-memory`
  to produce the headline breakdown table.
- A second run with signposts disabled (compile-time guard) as the
  overhead control; if the instrumented run is >2 % slower than
  uninstrumented, the post-process numbers need a measured
  correction factor — see "Overhead control" below.

**Out of scope:**
- Optimizing any of the spans we identify. E7 only *measures*; the
  follow-up experiments do the work.
- Instrumenting the other 6 MLTensor embedders (BGE-{small,base,large},
  GTE-base, mxbai-large, Nomic). The `os.signpost` calls land in
  `E5BaseEmbedder.swift` for this experiment; the same shape can be
  copy-pasted to peers later if the hotspot analysis warrants it.
  Pipeline-level signposts are embedder-agnostic and benefit every
  embedder for free, but the embedder-internal spans are the
  fine-grained ones we actually need, so embedder-by-embedder
  rollout is fine.
- Cross-corpus generalization. We measure once on `markdown-memory`
  at the canonical 891 s configuration. If hotspots differ on
  larger or smaller corpora, that is a follow-up.
- Behavioural changes. The instrumentation must be observation-only
  — no algorithmic change, no batch-size change, no thread-pool
  change. Reverting the patch must restore byte-identical output.

## Why os.signpost (not OSLog intervals, not custom timestamps)

Three options were considered:

1. **`os.signpost` via `OSSignposter`** — Apple's first-class
   profiling primitive. Each `beginInterval` / `endInterval` pair
   logs a 64-bit timestamp + identifier; the kernel's persistent
   ring buffer carries them. Negligible overhead per call (~50 ns
   on M-series); pairs are emitted asynchronously. Rendered live in
   Instruments.app's "os_signpost" track and post-processable via
   `xctrace export --input <run>.trace --xpath ...` for offline
   tabulation. Reference:
   - https://developer.apple.com/documentation/os/ossignposter
   - https://developer.apple.com/documentation/os/recording-performance-data
2. **`OSLog` interval messages** — same kernel ring buffer, but
   you write `Logger.info` / debug strings and post-process by
   parsing log text. Higher per-call overhead than signposts (string
   formatting), and the interval semantics are not first-class —
   you'd hand-pair `start` / `end` log lines. Worse fit.
3. **Hand-rolled `DispatchTime.now()` deltas summed into actors**
   — what `StatsCollector` already does for `extractSeconds /
   embedSeconds / dbSeconds`. Cheap, but every new span needs a new
   actor field, and visualization requires a custom dump format. Fine
   for one or two spans; doesn't scale to the ~7 we need here.

**Decision: `os.signpost` via `OSSignposter`.** Lowest overhead at the
granularity we need, ships with the OS, and Instruments.app gives us
a free flame-chart view. The post-process pulls per-span totals out
of the `.trace` file via `xctrace export`.

The codebase has zero existing signpost / OSLog / Logger usage today
(verified by `grep -r "os_signpost\|OSSignposter\|signposter\|Logger("
Sources/`). We are adding the first hooks.

## Spans to measure

Granularity goal: **no single span > 30 % of total wall**. If a
recorded span hits 30 %+ in the breakdown, split it further in a
follow-up patch and re-run.

### Pipeline-level (in `IndexingPipeline.swift`)

| Signpost name           | Where                                                         | Args / metadata                                |
|-------------------------|---------------------------------------------------------------|------------------------------------------------|
| `extract`               | Stage 1, around `extractor.extract(from:)`                    | `path=%s, bytes=%lld, chunks=%d`               |
| `extract.split`         | Optional inner span if split cost dominates extract           | `chars=%d, chunks=%d`                          |
| `pool.warmup`           | `pool.warmAll()` call in `run()`                              | `instances=%d`                                 |
| `batch.former.flush`    | One per `batchContinuation.yield(BatchWork(items:))`          | `count=%d, bucket=%d, reason=%{public}s`       |
| `extract.gate.wait`     | Around `try await extractGate.acquire()`                      | _no args; sums to backpressure idle time_      |
| `pool.acquire.wait`     | Around `try await pool.acquire()`                             | _no args; sums to pool-saturation idle time_   |
| `batch.embed`           | One per spawned embed task, wraps `embedder.embedDocuments`   | `count=%d, embedder=%{public}s`                |
| `accumulator.add`       | `await accumulator.add(emitted)`                              | _no args; cheap actor hop_                     |
| `db.write`              | Stage 3b, wrapping the unmark + replace + mark trio           | `path=%s, records=%d`                          |

`reason` on `batch.former.flush` is one of `"bucket-full"`,
`"total-buffered"`, `"stream-close"` — matches the three flush rules
in the existing comments at `IndexingPipeline.swift:411-466`. Lets us
see how often each rule fires.

`extract.gate.wait` and `pool.acquire.wait` are *idle-time spans*: the
sum tells us how much wall-clock the pipeline spent stalled. If
`pool.acquire.wait` summed across all spawn tasks is huge, the embed
stage is the bottleneck (chunks queue waiting for an embedder); if
`extract.gate.wait` is huge, embed is starving extract (gate full,
extract blocked). Both being small means the pipeline is balanced
and the cost is in the work itself.

### Embedder-level (in `E5BaseEmbedder.swift`)

| Signpost name                | Where                                                                                  | Args / metadata                                |
|------------------------------|----------------------------------------------------------------------------------------|------------------------------------------------|
| `e5.normalize-inputs`        | `normalizeBertInputs(_:prefix:maxChars:)` call in `embedDocuments`                     | `count=%d, live=%d`                            |
| `e5.tokenize`                | `bundle.tokenizer.tokenizeTextsPaddingToLongest(...)`                                  | `batch=%d, max_len=%d, total_chars=%d`         |
| `e5.tensor.alloc`            | The two `MLTensor(shape:scalars:)` constructions for `inputIds` and `attentionMask`    | `batch=%d, seq_len=%d`                         |
| `e5.compute.policy.scope`    | The `withOptionalComputePolicy(computePolicy)` block (graph construction only)         | `policy=%{public}s, batch=%d, seq_len=%d`      |
| `e5.forward`                 | The `bundle.model(inputIds:attentionMask:)` call — graph construction time             | `batch=%d, seq_len=%d`                         |
| `e5.pool`                    | Mask broadcast / multiply / sum / divide chain (still inside the policy scope)         | `batch=%d, seq_len=%d, hidden=%d`              |
| `e5.materialize`             | `await pooled.cast(to: Float.self).shapedArray(of: Float.self).scalars`                | `batch=%d, dim=%d`                             |
| `e5.unpack-and-l2`           | `unpackAndReinterleave` post-process                                                   | `batch=%d, dim=%d, normalizer=l2`              |

**Critical caveat: MLTensor lazy execution.** `bundle.model(...)`
returns an `MLTensor` whose underlying CoreML graph has not yet
*run*; the work happens during materialization
(`pooled.cast(...).shapedArray(...)`). This is documented behavior —
the same pattern shows up in `swift-embeddings`'
`NomicBertModel.swift` (`batchEncode` returns the tensor and the
caller materializes). So the wall-clock spent compiling and running
the graph will land **mostly in `e5.materialize`**, not in
`e5.forward` or `e5.pool`. The forward + pool spans will look
"free" — that is correct and informative. We instrument them
anyway so the post-process can show the materialize span dominates,
which is the answer we expect.

If `e5.materialize` lands at 80 %+ of `batch.embed`, the natural
follow-up is to split materialization further — token reads and
device-host transfer can be measured separately by inserting a
`pooled.cast(to: Float.self)` wait *before* `.shapedArray(...)` and
timing each. That's an E7.1 follow-up if E7 leaves the materialize
span undifferentiated above the 30 % rule.

### Why these and not others

- **`accumulator.add`** is included so we can rule it out as a
  serialization point. The `FileAccumulator` is an actor; if its
  mailbox queues, embed tasks block on the hop. Expectation is
  <1 % of wall; the span exists to confirm.
- **`db.write`** wraps the SQLite trio rather than each call
  individually. If the trio is large enough to matter we split it
  in a follow-up; today `dbSeconds` summed across 674 files runs at
  a few seconds total in baseline `IndexingStats`, so a coarse span
  is sufficient.
- **`pool.warmup`** is a one-shot but worth tagging: the H7 doc
  comment warns it can be a bigger fraction of total wall on tiny
  corpora. On `markdown-memory` we expect <5 s.
- **No `extract.split` by default.** If `extract` itself lands at
  >5 % of wall and we want to know whether file I/O or splitting is
  the cost, that's a follow-up signpost; don't pre-instrument.

## Output format

Two outputs from one profiled run.

### 1. Live `.trace` file (Instruments.app or `xctrace`)

Run the binary under `xctrace record` to capture an .trace file. The
canonical recording command (one line, no piping; agents must run as
two separate Bash calls — gather first, then record):

```sh
# step 1 — bundle profile (one-shot; tells xctrace which signposts to log)
xcrun xctrace record \
    --template "Time Profiler" \
    --launch -- \
    swift run -c release vec update-index --db markdown-memory --verbose
```

Apple docs:
- `xctrace` man page: `man xctrace` (or `xcrun xctrace help record`).
- "Recording, Pausing, and Stopping Traces" guide:
  https://developer.apple.com/library/archive/documentation/DeveloperTools/Conceptual/InstrumentsUserGuide/RecordingPausingandStoppingTraces.html
- `os.signpost` and Instruments integration:
  https://developer.apple.com/documentation/os/recording-performance-data

The `Time Profiler` template auto-includes the `os_signpost`
instrument; signposts emitted via the
`OSLog(subsystem: "com.adamwulf.vec.indexing", category: ...)` /
`OSSignposter` we add in this experiment will appear in their own
track without further configuration.

### 2. Post-processed table

`xctrace export --input <run>.trace --xpath
'/trace-toc/run/data/table[@schema="os-signpost"]'` produces an XML
dump with one row per signpost event. A small Python
post-processor (committed under `scripts/profile-spans.py` as part
of E7) bins by signpost name, computes:

- count
- sum-seconds
- mean-seconds
- median-seconds
- p95-seconds
- percent-of-wall

…and emits a markdown table identical in shape to:

```
| span                       | count | sum_s | mean_ms | p95_ms | %wall |
| -------------------------- | ----: | ----: | ------: | -----: | ----: |
| extract                    |  674  |  21.4 |    31.8 |   118  |  2.4% |
| pool.warmup                |    1  |   3.1 |  3100   |  3100  |  0.3% |
| batch.former.flush         |  421  |   0.8 |     1.9 |     6  |  0.1% |
| extract.gate.wait          | 8070  |  ...  |   ...   |   ...  |  ...  |
| pool.acquire.wait          | 8070  |  ...  |   ...   |   ...  |  ...  |
| batch.embed                |  421  |  ...  |   ...   |   ...  |  ...  |
| e5.tokenize                |  421  |  ...  |   ...   |   ...  |  ...  |
| e5.tensor.alloc            |  842  |  ...  |   ...   |   ...  |  ...  |
| e5.compute.policy.scope    |  421  |  ...  |   ...   |   ...  |  ...  |
| e5.forward                 |  421  |  ...  |   ...   |   ...  |  ...  |
| e5.pool                    |  421  |  ...  |   ...   |   ...  |  ...  |
| e5.materialize             |  421  |  ...  |   ...   |   ...  |  ...  |
| e5.unpack-and-l2           |  421  |  ...  |   ...   |   ...  |  ...  |
| accumulator.add            | 8070  |  ...  |   ...   |   ...  |  ...  |
| db.write                   |  674  |  ...  |   ...   |   ...  |  ...  |
| TOTAL (wall)               |    -  |  891  |    -    |    -   | 100%  |
```

Counts are predicted: 8070 chunks / 32 batch-cap → ~252 batches
minimum; with bucketing flushes plus stream-close partial flushes
the actual count lands closer to ~420. Use observed numbers, not
these predictions, in the final report.

`%wall` is `sum_s / wall_s × 100`. Numbers will sum to >100 % when
spans run in parallel across the worker pool — that is expected and
informative (a span at 600 % is occupying ~6 of 8 workers' wall on
average). The post-processor flags any span ≥ 30 % of `wall_s`
serialized (i.e., divided by `min(workerCount, count_of_concurrent_workers_on_that_span)`)
for the "split this further" rule.

### 3. Sanity-cross-check vs `IndexingStats`

The existing `IndexingStats` totals (`extractSeconds`,
`totalEmbedCallSeconds`, `dbSeconds`) are summed in actors and
already known-correct. The post-processor must:

- `sum(extract) ≈ stats.extractSeconds` (within 1 %).
- `sum(batch.embed) ≈ stats.totalEmbedCallSeconds` (within 1 %).
- `sum(db.write) ≈ stats.dbSeconds` (within 1 %).

If any of these three checks fails by >1 %, the signpost
instrumentation is buggy; fix before trusting the per-span
breakdown.

## Experiment protocol

### Corpus and config

Canonical reference run: `markdown-memory` at `e5-base@1200/0`, E6.5
defaults (`pool=8 batch=32 bucket-width=500 compute-policy=auto`).
Same configuration that produced the 891 s row in
`benchmarks/wallclock-2026-04-25/e5-base/summary.md`.

**Corpus drift caveat (per CLAUDE.md).** `markdown-memory` is
operator-synced, not continuously-growing. Before declaring a chunk
count or a wall delta a real signal, ask Adam if he has synced
Granola since 2026-04-25. If yes, expect more chunks and
proportionally longer wall — that's drift, not a measurement
problem. If no, expect bit-identical chunk count (8070) and
wall within run-to-run noise (~11.6 % per E6.3 documented bound).

### Reindex recipe (per run)

```sh
# Reset + fresh reindex at canonical config (3 steps):
swift run -c release vec reset --db markdown-memory --force
xcrun xctrace record --template "Time Profiler" --launch -- \
    swift run -c release vec update-index \
        --db markdown-memory --embedder e5-base --verbose
# Trace lands in current dir as `Launch_<timestamp>.trace`.
```

Each `swift run` and `xctrace record` is a separate Bash call (one
command per call per the agent harness rule). Two runs total:

1. **Run A: instrumented run** under `xctrace`. Capture `.trace`.
2. **Run B: instrumented binary, no recording** (drop `xctrace`,
   keep the signpost calls in the build). Captures the wallclock
   under signpost overhead but without trace I/O.
3. **Run C: control** — uninstrumented binary (signposts compiled
   out via `#if PROFILING`). Captures the no-overhead reference wall.

Compare `wall_C` (control) vs `wall_B` (instrumented w/o trace) vs
`wall_A` (instrumented with trace). If `wall_B / wall_C - 1` > 2 %,
the post-processed sums need a measured correction factor (multiply
each span sum by `wall_C / wall_B`). The signpost API claims ~50 ns
per call; at ~10 events per chunk × 8070 chunks ≈ 80k events ≈
4 ms total — well under our run-to-run noise. We measure this
explicitly anyway to be honest with the data.

**One run each, not three averaged.** E6.3 documented run-to-run
wallclock noise at ~11.6 %; one run gives us a single point estimate
per condition and the per-span structure, which is what we want.
Averaging three would consume ~45 minutes per condition for a
~12-minute run and gain little — the per-span totals within a single
run are very stable because the corpus is fixed and the pipeline is
deterministic up to scheduler ordering.

### Compile-out guard

Wrap every signpost call in:

```swift
#if PROFILING
signposter.beginInterval(...)
#endif
```

…and the corresponding end-call. Add `PROFILING` to the package's
`swiftSettings` only when invoked via:

```sh
swift run -c release \
    -Xswiftc -DPROFILING \
    vec update-index ...
```

Default builds (and tests) compile the signposts out entirely —
zero overhead, zero change to public surface, no new dependencies.

This matches Apple guidance on conditional signpost compilation:
https://developer.apple.com/documentation/os/recording-performance-data#3413040

Alternative (simpler, still acceptable): use
`OSSignposter(subsystem:category:)` unconditionally and rely on the
documented sub-microsecond-when-disabled behavior of the signposter
when `os_signpost_enabled(log)` returns false. The `xctrace` tool
enables the log only when recording, so production runs see no
overhead. Pick whichever is easier to land cleanly; the
`#if PROFILING` route is more explicit but adds a build flag.

## Success criteria

E7 is **done** when we have a committed report containing:

1. **A breakdown table** (the format above) with every span listed
   above populated, percent-of-wall computed, and each span labeled:
   - `<1 %` — ignore.
   - `1-5 %` — note, no immediate action.
   - `5-15 %` — candidate for follow-up optimization.
   - `15-30 %` — strong candidate; queue an E7.x or E8.x.
   - `30 %+` — split-this-further rule fired; the experiment is
     incomplete and a follow-up patch with finer signposts is
     required before E7 closes.

2. **A `IndexingStats` cross-check** showing the three sum-equality
   constraints all hold within 1 %.

3. **An overhead correction note** stating the measured `wall_B /
   wall_C` ratio and whether it's under or over the 2 % threshold.

4. **A short "what to attack first" recommendation** based on the
   top-3 spans by absolute time. Three sentences, no
   pre-implementation work — that's the next experiment's job.

5. **The instrumentation patch** committed behind `#if PROFILING`
   so future E-experiments can re-run the profile without
   re-implementing the signposts. Reverting to default build flags
   must restore byte-identical wallclock and behavior.

## Blockers / open questions

These are explicit unknowns. Each must be resolved during execution
or noted as residual in the report.

- **MLTensor compute-policy boundary semantics.** The docstring on
  `E5BaseEmbedder.meanPooledBatch` calls out that
  `withOptionalComputePolicy(...)` "captures the policy at graph
  construction time" and that materialization runs outside the
  scope. Open: does materialization run *synchronously* on the
  current thread, or is it dispatched async to a CoreML worker
  queue? If the latter, our `e5.materialize` span captures only the
  wait, not the compute — and the compute time is invisible to
  signposts. Plausible mitigation: also signpost the
  `withMLTensorComputePolicy` block exit and a paired event right
  before the `await` on `.shapedArray(...)`; the gap between the
  two is "graph build", the `await` body is "graph run + transfer".
  No documented reference at the time of writing; we may need to
  empirically confirm by toggling `--compute-policy cpu` (where
  there is no device transfer) vs `--compute-policy ane` and
  observing where the wall lands.

- **`xctrace export` schema stability.** The signpost row schema in
  `xctrace`'s XML output has shifted across Xcode versions. The
  post-processor must declare the Xcode version it was developed
  against in a comment and bail loudly with a useful error if it
  encounters an unknown column layout. Don't silently produce
  wrong sums.

- **Tokenizer cost on first chunk vs steady-state.** The
  `Bert.ModelBundle.tokenizer` lazy-loads its vocab on first call.
  If `e5.tokenize`'s first event is 100× slower than steady-state,
  the post-processor's mean is misleading; report median + p95 to
  surface the warm-cache distribution and call out the cold-cache
  cost as a separate line. (Pool warmup at `pool.warmAll()`
  *should* warm the tokenizer already by running one embed per
  pool instance — verify.)

- **Span overlap on the embed-spawner inner TaskGroup.** Each
  spawned task's `batch.embed` span runs concurrently with up to 7
  others on the worker pool. The post-processor's `%wall` column
  must distinguish "sum across parallel workers" (>100 %) from
  "fraction of serial wall" (≤100 %). Use the latter for hotspot
  ranking; the former for occupancy diagnosis. Document both.

- **What if extract is the bottleneck?** Pre-experiment guess says
  extract is 1-3 % of wall (`stats.extractSeconds` was a small
  bucket in every E6.x report). If E7 surprises us with extract
  >10 %, the corpus has changed or something regressed in
  `RecursiveCharacterSplitter`; cross-reference the corpus drift
  question in CLAUDE.md before diving into a splitter rewrite.

- **One-corpus generalizability.** A hotspot identified on
  `markdown-memory` (heterogeneous Granola transcripts + summary
  markdown) may not be the hotspot on a different corpus shape
  (uniformly-short README files, uniformly-long PDFs, etc.). E7's
  output is "where the time goes on this corpus today"; before
  acting on it, the follow-up should consider whether a second
  corpus would invalidate the ranking.

## Done definition

E7 ships with one commit:

- `experiments/E7-profile-indexing/plan.md` (this file).

E7 *executes* in a follow-up commit chain (out of scope for this
plan-writing task):

- Instrumentation patch under `#if PROFILING`.
- `scripts/profile-spans.py` post-processor.
- `experiments/E7-profile-indexing/report.md` with the breakdown
  table and recommendation.
- `experiments/E7-profile-indexing/commits.md` linking SHAs.
- A "Done" entry in the top-level `plan.md` referring back here.
