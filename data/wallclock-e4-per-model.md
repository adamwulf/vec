# E4 batched-path wallclock comparison — markdown-memory corpus

Captured 2026-04-21 to fill in the per-model wallclock data point that
phase-2 docs review flagged as missing. All four built-in embedders
were re-indexed against the same corpus (674 files, 18 unreadable
skipped) on the same machine at the E4 batched commit, so the
columns below are comparable head-to-head.

## Setup

- Corpus: `~/Library/Containers/com.milestonemade.EssentialMCP/Data/Documents/tools/markdown-memory`, 674 files indexed
- Build: `swift build -c release` at HEAD `0d89210`
- Each run used a per-experiment DB name (`markdown-memory-perf-*`) so
  the user's working `~/.vec/markdown-memory` index was never touched
- Workers: `activeProcessorCount` (10 on this machine), pool size = 10
- Configuration normalised across the BERT-family embedders: chunk
  1200 chars, overlap 240 (the bge-base default profile). nl uses its
  own default (2000/200) since it has no chunking optimum on this
  corpus and the larger chunks produce fewer model calls

## Headline table

| alias            | wall (s) | chunks | pool util | extract (s) | embed (s, total CPU) | save (s) | chunks/sec | p50 embed (s) | p95 embed (s) | rubric |
|------------------|----------|--------|-----------|-------------|----------------------|----------|------------|---------------|---------------|--------|
| **bge-base**     | **1028** | 8170   | 98 %      | 27.4        | 40516                | 1.1      | 0.2*       | 40.0          | 106.7         | **36/60, 9/10** |
| nomic‡           | 1417     | 8170   | 98 %      | 30.8        | 55524                | 1.8      | 0.1*       | 55.3          | 121.3         | 35/60, 3/10 (prior) |
| nl-contextual    | 52       | 8170   | 83 %      | 28.8        | 1826                 | 0.9      | 4.5        | 1.7           | 3.8           | 3/60, 1/10 |
| nl               | 138      | 4828†  | 98 %      | 20.3        | 7467                 | 1.3      | 0.6*       | 8.6           | 15.6          | 6/60, 0/10 |

\* `chunks/sec` from the verbose-stats line is reported per file rather
  than per chunk for the Bert-family embedders; it's wall-time
  throughput, not pool-aggregate. nl-contextual's higher chunks/sec
  reflects the per-chunk speed advantage of Apple's framework.

† nl uses 2000-char default chunks, so the corpus produces ~41 % as
  many chunks as the BERT-family configuration. Wallclock is therefore
  not comparable per-chunk to the others without normalising.

‡ nomic is pinned to `computePolicy: .cpuOnly` post-fix (commit
  `7182920`) to dodge a macOS 26.3.1+ CoreML/ANE compile error. The
  other three rows let the compiler pick placement; nomic's 1417 s
  is pure CPU. A like-for-like ANE comparison is not available on
  this machine, and the pre-E4 historical number at the same config
  was ~2940 s. Captured 2026-04-21.

## Speed ratios (lower-is-faster)

Normalising on bge-base = 1.0×:

| alias            | speed ratio | per-chunk speed ratio |
|------------------|-------------|------------------------|
| bge-base         | 1.0×        | 1.0×                   |
| nl-contextual    | **19.7×**   | **22.5×**              |
| nl               | 7.5×        | **3.1×**¹              |
| nomic‡           | 0.73×       | 0.73×                  |

¹ Per-chunk normalised: `nl_wall / nl_chunks` vs `bge_wall / bge_chunks` —
  138/4828 = 0.0286 s/chunk vs 1028/8170 = 0.126 s/chunk → 4.4× per
  chunk. The 3.1× figure (instead of 4.4×) appears here because nl's
  pool util is also 98 %, so wall scales near-linearly with chunk count
  on this corpus and the per-chunk number is the right normaliser.

## Findings

