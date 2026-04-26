# E7 — Batch-former refinements beyond bucket-width

PLAN ONLY. Successor to E6.4 (`bucket-width=500` confirmed at the
E6.3 winner anchor `N=8 b=32 ane`, no default change). E6.4 closed
the **bucket-width** dimension. This experiment opens the next four
dimensions of the batch-former that E6.x never touched.

## Why this experiment exists

E6.3 reduced `e5-base@1200/0` wall-clock from 1081.1 s → 937.2 s
(−13.3 %, in-grid) by tuning `(N, batch_size, compute_policy)`.
E6.4 confirmed the bucket-width default `/500` is already optimal
at that anchor. But `bucket-width` is only **one** of several
levers in the batch-former code path. Four others are untested:

1. **Within-bucket sort order.** Today chunks land in append order.
   A length-sort (longest-first or shortest-first) inside each
   bucket would tighten the per-batch length distribution, reducing
   the longest-element padding waste.
2. **Padding-aware tie-breaking on Rule 2.** Today's "flush largest
   bucket" rule (`buckets.max(by: { $0.value.count < $1.value.count })`)
   ignores per-batch padding cost.
3. **Variable batch size per bucket.** Today every bucket flushes
   at the global `batchSize=32`. Short-chunk buckets could run
   larger batches at the same memory cost; long-chunk buckets
   could shrink to avoid the BNNS-cap pad penalty.
4. **Cross-bucket borrowing for trailing partials.** At
   `embedStream` close, every non-empty bucket flushes as-is —
   guaranteed sub-`batchSize` final batches per active bucket.
   Borrowing from neighbouring buckets could reduce the count of
   short tail batches.

Estimated additional savings: 2–8 % wall on `e5-base@1200/0`. The
upper bound assumes E6.4's "padding cost roughly equals parallelism
gain" interpretation is correct — i.e. real waste exists at the
batch boundary that bucket-width alone can't reach.

## Code being modified — quote first, change later

The entire batch-former is the inner-task body at
[`Sources/VecKit/IndexingPipeline.swift:429–467`](../../Sources/VecKit/IndexingPipeline.swift).
Quoted verbatim:

```swift
// Stage 1.5: Batch-former. Drains embedStream, length-buckets
// by chunk.text.count / bucketWidth (minimizes batchEncode
// padding waste; default width 500 char). Flush rules, in
// order:
//   1. If any bucket hits batchSize, flush it (preferred: full
//      batch = best pool utilization, minimal padding).
//   2. Else, if total buffered items reaches batchSize, flush
//      the largest bucket. Needed to guarantee forward
//      progress — without this, pathological inputs where
//      every few chunks go to a different bucket would stall
//      extract behind its backpressure gate forever (no
//      bucket ever reaches batchSize; stream-close never fires).
//   3. On embed-stream close, flush every remaining partial
//      bucket so the run finishes cleanly.
// Rule 2 caps the amount of work sitting in buckets at
// 2*batchSize − 1 worst case (totalBuffered hits batchSize
// pre-flush, Rule 2 drops the largest bucket of ≥1 item) —
// guarantees bounded memory under any input distribution.
group.addTask {
    var buckets: [Int: [EmbedWork]] = [:]
    var totalBuffered = 0
    for await work in embedStream {
        // Each loop iteration appends exactly one chunk, so at
        // most one bucket's count increments per pass. Rule 1
        // (full-bucket flush) and Rule 2 (largest-bucket flush)
        // are mutually exclusive via `else if`, so at most one
        // flush fires per iteration. This is what keeps the
        // 2*batchSize − 1 worst-case `totalBuffered` bound.
        let bucket = work.chunk.text.count / bucketWidth
        buckets[bucket, default: []].append(work)
        totalBuffered += 1
        if buckets[bucket]!.count >= batchSize {
            let flushed = buckets.removeValue(forKey: bucket)!
            totalBuffered -= flushed.count
            batchContinuation.yield(BatchWork(items: flushed))
        } else if totalBuffered >= batchSize {
            // No bucket has filled, but we've accumulated a
            // batch's worth spread across buckets. Flush the
            // largest bucket to keep the pool fed.
            // Tie-break is Dictionary.max's unspecified order —
            // non-deterministic across runs. Embeddings are
            // unaffected (ordinals preserved); only the padding
            // cost of the chosen batch varies, making wall-clock
            // a slightly noisy signal on heterogeneous corpora.
            if let (biggest, _) = buckets.max(by: { $0.value.count < $1.value.count }) {
                let flushed = buckets.removeValue(forKey: biggest)!
                totalBuffered -= flushed.count
                batchContinuation.yield(BatchWork(items: flushed))
            }
        }
    }
    // Extract stream closed — flush remaining partial buckets.
    for (_, items) in buckets where !items.isEmpty {
        batchContinuation.yield(BatchWork(items: items))
    }
    batchContinuation.finish()
}
```

