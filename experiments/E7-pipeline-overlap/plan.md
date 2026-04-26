# E7 — Pipeline-stage overlap (tokenize / embed / write) — Plan

Goal: investigate whether pipelining the per-batch sub-stages
(tokenize+pad → CoreML forward → mean-pool+L2 → write) across
adjacent batches inside the embed stage can shave 5-15 % wallclock
off `e5-base` indexing at zero quality cost (byte-identical output
embeddings).

Targeted model: `e5-base@1200/0` on `markdown-memory`, at the E6.5
defaults (`pool=8 batch=32 bucket-width=500 compute-policy=auto`).

This is a **planning-only** doc. No code changes here. A companion
plan `E7-profile-indexing` is expected to ship the signpost
instrumentation that makes the validation phase here measurable.

## 1. Current pipeline shape

The shipped pipeline in
`Sources/VecKit/IndexingPipeline.swift` is a four-stage stream
graph (extract → batch-form → embed → accumulate → write), not a
"per-worker chunk loop". The shape:

```
extract (1 task) → embedStream → batch-former (1 task) → batchStream
                                                           ↓
                                             embed-spawner (TaskGroup)
                                                           ↓
                                          accumStream → accumulator (1 actor)
                                                           ↓
                                                       saveStream
                                                           ↓
                                                    DB writer (1 task)
```

Concrete line refs (post-H7 / post-E6.5):

- **Stage 1 (extract, single task)**:
  `IndexingPipeline.swift:308–409`. Single-threaded by design
  (line 304 doc-comment): "N_extract = 1 by design. Extract is
  cheap and keeping it single-threaded preserves intra-file
  ordinal monotonicity". One `EmbedWork` is yielded per chunk
  (`embedContinuation.yield(work)` at line 402) after acquiring
  one extractGate permit per chunk (line 392).

- **Stage 1.5 (batch-former, single task)**:
  `IndexingPipeline.swift:429–467`. Drains `embedStream`,
  length-buckets by `chunk.text.count / bucketWidth` (line 439),
  and emits one `BatchWork` per flush (lines 445, 458, 464).
  Three flush rules: full bucket, total-buffered cap (largest
  bucket flushed), end-of-stream drain.

- **Stage 2 (embed-spawner, fan-out TaskGroup)**:
  `IndexingPipeline.swift:474–563`. `for await batch in
  batchStream { embedGroup.addTask { … } }` — one child task per
  batch. Each child:
  1. `await pool.acquire()` (line 488) — gates concurrency to
     `pool.count == workerCount == 8`.
  2. `try await embedder.embedDocuments(texts)` (line 494) —
     this is the entire CoreML/MLTensor path for one batch.
  3. Synchronously fans the returned `[[Float]]` rows back out
     to the accumulator stream (lines 521–551), one
     `EmbeddedChunk` per row, releasing one extractGate permit
     per chunk along the way.

- **Stage 3a (per-file accumulator, single actor)**:
  `IndexingPipeline.swift:567–576`. Groups incoming
  `EmbeddedChunk`s by file path; emits one `SaveWork` to
  `saveStream` once a file's chunk count is satisfied
  (`accumulator.add(emitted)` returns non-nil → yield).

- **Stage 3b (DB writer, single task)**:
  `IndexingPipeline.swift:580–636`. Serial consumer of
  `saveStream`. Per file: `unmarkFileIndexed → replaceEntries →
  markFileIndexed`. Identical shape to pre-H7.

So the shape is **not** "split chunks into batches → for each batch
in parallel call embedDocuments → write outputs". It is a
**stream-of-batches with a TaskGroup fan-out at stage 2**: the embed-
spawner spawns one child task per batch as batches arrive on
`batchStream`, capped to N=8 in-flight by the pool's permit budget.

## 2. Where's the serial point?

There are two distinct serial points to consider, at different
nesting levels.

### 2a. Per-batch (inside one embed task)

