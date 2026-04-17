# Embed Pipeline Backpressure Diagnosis

## Symptom

Running `vec update-index --verbose` against a single text-heavy corpus
showed embed queue depth oscillating in a sawtooth: the queue would
drain `10 → 9 → 8 → … → 1`, then refill in one observable step back to
`10`. With pool size 10 (and `ExtractBackpressure` capacity =
`workerCount * 2`), this means extract was producing chunks in batches
rather than refilling the queue one chunk at a time as embed tasks
completed.

Sample verbose output (10s sample interval):

```
Indexing: 0/924 | 168 ch | extract q 1 | embed q 7/10 | save q 0 | bn ok | 26.0s | 6 c/s avg, 18 30s
Indexing: 0/924 | 354 ch | extract q 1 | embed q 8/10 | save q 0 | bn ok | 36.0s | 10 c/s avg, 18 30s
Indexing: 0/924 | 532 ch | extract q 1 | embed q 6/10 | save q 0 | bn ok | 46.1s | 12 c/s avg, 18 30s
```

Steady-state throughput stalled at ~18 chunks/sec in the 30s window
even though the embed pool had 10 workers. Bottleneck classifier
reports "ok" because no single queue is pinned, but the pool is
chronically under-utilized.

## Initial wrong turns (recorded so we don't repeat them)

1. **"extract q is always 1, that's the bottleneck — bump the
   buffer."** False. `extract q` is `extractEnqueued −
   extractDequeued`, and extract is a single serial task by design
   (`IndexingPipeline.swift:277`). The counter only ever reads 0 or 1
   regardless of buffer sizing — the doc comment at
   `UpdateIndexCommand.swift:21` calls this out explicitly. A bigger
   `ExtractBackpressure` cap addresses a different problem (memory on
   huge corpora), not throughput.

2. **"Extract is too slow on large files — overlap file N+1's read
   with file N's embed."** Plausible for PDF-heavy corpora, but the
   reproducing run is one text file with hundreds of fast chunks. Per-
   file extract latency is not the limiter here.

3. **"`ExtractBackpressure` is an actor, the per-chunk acquire/release
   actor hop is the throttle."** Per-chunk actor hops are cheap
   relative to NLEmbedding work (~50–100ms per embed). They add
   overhead but don't explain the *batched* refill pattern. If actor
   hop cost were the issue, we'd see a smooth-but-slow refill, not a
   sawtooth.

## Root cause

In the embed task body (`IndexingPipeline.swift:383-435`), the steps
after a chunk finishes embedding ran in this order:

```swift
await pool.release(embedder)              // line 394 — pool slot freed
await statsCollector.recordChunkEmbed(…)  // line 397 — actor hop
…build EmbeddedChunk…
accumContinuation.yield(emitted)          // line 426 — sync, but takes
                                          // the AsyncStream's internal lock
await extractGate.release()               // line 433 — releases the
                                          // permit extract is waiting on
```

`accumContinuation.yield` is synchronous, but it acquires the
`AsyncStream`'s internal buffer lock, and the consumer side
(`for await emitted in accumStream` on the accumulator stage,
`IndexingPipeline.swift:444`) holds the same lock when delivering each
element. If the accumulator does any non-trivial work per delivery —
in particular, when a file completes and `closeIfComplete` fires a
`.saveEnqueued` progress event, which takes the renderer's `NSLock`
(`UpdateIndexCommand.swift:69`) and writes to stdout — that work is
serialized against every embed task that's trying to yield.

The cascade:

1. One embed task hits `accumContinuation.yield` while the accumulator
   is mid-bookkeeping for a completing file.
2. The other 9 in-flight embed tasks reach line 426 and stall there.
3. None of them have called `extractGate.release()` yet — the gate
   sees zero new permits.
4. Extract is blocked at `extractGate.acquire()`, the embed stream is
   draining one chunk per cycle (the one currently being embedded by
   each pool worker).
5. The accumulator finishes its bookkeeping; all 10 stalled yields
   complete in rapid succession; all 10 `extractGate.release()` calls
   fire back-to-back; extract slams 10 new chunks onto the embed
   stream.

That sequence reproduces the observed `1 → 10` jump exactly. The
`extract q` counter never moves off 1 because extract is technically
busy the whole time — it's just busy *waiting on the gate*, not
producing.

## Fix (initial probe)

Reorder lines 426 and 433 so `extractGate.release()` happens **before**
`accumContinuation.yield(emitted)`.

Justification for safety: the permit gates "is there pool capacity for
the next chunk?", and `pool.release` already ran on line 394. The
accumulator handoff is downstream bookkeeping — it doesn't need to
complete before extract is allowed to produce the next chunk. The
permit is released on every path (success or vector == nil failure),
preserving the existing deadlock guarantee.

Applied in this branch — see `IndexingPipeline.swift:427-446`.

## What to measure

Re-run `vec update-index --verbose` against the same corpus.
Hypothesis: embed queue depth should refill smoothly (visible
intermediate values like 5 → 6 → 5 → 7 instead of 1 → 10), and
windowed chunks/sec should rise above ~18 c/s.

If the sawtooth persists at the same magnitude, the gating is
elsewhere — next suspect would be the `EmbedderPool` actor's
acquire/release pattern (line 657), or the renderer lock under
contention from many simultaneous `.chunkEmbedded` events.

## Open questions for reviewers

- Is reordering the release safe in **all** the embed-failure
  branches? The current fix moves the release out of the natural
  "after handoff" position; double-check the `vector == nil` path
  still releases exactly once.
- Does the accumulator actually stall long enough to matter, or is
  there a second source of batching we're missing? An instrumented
  run that timestamps `extractGate.release` calls would settle this
  empirically.
- If the fix works, `ExtractBackpressure` is still useful for memory
  bounding on large corpora — keep it, but its capacity tuning
  matters less.
