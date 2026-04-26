# E7 — Indexing wallclock master plan

PLAN ONLY. Sequences seven sub-experiments that each take a
different shot at cutting `e5-base@1200/0` indexing wallclock on
markdown-memory below the current **891 s** (E6.6 baseline at
E6.5 defaults: `pool=8 batch=32 bucket-width=500 compute-policy=auto`)
**without sacrificing rubric quality** (current 40/60, both-top10 5/10).

The seven sub-plans were drafted in parallel; this doc orders them
by dependency and expected EV, declares which run gates the others,
and sets a stop-when-done target.

## Why "performance" means wallclock here

Adam scoped this round explicitly: *reduce indexing time without
sacrificing quality*. Retrieval-quality work (rerankers, hybrid
search, query expansion) is parked. Every E7.x sub-experiment is
measured against:

- **Win:** ≥ X % wallclock cut at e5-base, **rubric ≥ 38/60**
  (the per-sub-plan X varies; aggregated stack target is ≥ 10 %).
- **No-go:** rubric drop below 38/60, OR wallclock change inside
  run-to-run noise (≤ 2 % at this corpus size).

## The seven sub-plans

Each links to its full plan file. Headline per row:

| ID | Title | Plan | Est. savings | Risk to rubric | Dependency |
|---|---|---|---|---|---|
| **E7.0** | Profile indexing pipeline | [E7-profile-indexing](../E7-profile-indexing/plan.md) | meta — informs all others | none (instrumentation only) | — |
| **E7.1** | FP16 inference + compute-policy | [E7-fp16-inference](../E7-fp16-inference/plan.md) | 10–30 % | very small | E7.0 (uses signposts) |
| **E7.2** | Tokenizer reuse + lifecycle | [E7-tokenizer-reuse](../E7-tokenizer-reuse/plan.md) | 5–10 % | none (byte-identical tokens) | E7.0 (gates if tokenize <3 % of wall) |
| **E7.3** | Pipeline-stage overlap | [E7-pipeline-overlap](../E7-pipeline-overlap/plan.md) | 5–15 % | none (byte-identical embeddings) | E7.0 (need per-stage breakdown) |
| **E7.4** | CoreML model format / mlpackage | [E7-mlmodel-format](../E7-mlmodel-format/plan.md) | 5–20 % | small (graph swap) | E7.0 + E7.1 (FP16 first) |
| **E7.5** | Batch-former refinements | [E7-batchformer-refine](../E7-batchformer-refine/plan.md) | 2–8 % | none (byte-identical embeddings) | E7.0 (need padding-waste breakdown) |
| **E7.6** | I/O optimizations (SQLite, batched writes) | [E7-io-optimization](../E7-io-optimization/plan.md) | 1–3 % | none (byte-identical writes) | E7.0 (gates if dbSeconds <1 % of wall) |

All seven plans converge on the same baseline anchor (891 s,
40/60, e5-base@1200/0, markdown-memory) and on the same drift
guard (Granola sync is operator-triggered per CLAUDE.md — ask
Adam if scores deviate noticeably from documented).

## Sequencing rationale

### Phase 1: Profile first (E7.0)

E7.0 is non-negotiable and runs first. Without per-stage timings
we'd be optimizing speculatively, and three of the other six plans
(E7.2, E7.3, E7.5, E7.6) explicitly gate on signpost numbers from
E7.0:

- E7.2 abandons if tokenize+mltensor-build is < 3 % of wall.
- E7.6 archives as "measured, not worth it" if dbSeconds is < 1 %
  of wall.
- E7.3 (pipeline-overlap) and E7.5 (batch-former) need per-batch
  forward-pass time vs padding waste vs tokenize overlap to choose
  between their internal options.

E7.0 is also the cheapest plan to execute — it's pure
instrumentation, no algorithmic change, no risk to outputs.

### Phase 2: The big lever (E7.1)

If E7.0 confirms the embed stage dominates wall (expected, given
E6.x history), E7.1 (FP16 inference) is the single highest-EV
follow-up. Estimated 10–30 % wallclock cut at zero quality risk
beyond known-small FP16 noise. It's the only sub-plan that touches
the inference math directly; every other plan is around the math.

E7.1 also has the cleanest "cell" structure: a 4–6-cell grid over
`{precision=fp32, fp16} × {policy=auto, ane, cpuOnly}`. The win or
no-win signal is unambiguous.