Key observations from the quote:

- **No within-bucket sort.** `buckets[bucket, default: []].append(work)`
  preserves arrival order. When Rule 1 fires, the flushed batch's
  per-chunk `chunk.text.count` distribution is whatever the extract
  stage produced, in the order it produced it.
- **Rule 2 tie-break is non-deterministic.** The pre-existing code
  comment calls this out: when multiple buckets tie at the same
  `count`, `Dictionary.max` returns "unspecified order". This is
  already flagged as a wallclock-noise source.
- **No cross-bucket borrowing at close.** The closing loop emits
  one `BatchWork` per bucket regardless of how short.
- **Bucket key drives padding.** A bucket spans `bucketWidth=500`
  characters of input length. At b=32 a bucket batch may contain
  one chunk near `bucket*500+499` and 31 chunks near `bucket*500`,
  so the longest element drives the pad-to-longest tokenizer
  cost (`tokenizeTextsPaddingToLongest` for E5;
  `bundle.batchEncode` for the BERT family). Bucket-width is a
  cap on the **range** of lengths, not the **realized** longest.

## How padding actually happens — verify the model

E5-base `meanPooledBatch` calls
[`bundle.tokenizer.tokenizeTextsPaddingToLongest(texts, padTokenId: 0, maxLength: 512)`](../../Sources/VecKit/E5BaseEmbedder.swift)
at line 101. The name is dispositive: padding length is the longest
input in `texts`, capped at 512. **The bucket-width key never
reaches the tokenizer.** So padding cost is driven by:

`pad_seq_len = min(512, longest_chunk_token_len_in_batch)`

Forward-pass FLOPs per batch ∝ `batch_count * pad_seq_len² * hidden_dim`
(attention is quadratic in sequence length; the b=32 cap holds
`batch_count` constant). **Halving `pad_seq_len` quartiles attention
cost for that batch.** This is the lever within-bucket sort and
adaptive batch size are reaching for.

BGE/GTE/Mxbai/Nomic `embedDocuments` all funnel through
`bundle.batchEncode(..., padTokenId: 0, maxLength: 512)` — same
"pad to longest in batch" semantics. So findings here transfer
across the whole embedder family, not just e5-base.

**Important: bucketing already gives the batch-former most of
this win.** A bucket at `chunk.text.count / 500 = 3` covers chunks
1500–1999 chars. Within that bucket, longest-vs-mean ratio is
already capped at 4/3 = 1.33×. Realistic gain from a within-bucket
sort lands in the 5–15 % range on attention cost per batch — and
attention is one term in the forward pass, not the whole. End-to-
end wallclock improvement is attenuated further by stages outside
the embed call (extract, DB, pool acquire/release).

## Padding-waste estimate from the markdown-memory corpus

The E6.4 anchor reindex captured 8070 chunks at `1200/0`. We
don't have a chunk-length histogram archived, but we can bound it:

- `IndexingProfile` fixed `chunkChars = 1200, overlap = 0` →
  every chunk is approximately 1200 chars except the trailing
  chunk per file.