Inside one embed-spawner child task (lines 487–552), the per-batch
sub-stages are strictly serial because they live in one `await`
chain:

```
texts = batch.items.map { $0.chunk.text }       // O(batch) copy, trivial
vectors = try await embedder.embedDocuments(texts)
   // ↓ inside E5BaseEmbedder.embedDocuments (E5BaseEmbedder.swift:55–73):
   // 2a-i.   normalizeBertInputs (prefix + cap)              [trivial]
   // 2a-ii.  meanPooledBatch:                                [DOMINANT]
   //          - tokenizeTextsPaddingToLongest                (CPU)
   //          - MLTensor inputIds + attentionMask construction
   //          - bundle.model(inputIds:attentionMask:)        (CoreML forward)
   //          - masked mean-pool + sum + divide              (graph ops)
   //          - pooled.cast(...).shapedArray(...).scalars    (materialize → host)
   // 2a-iii. unpackAndReinterleave + l2Normalize             (CPU, O(batch*dim))
record = ChunkRecord(...)                       // CPU, trivial
accumContinuation.yield(emitted)                // hand-off, trivial
```

The whole `meanPooledBatch` body
(`E5BaseEmbedder.swift:97–146`) executes inside an `actor`
(`public actor E5BaseEmbedder`), so even if a single embedder
instance were shared across two batches the actor's mailbox would
serialize them. Today this is moot: the pool gives each batch a
**different** embedder instance, so the actor is not the
bottleneck — the bottleneck is the underlying CoreML/MLTensor
graph dispatch + ANE/CPU kernel itself.

We do not yet know which sub-stage of 2a-ii dominates. The brief
asks us to assume **CoreML forward (`bundle.model(...)`) is
dominant**. That's the right working assumption based on E6.2's
ANE feasibility result (the policy flag moved wallclock at all,
which it can only do by changing where the forward runs) and
external research on MLTensor BERT
(`research/mltensor-bert-batch.md` if/where filed). The companion
`E7-profile-indexing` plan is what actually measures it; this
plan will not ship code without that signal.

The other plausible candidate is `tokenizeTextsPaddingToLongest`
(line 101). It's pure CPU, runs serially in front of the forward,
and sees the full batch's text. If tokenize is non-trivial (say
≥10 % of the per-batch wall), pipelining it with the forward of
the **previous** batch is cheap to express and worth doing.

### 2b. Pipeline-level (across batches)

At pool concurrency N=8, stage 2 already has 8 in-flight batches.
But each in-flight batch executes its own
`tokenize → forward → pool → host-readback → fan-out` chain
back-to-back inside one task. There is no overlap **within** a
task between sub-stages: the task is blocked on the entire
`await embedDocuments` call, and the post-embed fan-out (lines
521–551) runs strictly after `await pool.release(embedder)` (line
512).

So the pipeline-level serial points (per worker) are:

1. The worker holds one batch at a time and the embedder it
   acquired from the pool until `embedDocuments` returns.
2. While the worker is in CoreML forward, the embedder it owns
   is idle for tokenize-like CPU work that could in principle
   overlap with the previous or next batch's forward — but
   today there is no mechanism to get other CPU work into that
   window.

## 3. Pipelining options

Three shapes worth considering, in increasing order of invasiveness.

### Option A — Producer/consumer split inside the embedder actor

Inside `E5BaseEmbedder` (and any other batched embedder), break
`embedDocuments` into two phases:

- `prepareBatch(_:[String]) -> Prepared` — does the tokenize +
  prefix-norm + MLTensor input construction. Pure CPU.
- `runBatch(_:Prepared) -> [[Float]]` — the CoreML forward,
  pool, materialize, L2-normalize. The dominant phase.

Then a single embed-spawner child task could pre-fetch
`prepareBatch(N+1)` while `runBatch(N)` is in flight, *for the
same embedder*. Concretely, an internal `AsyncStream` inside the
embedder actor would carry `Prepared` items.

**Pros**: contained inside one embedder; `E5BaseEmbedder` is the
only file that changes.

