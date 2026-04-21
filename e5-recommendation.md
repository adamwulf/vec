# What should E5 do — new models, or more optimization on bge-base?

Written 2026-04-21, after the E4 review cycle and the per-model
wallclock backfill. The full backlog of options lives in
`e4-next-steps-report.md`; this memo answers the narrower question
Adam asked: which of those options should run first.

## TL;DR

**Run model expansion first (E5 = §1 from the backlog), specifically
adding `bge-small-en-v1.5` and `bge-large-en-v1.5`.** Optimization
work on bge-base (E6 = §2/§3) returns less per hour right now, and
the model-expansion work also tells us *whether* further optimization
is worth doing.

## Why model expansion before more optimization

Three reasons, in declining order of weight:

### 1. E4 already harvested the cheap wallclock wins

E4 took bge-base from 1310 s → 1028 s (the fresh number measured
yesterday — the report's 997 s headline is within run-to-run
variance). The backlog optimizations (§2a batch=24/32, §2b bucket
width, §2c parallel DB writes) are all plausibly worth 5-15 % each
on top of the current 1028 s. Even stacked optimistically, that's
~700-800 s — a meaningful but bounded win, and bounded only because
on this corpus the embed step is now 98 % of wallclock and BNNS is
already pegged at b=16. Pushing past the BNNS cap (32) needs a model
swap anyway.

### 2. Quality has more headroom than speed on the rubric

bge-base scores 36/60 today. The rubric ceiling is 60. Even a
modest-quality model (bge-large) typically lifts MTEB by 2-3 points
versus bge-base, which on the markdown-memory corpus could
realistically translate to +4-8 rubric points. Compare that to
optimization wins, which are pure speed — they cannot move the
36/60 number.

The retrieval-quality story is the user-visible one ("did it find
the right doc"). Speed is the index-time story ("how long does
ingestion take"). Adam already pays the index time once per
re-ingestion — quality wins compound on every single search.

### 3. Smaller models inform whether optimization is worth doing

`bge-small-en-v1.5` is ~33 MB vs bge-base's ~110 MB and
~3-4× faster per chunk in benchmarks. If bge-small lands within
2-3 rubric points of bge-base on this corpus, the right next move is
to make it the default for users who care about speed — which is a
much bigger speedup than any §2/§3 optimization could deliver
without touching model size. If bge-small loses badly (say, under
30/60), then the model size matters here and we should invest the
optimization budget on bge-base. Either outcome is a clear signal
about where to spend the next round.

## Concrete E5 plan (next agent's recipe)

Priority order, each item independent:

1. **`bge-small-en-v1.5`**: add the alias to `IndexingProfileFactory`,
   wire it through `swift-embeddings` (same loader as bge-base, just
   different model id), run the rubric at 1200/240. Expected: ~270 s
   wallclock (extrapolated from per-chunk speed), ~30-34 / 60.
   Decision criterion: if rubric ≥ 32/60, ship as
   `bge-small@1200/240` and document as "small / fast" alternative.
2. **`bge-large-en-v1.5`**: same pattern, ~670 MB model. Expected:
   ~3000-3500 s wallclock (3× bge-base inference cost), ~38-42 / 60.
   Decision criterion: if rubric ≥ 40/60, ship as `bge-large@1200/240`
   and document as "max quality" option (default stays bge-base).
3. **Fix nomic load failure** (CoreML/ANE error caught yesterday,
   detailed in `e4-wallclock-comparison.md`): nomic at 768 dims is
   intended-supported but currently doesn't load on this macOS
   build. Either pin a working CoreML conversion, or remove nomic
   from the alias table to stop advertising a broken option.
4. **Fix the silent-failure mode that masked the nomic crash**:
   the pipeline reported "Update complete: 674 added, 0 updated"
   with exit 0 despite zero chunks landing in the DB. Phase-2
   review NB4 already flagged this as an observability gap; the
   nomic failure is the first time it's hidden a real bug. Suggest
   an assertion: if `chunks_extracted > 0` and `chunks_saved == 0`,
   exit non-zero with the underlying error.

## When to revisit optimization (E6)

Two trigger conditions:

- **bge-small ships as a viable speed-tier default** (item 1 above
  succeeds): the optimization work then targets bge-small, where
  per-chunk inference is ~25 ms and DB writes / extraction may
  start dominating sooner — which makes §2c (parallel DB writes)
  and §2f (extractor parallelism) higher-leverage than they are on
  bge-base today.
- **bge-small underperforms** (under 32/60): optimization on
  bge-base becomes the only path to faster indexing without a
  quality hit. At that point §2a (b=24 / b=32) is the cheapest
  first probe, with the §2b bucket-width sweep as a follow-up.

## What to skip / deprioritize

- `gte-base`, `e5-base`, `mxbai-embed-large` from the original
  §1 list. They're all in the same dim/size class as bge-base
  or bge-large; if bge-small + bge-large bracket the curve, the
  middle is well-explored. Revisit only if a specific corpus class
  (multilingual, code-heavy) calls for one of these.
- `nl-contextual` further chunk-size sweeps. The phase-D nl-contextual
  sweep already concluded the model is wrong for this corpus
  (3-2 / 60 across both 1200/240 and 800/160). Spending more
  iterations here is sunk cost. Keep it as the "no-install" tier
  embedder and stop trying to make it competitive on rubric.
- The MLX backend revisit (§2d). Still upstream-gated; adding it
  to the active backlog now would just delay model expansion.

## Open question worth answering before starting

Should the rubric corpus be expanded? Today every quality decision
hinges on 10 queries × 2 target files in markdown-memory. A model
that wins by +5 there might lose elsewhere. Recommendation: before
shipping bge-small or bge-large as defaults, run the rubric against
*one* additional corpus (a code repo seems easiest — vec's own
source tree could be the second corpus). If both rank the same
winner, we can ship with confidence. If they disagree, we've
discovered the corpus-dependence we suspected and should pause to
build per-corpus default selection before locking in a new global
default.

This is a one-time investment (~half a day to define the rubric on
a second corpus) that pays back on every subsequent embedder
decision.