- Boundary chunks (file end) skew shorter; embedded code blocks
  stay together so a markdown chunk often falls 600–1100 chars.
- E5's `maxInputCharacters = 2000` cap is moot at this profile —
  the 1200/0 chunker doesn't produce anything that large.

Cheap empirical step (do this in the experiment, not the plan):
**dump chunk-length distribution** for one full extract pass on
the `markdown-memory` corpus at `e5-base@1200/0`. We have a
profiler scaffold (see "Companion experiment" §) that can emit
per-batch `(actual_seq_len, longest_in_batch_seq_len, padded_count)`
counters and roll them up. **No tuning lever moves until that
counter exists.**

Speculative bound on the achievable win: if average bucket fill is
80 % (28/32 chunks) and within-bucket length variance brings
realized `pad_seq_len` to 1.15× of the bucket-mean, then a perfect
sort drops `pad_seq_len` to ~1.02×. That's ~12 % attention-FLOPs
saved per batch, ~5 % end-to-end wall (attention is one term).
This is the high end of the 2–8 % estimate.

## The four levers

### Lever A — Within-bucket sort by length

**Mechanism.** Sort each bucket by `chunk.text.count` immediately
before flushing (longest-first or shortest-first). Goal: tighten
the per-batch realized `pad_seq_len`.

**Trade-off.** Bucketing already constrains length range to
`bucketWidth=500` chars. Within-bucket variance is whatever the
chunker produces inside that 500-char window. For markdown-memory
at `1200/0`, almost every "live" bucket should be `bucket=2`
(1000–1499 chars). Bucket 0 (0–499 chars) would catch trailing
short chunks. So the sort's biggest leverage is on bucket-0 and
on whichever "natural" bucket holds the bulk of the corpus.

**Why both directions.** Longest-first inside a bucket means the
first batch flushed contains the largest items; subsequent batches
are smaller. With Rule 1 firing as soon as a bucket hits 32, the
sort doesn't change which 32 items ship together — it changes the
order **within** the batch tensor. Pad-to-longest is a max
operation across the batch; **the order inside the batch does not
affect the result.** ⚠️ This invalidates Lever A as written.

**Refinement.** The actual lever is "sort across buckets at flush
time, build batches that minimize within-batch range." The
algorithm becomes:

1. Inside Rule 1's 32-item flush, **leave order alone** (cosmetic).
2. Inside Rule 2 (cross-bucket forced flush) and Rule 3 (close-out),
   **sort the candidate items by length first**, then form
   contiguous batches of up to `batchSize`. This bypasses the
   bucket map for the tail and feeds the embedder near-uniform-
   length batches.

This is materially different from "sort within a bucket" — it's
"sort the spillover queue." Memory the conclusion: **a within-
bucket sort is a no-op when Rule 1 fires; the real lever is
sorting the cross-bucket residue at flush boundaries.** The plan
keeps Lever A but renames it.

**Lever A (renamed): cross-bucket length-sort at Rule 2 / Rule 3
flushes.** When Rule 2 forces a flush because no bucket reached
32, sort all currently-buffered chunks by length and flush the
top-32-longest as one batch (or the bottom-32-shortest — pick the
clump with smaller variance). When Rule 3 fires at stream close,
sort the entire residue and ship contiguous-by-length batches.

### Lever B — Padding-aware tie-breaking inside Rule 2

**Mechanism.** Replace
`buckets.max(by: { $0.value.count < $1.value.count })` with
a comparator that scores each candidate bucket by **batch-FLOPs
cost** (≈ `count * pad_seq_len²`) and picks the lowest cost. When
two buckets tie on count, the one whose longest chunk is shorter
wins.

**Trade-off.** Adds an O(items_in_bucket) scan to each flush
decision. With 32-item buckets the cost is trivial. The win is
strictly conditional: it only fires on Rule 2, which itself only
fires under bucket-fragmentation. On a homogeneous-chunk corpus
(e.g. markdown-memory at `1200/0`) Rule 2 is rare. So Lever B's
ceiling is small — but the change is also small and composes
with Lever A.

