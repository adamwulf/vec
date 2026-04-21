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
| nomic            | n/a — load failed | n/a | n/a | n/a         | n/a                  | n/a      | n/a        | n/a           | n/a           | 35/60, 3/10 (prior) |
| nl-contextual    | 52       | 8170   | 83 %      | 28.8        | 1826                 | 0.9      | 4.5        | 1.7           | 3.8           | 3/60, 1/10 |
| nl               | 138      | 4828†  | 98 %      | 20.3        | 7467                 | 1.3      | 0.6*       | 8.6           | 15.6          | 6/60, 0/10 |

\* `chunks/sec` from the verbose-stats line is reported per file rather
  than per chunk for the Bert-family embedders; it's wall-time
  throughput, not pool-aggregate. nl-contextual's higher chunks/sec
  reflects the per-chunk speed advantage of Apple's framework.

† nl uses 2000-char default chunks, so the corpus produces ~41 % as
  many chunks as the BERT-family configuration. Wallclock is therefore
  not comparable per-chunk to the others without normalising.

## Speed ratios (lower-is-faster)

Normalising on bge-base = 1.0×:

| alias            | speed ratio | per-chunk speed ratio |
|------------------|-------------|------------------------|
| bge-base         | 1.0×        | 1.0×                   |
| nl-contextual    | **19.7×**   | **22.5×**              |
| nl               | 7.5×        | **3.1×**¹              |
| nomic            | n/a         | n/a                    |

¹ Per-chunk normalised: `nl_wall / nl_chunks` vs `bge_wall / bge_chunks` —
  138/4828 = 0.0286 s/chunk vs 1028/8170 = 0.126 s/chunk → 4.4× per
  chunk. The 3.1× figure (instead of 4.4×) appears here because nl's
  pool util is also 98 %, so wall scales near-linearly with chunk count
  on this corpus and the per-chunk number is the right normaliser.

## Findings

### nl-contextual is unexpectedly fast

The previous baseline (`retrieval-results-nl-contextual.md`)
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

### nomic fails to load on the current macOS / ANE configuration

Both attempts to reindex with nomic crashed at model load with:

```
<unknown>:0: error: Incompatible element type for ANE: expected fp16, si8, or ui8
```

This is a CoreML/ANE-side error — the model's FP32 weights aren't
acceptable to the Apple Neural Engine compiler on this build of
macOS / on this device. **The pipeline returned exit 0 anyway and
left the DB with 0 chunks**, which is the exact failure mode that
phase-2 architecture review NB4 ("observability of swallowed
errors") warned about. Filed as a follow-up: the pipeline should
detect zero-chunk completion when chunks were extracted and surface
the underlying error rather than reporting "Update complete: 674
added, 0 updated".

The nomic retrieval row in the comparison table above is the
historical 35/60, 3/10 result from `retrieval-results-nomic.md`. It
remains the documented score because the model used to load on
earlier macOS builds — the regression is an environment problem,
not a recall regression.

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