### Phase 3: Cheap parallel refinements (E7.2, E7.3, E7.5, E7.6)

After E7.1 lands (or doesn't), four sub-plans become independent
of each other and can run in parallel. Each lever is small (2–10 %)
but **stacks linearly** if the changes touch disjoint code paths.
Run order within Phase 3 is free; suggested:

1. **E7.6 first** — smallest, fastest to verify or archive. SQLite
   PRAGMAs + batched writes is a 1-day sprint at most; a clean
   negative result is also valuable for future "where's the
   wallclock going" conversations.
2. **E7.2** — tokenizer-reuse, 5–10 % at zero quality risk. The
   levers are small code changes (cache buffers, share tokenizer
   across actors) and the validation is byte-identical token grids.
3. **E7.5** — batch-former refinements. More invasive than E7.2
   but well-bounded: four named levers (within-bucket sort,
   padding-aware tie-break, variable batch size per bucket,
   cross-bucket borrow). Validation is byte-identical embeddings.
4. **E7.3** — pipeline-stage overlap. The most architecturally
   intrusive of the four; only run if Phase 2 + the other three
   leave headroom on the table. Validation is byte-identical
   embeddings.

### Phase 4: The big-bet lever (E7.4)

E7.4 (CoreML model format / mlpackage conversion) is the largest
scope and deepest change — it would replace swift-embeddings'
MLTensor JIT path with a pre-compiled `.mlpackage` loaded via
`MLModel`. Estimated 5–20 % cut, but the implementation cost is
much higher than any other sub-plan. **Run E7.4 only if Phase 1–3
falls short of the aggregate ≥10 % stack target.**

E7.4 also depends on E7.1: knowing whether FP16 alone unblocks ANE
acceleration tells us whether the mlpackage rewrite needs to
include a precision flip or just a graph format flip.

## Aggregate target

Stack target across all seven phases: **≥ 10 % wallclock cut**
(891 s → ≤ 802 s) at rubric ≥ 38/60. Baseline metric is the
median of three runs at HEAD before the first E7 commit; stop
condition is one of:

- Three sub-plans land green and the cumulative wall is ≤ 802 s.
- Phase 1–3 lands and aggregate wall is < 850 s — call it done,
  archive E7.4 as deferred.
- Phase 1–3 lands but aggregate wall is still > 870 s — promote
  E7.4 to the active queue and target a single 10 %+ jump.

## Cross-cutting risks

1. **Run-to-run noise.** E6.x established noise band ≈ ±2 % at
   this corpus size. Any sub-plan claiming < 3 % needs to clear
   the bar via three-run median, not a single sample.
2. **Corpus drift.** Operator-triggered (Granola sync). Every
   sub-plan must check the e5-base baseline rubric (40/60) on its
   first run; if it shows ≥ 2 points off, escalate before
   investigating — see `CLAUDE.md` and `MEMORY.md` for the rule.
3. **Stack non-linearity.** Two changes that each save 5 %
   independently may save < 10 % combined if they target the
   same hotspot. After each Phase-3 sub-plan ships, re-measure the
   E7.0 signpost breakdown to confirm the next lever still has
   savings on the table.
4. **Quality guard cascade.** Every sub-plan has a quality bar
   (rubric ≥ 38/60). The cumulative effect across multiple ships
   is a small but non-zero drift risk; a final "all-changes-on"
   rubric run at the end of E7 is mandatory before merging the
   stack to main.

## Out of scope for E7

These are expressly NOT covered by the seven sub-plans, and would
be E8 candidates if pursued:

- New embedder models (gated by swift-embeddings loader limits;
  arctic-embed-m and stella-base-en-v2 already evaluated and
  rejected — see `indexing-profile.md` "Candidates evaluated but
  not shipped").
- Retrieval-quality changes (rerankers, hybrid search, query
  expansion). Adam scoped this round to wallclock only.
- Cross-corpus validation. Markdown-memory is the canonical
  benchmark; corpus-portability is its own follow-up.
- Hardware-specific tuning. The `defaultConcurrency = 8`
  doc-comment already flags machine-specificity for future
  hardware upgrade. E7 inherits the same machine envelope.

## What this plan is not

Not an implementation. Each E7.x sub-plan is its own commit and
can be promoted to active work independently. This master plan
orders them; it does not execute them.