### Lever C — Variable batch size per bucket

**Mechanism.** Compute a per-bucket `effectiveBatchSize` from
the bucket key. Short-chunk buckets (`bucket=0`, len 0–499 chars)
flush at a higher count (e.g. 32 stays the cap, but the user-
visible benefit appears when we **lower** the cap on long-chunk
buckets to avoid wasted attention compute).

The formula candidates:
- **Inverse-length scaling**: `effectiveBatchSize = min(32,
  max(8, round(K / max(1, bucket+1))))` for some constant K.
  Small buckets unchanged at 32; long-chunk buckets shrink.
- **FLOPs-budget**: pick `effectiveBatchSize` such that
  `effectiveBatchSize * pad_seq_len² ≈ const` across buckets.

**Trade-off.** Smaller batches per long-chunk bucket reduce ANE
amortization — E6.3 showed b=32 beats b=16 by 6–11 %. So Lever C
is only a win if the FLOPs saved on padding exceed the dispatch
cost lost. For a 1200/0 corpus where almost every chunk is
~1200 chars, **all chunks land in roughly the same bucket and
Lever C does nothing useful.** This lever lights up on
heterogeneous corpora — code repos, PDFs, transcripts — and on
embedders with smaller char-caps. Run it but expect a flat
result on markdown-memory.

### Lever D — Cross-bucket borrowing for trailing partials

**Mechanism.** At Rule 3 (`embedStream` close), instead of
`for (_, items) in buckets where !items.isEmpty { yield(BatchWork(items)) }`,
merge adjacent buckets whose combined count is ≤ `batchSize`.
A bucket at key=2 with 7 items and a bucket at key=3 with 9 items
flush as one 16-item batch (whose `pad_seq_len` is bucket-3's
max).

**Trade-off.** The merged batch incurs the larger bucket's
padding cost on the smaller bucket's items. Net win only if the
fixed per-batch dispatch cost (warmup, MLTensor graph, ANE
hand-off) exceeds the extra padding cost. Whether that crosses
zero depends on:
- How small the average tail bucket is (≪ 32 = win likely).
- Bucket-width spacing (adjacent buckets at `/500` differ by
  500 chars, which is a meaningful pad-cost step).

This is the lever with the cleanest "test, ship, or revert"
signal — it changes the count of trailing batches, easy to
measure.

## Quality guard — bit-identical retrieval

The batch-former is **purely** an indexing-time scheduler. The
embedder's per-text output is a pure function of `(model, text)`
once tokenizer behavior is held constant. None of the four levers
modify the text fed to `Embedder.embedDocuments`; they only modify
**which texts ride together in a batch** and **in what order**.

Two failure modes to rule out:

1. **Pad-to-longest changes attention math?** No. Padding tokens
   are masked in attention (`attentionMask` zeroes them), and E5's
   masked mean pool excludes pad positions explicitly
   ([`E5BaseEmbedder.swift:138-142`](../../Sources/VecKit/E5BaseEmbedder.swift)).
   Adding more pad tokens to a sequence does not perturb the live
   tokens' contextualized embeddings (verified via the existing
   E6.3/E6.4 sweeps, all of which produced **bit-identical**
   retrieval output across different batching configurations).

2. **Order of items inside a tensor batch changes anything?**
   No. BERT/E5 attention is independent across batch dim. The
   batch dimension is a parallelism axis, not a context axis.
   Reordering rows in the input tensor reorders rows in the
   output tensor — `unpackAndReinterleave` then routes outputs
   back via per-item `slots`/`ordinal` indices.

**Validation protocol.** Every E7 sweep point must produce
TOTAL=38/60, TOP10_EITHER=9/10, TOP10_BOTH=5/10 against the
[`e5-base-baseline-2026-04-24`](../../benchmarks/e5-base-baseline-2026-04-24/)
reference. Any deviation = bug, not a finding. The E6.3/E6.4
sweeps both produced bit-identical retrieval across **every**
batching point; matching that bar is non-negotiable.