**Cons**: the embedder `actor` serializes calls — to overlap
N+1's prepare with N's forward we have to drop the actor's
single-mailbox guarantee, or split into two actors (a tokenizer
actor + a forward-runner actor). That's a significant API
re-shaping for what may be a small CPU phase. Also: at pool
concurrency N=8, eight tokenize calls are already running in
parallel across eight embedder instances. Doubling per-instance
tokenize concurrency to 2 makes 16 tokenize calls in flight —
contending for the same CPU cores that the forward also wants
when `compute-policy=auto` falls back to CPU. Possible
regression.

### Option B — Pipeline-level prefetch (one-batch lookahead)

Add a one-batch tokenize-lookahead between the batch-former
(stage 1.5) and the embed-spawner (stage 2). The simplest shape:

```
batchStream → tokenize-prefetch (1 task) → preparedBatchStream
                                              ↓
                                  embed-spawner (TaskGroup)
```

The new stage runs `prepareBatch` serially (or with N=2
concurrency) and emits `(BatchWork, Prepared)` pairs. The
embed-spawner then only does `await pool.acquire(); runBatch(...);
fanout`. Effectively, while the spawner is acquiring the pool +
running CoreML forward for batch N, the prefetch stage has
already tokenized batch N+1.

**Pros**:
- Localized to `IndexingPipeline.swift` plus a small embedder
  surface change (split `embedDocuments` into prepare/run, OR
  expose a "tokenize" stage).
- Doesn't break the embedder-actor serialization invariant —
  preparation runs in the prefetch task, the embedder actor
  only sees `runBatch`.
- Easy to disable with a flag for A/B comparison.

**Cons**:
- Only buys us tokenize-vs-forward overlap. If forward
  >> tokenize (the working assumption), the win is ≤
  tokenize_seconds / total_seconds, which is plausibly small.
- Adds one more stream and one more task; needs a corresponding
  backpressure bound or the prefetch can race ahead by the full
  embedStream depth (already gated by extractGate, so this is
  bounded transitively, but worth re-verifying).

### Option C — Async stream where stages are explicit

Full decomposition. Replace the single `embedDocuments` call with
four explicit streams:

```
batchStream → tokenize-stream → prepared-stream
                                    ↓
                            forward-stream
                                    ↓
                            pool+L2-stream
                                    ↓
                              accumStream
```

Each stream has its own bounded concurrency (e.g. tokenize=4,
forward=8 (= pool size), pool+L2=2, write=1). The embedder
becomes a thin protocol that exposes the three internal phases
rather than one fused `embedDocuments` call.

**Pros**: maximum flexibility; each stage tunable independently;
tokenize and pool+L2 can soak up CPU while forward runs on ANE.

**Cons**: largest refactor; cross-cuts every embedder
implementation; ordering invariants (chunk ↔ ordinal, file →
saveWork) become harder to maintain across more streams. Likely
not worth it unless the profile (companion experiment) shows
multiple sub-stages with comparable cost. **Defer until
E7-profile-indexing returns measurements that justify it.**

### Recommended shape for the first cut

**Option B**, with tokenize-only prefetch (concurrency=1,
look-ahead=1). It's the smallest change that exercises
pipelining at all. If profiling shows tokenize is <5 % of the
per-batch wall, abandon. If it's 10–20 %, Option B should
recover most of it. If it's higher *and* `compute-policy=auto`
is keeping forward on ANE while CPU is idle, escalate to
Option C.

## 4. Concurrency interactions

The dominant question: **at N=8 (current default), is the ANE the
shared resource that bottlenecks all 8 workers simultaneously?**
If yes, pipelining buys nothing — every worker is waiting on the
same hardware unit, and overlapping their per-worker tokenize
phases just shifts CPU work earlier without freeing the bottleneck.

Three sub-questions:

1. **Is CoreML's `bundle.model(...)` synchronous or actually
   parallel-friendly?** Under `compute-policy=auto` the placement
   may differ across batches; under `compute-policy=ane` (as in
   E6.3 winner) the ANE is a single hardware unit. Eight in-flight
   forward calls are serialized by the ANE driver internally.
   *If* that serialization is full (no per-call setup/teardown
   overlap), pipelining at the pipeline level is moot and the
   real win is fewer/larger batches, not earlier-tokenize.

2. **Does `await pooled.cast(...).shapedArray(...)` block the
   calling task for the entire materialize?** The MLTensor docs
   imply lazy evaluation up to materialize. If materialize blocks
   the caller's actor for tens of ms, eight workers materializing
   back-to-back can't overlap at all and pipelining their
   pre-forward phases buys nothing.

3. **Is the pool actually saturated today?** E6.3 picked N=8 as
   the global wallclock minimum on a 10-perf-core M-series host;
   N=10 was inferior, N=12 oversubscribed. That suggests the
   bottleneck above N=8 is *not* CPU for tokenize but CPU/ANE for
   forward. If forward truly saturates above N=8, within-worker
   pipelining might be a way to *get more useful work per pool
   slot* without raising N — which would make Option B a net win
   even though Option A's "more concurrent tokenize calls"
   would not.

The companion `E7-profile-indexing` plan is what makes these
sub-questions answerable. Without signposts we are guessing about
which stage dominates and whether it parallelizes.

## 5. Validation strategy

Two-step measurement.

1. **Profile before shipping any pipelining change.** Land
   `E7-profile-indexing` first. Use its signposts to:
   - measure per-batch wallclock split between
     tokenize / forward / materialize / fan-out;
   - measure pool occupancy under saturation (the
     `.poolAcquired` − `.poolReleased` gauge already exposed);
   - confirm whether forward-phase wallclock is correlated
     across the eight workers (suggesting a shared bottleneck)
     or anti-correlated (suggesting independent ANE/CPU
     placement).

2. **A/B against E6.5 defaults.** Once an Option B prototype
   exists, run two reindexes of `markdown-memory` at the
   E6.5 defaults (`pool=8 batch=32 bucket-width=500
   compute-policy=auto`):
   - control: current pipeline (no prefetch);
   - test: pipeline with tokenize-prefetch enabled.

   Run each three times, alternating, on AC power. Compute
   wallclock mean and stdev for each arm. The known E6.x
   run-to-run noise band on this corpus is **~11.6 %** (E6.4
   doc); a credible win has to clear that noise band with
   non-overlapping CIs. Use `vec update-index --db
   markdown-memory --embedder e5-base` after a `vec reset
   --db markdown-memory --force` for each run, per the
   project CLAUDE.md `markdown-memory` reset+reindex recipe.

3. **Quality guard at every run** (see §6). A failed quality
   guard invalidates the wallclock comparison.

## 6. Quality guard

**Pipelining must not change vector outputs.** The chunk →
embedding mapping must be byte-identical between control and
test runs.

Two checks:

1. **Rubric score reproduces.** After each test arm reindex,
   run `python3 scripts/score-rubric.py
   benchmarks/<alias>-<chunkChars>-<overlap>/` and confirm
   the TOTAL line matches the E6.x e5-base baseline (40/60).
   A drift here is an immediate red flag.

2. **Spot-check vector equality.** Pull 32 random chunks from
   the control DB and the test DB at matching `(file_path,
   ordinal)` keys, and assert byte-identical embedding bytes
   for each. (The embedding column is a BLOB of `Float`s in
   little-endian; `sqlite3 ... "SELECT hex(embedding) FROM
   chunks WHERE …"` is enough.) Even one bit-flip means
   pipelining has changed inputs to the model — likely a
   tokenize/prefix race — and the experiment must abort.

Both checks must pass before we accept any wallclock measurement
as a real result.

## 7. Success criteria

Ship the change only if **all three** hold:

- **Wallclock**: mean wallclock on `markdown-memory` drops
  ≥ 5 % vs the E6.5 defaults baseline (current ~891 s for
  e5-base per E6.6), with non-overlapping run-to-run CIs
  across the three-run A/B.
- **Quality**: rubric score on `markdown-memory` is unchanged
  (40/60), and the 32-chunk byte-equality spot-check passes.
- **Architecture**: the change is bounded — fits inside
  `IndexingPipeline.swift` plus one embedder file, doesn't
  expand the public `Embedder` protocol surface beyond an
  optional opt-in (default impl falls back to today's
  `embedDocuments`).

If wallclock comes back at +0–5 % (in noise), the experiment
ships as a "no-go" report and the code is reverted; pipelining
is not worth the architectural cost without a measurable win.

## 8. Blockers / open questions

Listed explicitly so a future agent can pick this up without
re-deriving them.

1. **Is the ANE shared across pool workers?** If `compute-policy
   = ane` (or `auto` falling back to ANE) means all eight workers
   are serialized on one hardware unit, within-worker pipelining
   is moot — the real lever is batch size or compute-policy
   choice. Need profile data to answer.

2. **Does CoreML forward return synchronously, blocking the
   worker until materialize?** Specifically, does
   `await pooled.cast(...).shapedArray(...)` (line 145) block
   the caller for the full forward duration, or is the
   forward-construction phase async and only `shapedArray`
   blocks for a small final readback? If the former, Option A's
   "tokenize next while forward runs" is invisible from the
   worker's POV — the worker is suspended on `await` for the
   whole forward. This determines whether Option A even has a
   theoretical win.

3. **Does tokenize parallelism contend with forward CPU
   placement under `compute-policy=auto`?** auto is the E6.5
   default. If MLTensor's auto-placement uses CPU for some
   sub-graphs, eight prefetch tokenize tasks running in
   parallel may steal cycles from forward. Need an A/B with
   `--compute-policy ane` to disambiguate.

4. **Is the per-file accumulator a hidden bottleneck that
   pipelining could expose?** Today the accumulator is a single
   `actor` with `add(...)` (line 741). Eight workers all calling
   `await accumulator.add(...)` serializes through one mailbox.
   If pipelining materially raises throughput, that mailbox
   could become the new bottleneck. The pre-existing
   `IndexingPipeline.swift:565` doc says "groups by file path";
   make sure the profile run captures `accumulator.add`
   wallclock too.

5. **`compute-policy=ane` tuning is out of scope for this
   experiment.** The E6.6 result (`gte-base` +65 % regression
   under auto) suggests the compute-policy axis is not
   well-explored model-by-model; that's the queued E6.7
   follow-up, not E7. E7 holds compute-policy fixed at the
   E6.5 default (`auto`) and varies only the pipelining shape.

6. **Hardware specificity.** vec's defaults are measured on a
   10-perf-core M-series machine (per
   `IndexingPipeline.swift:198–207`). Pipelining wins on
   different hardware classes (fewer perf cores, different
   ANE generation) are not in scope; we measure on Adam's
   host and ship if it wins there.

## Out of scope (for E7)

- DB-write parallelism. The `### E7 — DB-write parallelism`
  bullet in `plan.md` is a different future-work item; the
  writer is not the bottleneck today (per its own doc) and
  this plan does not touch it.
- Extractor parallelism. Same — `### Extractor parallelism`
  in `plan.md` is its own follow-up and is moot for
  text-only `markdown-memory`.
- New embedder shapes (compute-policy retuning, batch>32,
  etc.). E6.x already explored those axes.

## Sequencing

1. Land `E7-profile-indexing` (companion plan).
2. Read its profile output. If forward >> tokenize+materialize
   combined (say, ≥85 % of per-batch wall), close E7 as a
   no-go without writing prototype code.
3. Else, prototype Option B (tokenize-prefetch). A/B against
   E6.5 defaults per §5.
4. Either ship as E7.1 (defaults flip) or close as no-go with
   a one-paragraph report.