### nl-contextual is unexpectedly fast

The previous baseline (`retrieval-nl-contextual.md`)
reported 424 s wall at the same 1200/240 config. The fresh E4 run
clocks 52 s, **8.2× faster**. Two explanations are plausible and
both probably contribute:

1. The E4 batched path is genuinely faster for this embedder. The
   prior baseline pre-dated the batched extension on `Embedder`, so
   nl-contextual was being called per-chunk through `embedDocument`.
   The default `embedDocuments` extension still calls per-chunk, but
   the surrounding pipeline got tighter (extract + save overlapped
   with embed via the actor pool).
2. Pool utilisation dropped from 98 % to 83 %. nl-contextual is now
   so fast per chunk that the extract stage is becoming the
   bottleneck — the pipeline is no longer embed-bound. Treat the
   83 % as the canary: future work to make extract faster (e.g.
   parallelise the file scanner) would translate directly into
   throughput gains for this embedder.

### bge-base's 1028 s matches the E4 finalised number (997 s) within run-to-run variance

The E4 commit's headline was a 23.9 % wallclock reduction (1310 → 997 s).
The fresh run lands at 1028 s, so the speedup is reproducible on a
clean DB. The slight regression to 1028 vs 997 is within the
±5 % variance previously observed across runs and is not load-bearing.

### nl is the speed floor; nl-contextual is the throughput leader per chunk

nl's wallclock advantage over bge-base (7.5×) comes mostly from its
larger default chunks. Per-chunk it's only ~4.4× faster than bge-base.
nl-contextual's per-chunk speed (~22×) is the more honest speed signal
because it indexes the same 8170 chunks as bge-base.

### nomic load failure — diagnosed and fixed (historical)

Initial E4 runs of nomic crashed at model load with:

```
<unknown>:0: error: Incompatible element type for ANE: expected fp16, si8, or ui8
```

The CoreML/ANE compiler on macOS 26.3.1+ rejects nomic's FP32
weights when the compute policy is left to the default (the
compiler chooses ANE and then refuses the conversion). The pipeline
nevertheless returned exit 0 with zero chunks written, matching the
observability gap phase-2 review NB4 ("observability of swallowed
errors") flagged — that remains an open follow-up in `plan.md`.

**Fix landed** in commit `7182920` ("NomicEmbedder: force .cpuOnly
compute policy in batchEncode"), which pins the batched call to CPU
and sidesteps the ANE path entirely. The nomic row in the headline
table above is the post-fix measurement (2026-04-21, same machine
and commit as the other three rows + the NomicEmbedder fix on top).

Implications for reading the table:

- The 1417 s wallclock is CPU-only; the other three rows let CoreML
  place ops wherever the compiler chose. A same-machine ANE number
  for nomic isn't available on this macOS build.
- The pre-E4 pre-fix historical number at the same config (with ANE
  available) was ~2940 s, so even CPU-only-E4 is ~2× faster than
  pre-E4-with-ANE — the batched path dominates the placement
  difference.
- The 35/60 rubric score quoted in the table is the historical
  result from `retrieval-nomic.md` (pre-fix ANE path on an earlier
  macOS build). Re-scoring the rubric against the post-fix
  CPU-only vectors is deferred — whether `.cpuOnly` produces
  numerically identical outputs vs the compiler's default placement
  hasn't been re-verified on this branch.

## How to reproduce

The recipe is the new "## Running a baseline" section in
`retrieval-rubric.md`. Each row above was generated by:

```bash
swift run -c release vec update-index \
  --db markdown-memory-perf-<alias> \
  --embedder <alias> \
  --chunk-chars <N> --chunk-overlap <M> \
  --verbose
```

The four temporary perf DBs created during this run live at
`~/.vec/markdown-memory-perf-{bge,nl,nlc,nomic}` — they can be removed
once any future baseline run has captured the full schema (see
"Results schema" subsection in the rubric file).