## Companion experiment — E7-profile-indexing (signposts)

Levers A–D are all about reducing wasted attention FLOPs on pad
tokens. We cannot tune blind. **Before any lever lands**, instrument
the pipeline to emit two counters per batch:

1. `actual_token_count` — sum of attention-mask 1s across the
   batch (live tokens).
2. `padded_token_count` — `batch_size * pad_seq_len` (total
   tokens including pad).

Padding waste fraction = `1 - actual / padded`. If this number is
already <5 % on markdown-memory at the E6.3 winner anchor, **stop
the experiment** — there is no fat to trim and the upper-bound
estimate of 2–8 % was wrong. Do NOT proceed to lever sweeps.

Companion plan: `experiments/E7-profile-indexing/plan.md` (sibling
file). It defines:
- The profiler scaffold (a `BatchProfile` struct, summed in a
  StatsCollector field, dumped to `summary.md`).
- A one-shot pre-experiment run that produces the corpus's
  baseline padding-waste number and per-batch forward-time
  histogram.

E7-profile-indexing is a **prerequisite** to E7-batchformer-refine.
Don't fork lever sweeps until the profiler tells us the ceiling
is real.

## Experiment protocol

Conditional on E7-profile-indexing reporting padding waste ≥ 5 %.

**Anchor.** All sweeps run at the E6.5 default `(N=8, b=32, ane,
bucket-width=500)` against `markdown-memory` reset+reindexed at
`e5-base@1200/0`. Same exact config E6.3/E6.4 used so wallclock
deltas are apples-to-apples.

### Phase 1 — Lever A (cross-bucket length-sort at Rule 2/Rule 3)

Three points:

| Point | Description |
| --- | --- |
| `A0` | Reference: existing batch-former, no changes (re-run E6.4's `bucket=500` archive). |
| `A1` | Sort residue at Rule 2 + Rule 3 by length, flush contiguous-by-length batches. |
| `A2` | Same as A1 but **also** sort the bucket map keys at Rule 3 (merge sort-vs-borrow with Lever D's idea). |

Invocation pattern (after the lever is wired behind a hidden flag
`--batch-sort-strategy`):

```
swift run -c release vec sweep \
  --db markdown-memory --embedder e5-base \
  --sizes 1200 --overlap-pcts 0 \
  --concurrency 8 --batch-size 32 --compute-policy ane \
  --bucket-width 500 \
  --batch-sort-strategy <none|lengthSortResidue|lengthSortAll> \
  --out benchmarks/sweep-e7-batchformer/lever-A-<point> --force
```

Bit-identical retrieval check on every point — same gate as E6.3/E6.4.

### Phase 2 — Lever B (padding-aware Rule 2 tie-break)

Two points:

| Point | Description |
| --- | --- |
| `B0` | Reference (= A0). |
| `B1` | Replace `buckets.max(by: count)` with a `(count, -longestLen)` comparator. |

Same invocation shape, swap flag for `--rule2-tiebreak <count|cost>`.

### Phase 3 — Lever C (variable batch size per bucket)

Three points:

| Point | Description |
| --- | --- |
| `C0` | Reference (= A0). |
| `C1` | `effectiveBatchSize = clamp(round(K / (bucket+1)), 8, 32)` for K=64. |
| `C2` | Same with K=96 (more aggressive shrink on large buckets). |

`--per-bucket-batch <off|inverse64|inverse96>`.

### Phase 4 — Lever D (cross-bucket borrowing on close)

Two points:

| Point | Description |
| --- | --- |
| `D0` | Reference (= A0). |
| `D1` | At Rule 3, sort buckets by key and merge adjacent residues with combined count ≤ batchSize. |

`--rule3-merge <off|adjacent>`.

### Phase 5 — Best combination

If any of A/B/C/D individually clear the 3 % bar, run a final point
combining the winners. Then a 3-rep replicate to confirm the
combined number isn't run-to-run noise (E6.3 documented ~11.6 %
in-grid noise; we'd need to clear that or repeat).

## Success criteria

- **Headline.** ≥ 3 % wallclock reduction vs the E6.5-default
  reference (= E6.4's `bucket=500` archive at 937.2 s on the same
  corpus). The 3 % bar matches the noise floor of the E6.3 sweeps;
  anything smaller is unprovable on a single-corpus single-run
  test.
- **Defaults flip.** ≥ 5 % wallclock reduction on the **best
  combination** point, with bit-identical retrieval, replicated
  3× within 2 % of each other. Matches the E6.3 defaults-update
  rule.
- **Hard requirement.** Bit-identical retrieval on every point
  (38/60, 9/10, 5/10 against the baseline). A point that fails
  this is a bug to fix before publishing the wallclock number.

## Blockers / open questions

1. **Padding waste might already be near zero.** If E7-profile-
   indexing reports < 5 % padding waste at the E6.5 default
   anchor on markdown-memory, **abort E7-batchformer-refine**.
   The 2–8 % win estimate assumed real padding waste exists; if
   it doesn't, we're tuning noise.

2. **Markdown-memory corpus is too homogeneous to exercise
   Levers C / D.** Almost every chunk lands in one bucket
   (`bucket = 1200 / 500 = 2`), so the per-bucket adaptive levers
   have nothing to bite on. **Mitigation**: run a second corpus
   for the lever sweeps — a code repository (e.g. one of the
   `vec` Sources/ sub-directories) or an untouched stub corpus
   produced from chunkSize=600/overlap=20 over the same source.
   Heterogeneity across corpora was an explicit follow-up
   recommendation in plan.md §"Length-bucket width tuning".
   Do not block lever-A / lever-B (they target the homogeneous-
   bucket Rule-2 fragility) on having a second corpus, but do
   add a heterogeneous corpus before drawing conclusions about
   levers C / D.

3. **Rule 2 tie-break determinism is a hidden variable.** E6.4
   noted: `Tie-break is Dictionary.max's unspecified order —
   non-deterministic across runs`. So even **two reps of the
   same E6.4 anchor** can wallclock-disagree by some amount
   purely from tie-break shuffling. Lever B's win has to clear
   that invisible noise floor. **Mitigation**: include a 2-run
   replicate at the reference point (A0/B0/etc) to bound the
   tie-break noise contribution.

4. **`--batch-sort-strategy` adds CLI surface area for
   experiment-only flags.** Pattern from E6.1 was to ship the
   lever as a stable CLI flag from day one. For E7 the levers
   may not be defaults-worthy; consider making the flags
   "internal" (no help text, prefixed `--x-`, document in
   `plan.md`'s experiments section only). Open question for the
   manager: ship as stable flags or experiment-only?

5. **ANE forward-time vs CPU forward-time.** E6.3 found ANE wins
   only at N=8. Lever C's per-bucket batch sizing changes
   per-batch FLOPs, which changes the ANE-vs-auto preference
   per-bucket. If a future user runs E7 levers on `auto`, the
   conclusions will be different. **Mitigation**: keep `ane`
   pinned across all E7 sweep points; do not vary
   compute-policy.

6. **Refinement of Lever A invalidated the within-bucket
   sort.** Documented above. The refined Lever A targets the
   residue at Rule 2/Rule 3, not the within-bucket order. Plan
   keeps the rename; no re-design needed.

## Out of scope

- Raising the `batchSize` cap above 32 (separate experiment;
  blocked on swift-embeddings #17 BNNS fix).
- Pre-tokenizing in extract to drive bucket keys by **token**
  count instead of **character** count (would tighten padding
  estimates but adds a stateful tokenizer to extract; rejected
  here — character count is a cheap proxy that already gets us
  within 1.3× of optimal).
- Cross-file batching (already happens — `EmbedWork` doesn't
  carry a per-file constraint, the bucket-former pools across
  the whole `embedStream`).
- Embedder-internal optimizations (anything inside
  `bundle.batchEncode` or `meanPooledBatch`); E7 stops at the
  call boundary.
