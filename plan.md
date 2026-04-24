# vec — Plan

The rolling plan for the `vec` project. Covers what has shipped,
what's in progress, and what should happen next.

- **Reference** (stable): [`README.md`](./README.md) • [`indexing-profile.md`](./indexing-profile.md) • [`retrieval-rubric.md`](./retrieval-rubric.md)
- **Raw experiment data**: [`data/`](./data/)
- **Cited external research**: [`research/`](./research/)
- **Per-experiment plans + reports**: [`experiments/`](./experiments/)
- **Superseded snapshots**: [`archived/`](./archived/)

Last updated: 2026-04-24.

---

## Current state (as of 2026-04-24, post-E5.9b, default flipped to e5-base)

**Default embedder**: `e5-base@1200/0` (E5-base-v2, 768-dim,
masked mean-pooled with `passage: ` / `query: ` prefix injection
inside the embedder). Flipped from `bge-base@1200/240` on
2026-04-23 after E5.7 established e5-base at 40/60 vs bge-base's
36/60 on markdown-memory (see "E5.7 headline finding" below and
`data/retrieval-e5-base-sweep.md` §4 for the evidence).

**Rubric score on markdown-memory**: 40/60, 9/10 top10_either,
**6/10 top10_both** (scored with `scripts/score-rubric.py` against
the 10-query trademark rubric). See
[`retrieval-rubric.md`](./retrieval-rubric.md) for the rubric
definition.

**Wallclock on markdown-memory**: ~1025 s at N=10 workers,
batchSize=16 on a 10-core Apple Silicon machine — parity with
bge-base's ~1003 s, no throughput cost for the quality gain.
Per-model comparison in
[`data/wallclock-e4-per-model.md`](./data/wallclock-e4-per-model.md).

**Built-in embedders**: `e5-base` (default), `bge-base`, `bge-small`,
`bge-large`, `gte-base`, `mxbai-large`, `nomic`, `nl-contextual`, `nl`.
See [`indexing-profile.md`](./indexing-profile.md) for the profile
grammar and [`README.md`](./README.md#built-in-embedders) for the
comparison table. As of E5.4 / E5.6 / E5.7 / E5.8, the BGE tier,
gte-base, e5-base, and mxbai-large defaults are sweep-tuned on
markdown-memory rather than seeded:

| alias       | default       | rubric | sweep file |
|-------------|--------------|--------|------------|
| bge-small   | `1200/0`     | 30/60  | `data/retrieval-bge-small-sweep.md`   |
| bge-base    | `1200/240`   | 36/60  | `data/retrieval-bge-base-sweep.md`    |
| bge-large   | `1200/0`     | 34/60  | `data/retrieval-bge-large-sweep.md`   |
| gte-base    | `1600/0`     |  8/60  | `data/retrieval-gte-base-sweep.md`    |
| e5-base     | `1200/0`     | 40/60  | `data/retrieval-e5-base-sweep.md`     |
| mxbai-large | `800/80`     | 31/60  | `data/retrieval-mxbai-large-sweep.md` |

Cross-model finding (E5.4 → E5.8): **bge-base uniquely prefers
overlap at size 1200.** bge-small, bge-large, gte-base, e5-base, and
mxbai-large all peak at `1200/0` *or below the 1200 band entirely* —
overlap is harmful, flat, or recovers only partially for them at
size 1200. bge-base is the only model in the registry whose rubric
peak sits at 1200/240 (36/60). mxbai-large's peak shifts down to
`800/80` (the only registered embedder peaking in the 800 band),
likely because its required query prefix
(`"Represent this sentence for searching relevant passages: "`) eats
~10 BERT WordPiece tokens of the 512-token budget, effectively
shrinking its context window. The E5.4d distillation-smooths-the-
space hypothesis is now strongly weakened: gte-base is distilled and
rejects overlap, e5-base is not distilled and also rejects overlap,
mxbai-large is not distilled and peaks below the 1200 band. The
"bge-base wants overlap at 1200" finding is most plausibly a
bge-base-specific pretraining/objective-mix artifact, not a
dim-tier or distillation property.

**E5.7 headline finding: e5-base BEATS bge-base on markdown-memory.**
`e5-base@1200/0` = 40/60, 9/10 top10_either, 6/10 top10_both vs
bge-base@1200/240 = 36/60, 9/10, 3/10 on the same corpus with the
same rubric and near-identical wallclock (~1025 s vs ~1003 s).
`IndexingProfileFactory.defaultAlias` was flipped from `bge-base`
to `e5-base` on 2026-04-23 on the strength of this evidence. A
second-corpus confirmation is still open under E5.9 (below);
if the cross-corpus ranking diverges, the default may revisit. See
`data/retrieval-e5-base-sweep.md` §4.

**Known issues**:
- None outstanding in the E5.4 scope. The silent-failure observability
  gap (open pre-E5) is now closed — `vec update-index` exits non-zero
  when every embed attempt failed. See E5.1 in the Done section.
- Corpus-generalization of the per-model peaks is still unverified.
  E5.4e (deferred) would rerun winners against a second corpus; see
  "Next" below.

---

## Done

All shipped on the current branch, in rough chronological order.

### Nomic migration (2026-04-17 → 2026-04-18)

Replaced Apple's `NLEmbedding.sentenceEmbedding` with
`nomic-embed-text-v1.5` (768-dim) via `swift-embeddings`. Raised
the rubric ceiling from **6/60 → 35/60** (5.8×) on markdown-memory.
Chunking tuned to `RecursiveCharacterSplitter` 1200/240 after a
12-iteration parameter sweep.

- Plan (executed, archived for shape reference): [`archived/2026-04/nomic-experiment-plan.md`](./archived/2026-04/nomic-experiment-plan.md)
- Raw sweep data: [`data/retrieval-nomic.md`](./data/retrieval-nomic.md)
- NL baseline it replaced: [`data/retrieval-nl.md`](./data/retrieval-nl.md)
- Historical status snapshot (pre-Phase-D): [`archived/2026-04/status.md`](./archived/2026-04/status.md)

### E1 — Multi-core embedding pool (2026-04-20)

Turned the single-instance `EmbedderPool` into an N-instance actor
pool so the 10 workers in the indexing pipeline stopped contending
on one mailbox. Shipped at N=10, wallclock 1310 s, pool util 98 %,
aggregate 2.5 chunks/sec on markdown-memory.

- Plan: [`experiments/E1-multicore/plan.md`](./experiments/E1-multicore/plan.md)

### Phase D — Embedder expansion (2026-04-19)

Added two new built-in embedders — `bge-base-en-v1.5` (MIT, 768-dim)
and `nl-contextual` (Apple, 512-dim, zero install) — alongside the
existing `nomic` and `nl`. Selected per-embedder default chunk
parameters by sweep against the rubric. **Default embedder flipped
from `nomic` to `bge-base`** after bge-base scored 36/60 vs nomic's
35/60 and delivered 9/10 top-10 vs nomic's 3/10.

- Plan + final comparison: [`experiments/PhaseD-embedder-expansion/plan.md`](./experiments/PhaseD-embedder-expansion/plan.md)
- Raw data: [`data/retrieval-bge-base.md`](./data/retrieval-bge-base.md) • [`data/retrieval-nl-contextual.md`](./data/retrieval-nl-contextual.md)
- External survey that seeded the picks: [`research/embedder-survey.md`](./research/embedder-survey.md)

### E4 — Batched embedding (2026-04-20)

Added `Embedder.embedDocuments([String])` with a BGE/Nomic batch
override using `swift-embeddings`' `batchEncode`. Rewired
`IndexingPipeline` through a length-bucketing batch-former with a
reduced-worker / batched-inference topology. **23.9 % wallclock cut**
(1310 s → 997 s) with bit-identical retrieval (36/60, cosine ≥
0.9999 vs single-embed). Peak RSS dropped 4.6 GiB → 1.5 GiB.

- Plan: [`experiments/E4-batched-embed/plan.md`](./experiments/E4-batched-embed/plan.md)
- Commits + sweep table: [`experiments/E4-batched-embed/commits.md`](./experiments/E4-batched-embed/commits.md)
- Lessons + what-happened: [`experiments/E4-batched-embed/report.md`](./experiments/E4-batched-embed/report.md)
- Per-model wallclock at E4 commit: [`data/wallclock-e4-per-model.md`](./data/wallclock-e4-per-model.md)

### E5.1-3 — Silent-failure guard + bge-small + bge-large (2026-04-21)

Three sub-deliverables closed on 2026-04-21:

**E5.1 — Silent-failure observability guard** (commit `8d63753`).
The indexing pipeline now exits non-zero with
`VecError.indexingProducedNoVectors` when every embed attempt fell
into `.skippedEmbedFailure` on a non-empty work list. The nomic
CoreML/ANE failure that hid for a release cycle is now a loud
failure. `SilentFailureGuardTests` covers the exit-code + summary
paths.

**E5.2 — `bge-small-en-v1.5` (384-dim, "fast tier")** registered as
a built-in alias. Single-point rubric at the seeded 1200/240 defaults:
**25/60, 7/10 top-10, wall 692 s** (1.49× bge-base per chunk). Raw
data in [`data/retrieval-bge-small.md`](./data/retrieval-bge-small.md).

**E5.3 — `bge-large-en-v1.5` (1024-dim, "max quality tier")**
registered as a built-in alias. Single-point rubric at the seeded
1200/240 defaults: **31/60, 8/10 top-10, wall 4891 s** (0.21×
bge-base per chunk). Raw data in
[`data/retrieval-bge-large.md`](./data/retrieval-bge-large.md).

**Policy reversal on drop gates.** The initial E5.2 and E5.3 plans
each defined a hard rubric floor ("≥32/60 to ship bge-small",
"≥40/60 to ship bge-large") and dropped both models after single
runs at 1200/240. That drop was reversed on 2026-04-21: a single
chunk-geometry measurement is not sufficient evidence to remove a
model from the registry. 1200/240 was picked for direct
comparability with bge-base, not because it is either model's
optimum. Both models are now retained in
`IndexingProfileFactory.builtIns`; finding each model's actual
rubric peak via a full chunk sweep is the first task in E5.4.

- Commits: `8d63753` (E5.1 silent-failure guard), `a145ade` (bge-small),
  `ca42af5` (bge-large), `356f4d3` (restore both after drop reversal).
- Raw data: [`data/retrieval-bge-small.md`](./data/retrieval-bge-small.md) •
  [`data/retrieval-bge-large.md`](./data/retrieval-bge-large.md)

### E5.4a-d — Chunk-geometry sweeps for all three BGE tiers (2026-04-21 → 2026-04-22)

Four sub-deliverables closed. Replaces the seeded-from-bge-base
defaults for bge-small/bge-large with measured peaks, confirms
bge-base@1200/240, and surfaces a non-obvious cross-model finding.

**E5.4a — `vec sweep` subcommand** (commits `e82720b` + `197424c`).
Single Swift process: reset → reindex → 10 rubric queries →
in-process scorer → per-point q01..q10.json archive + summary.md
row. Scorer is byte-for-byte parity with
`scripts/score-rubric.py`. Two-round code review; round 2 APPROVED
by both reviewers. Added `--force` confirmation, per-iteration
`VectorDatabase` actor scoping via `runGridPoint` helper, and
parseGrid dedupe + non-sequential-n support.

**E5.4b — bge-small chunk sweep** (commit `b05cf47`). 15 points
(sizes ∈ {400,600,800,1200,1600}, overlap_pcts ∈ {0,10,20}) over
~3 h 40 min wallclock. **Peak: `bge-small@1200/0` → 30/60**, up
from 25/60 at the seeded 1200/240 (+5 pts). Overlap is harmful at
size ≥ 1200 for this 384-dim model, helpful at size ≤ 800. Default
updated. Raw data in
[`data/retrieval-bge-small-sweep.md`](./data/retrieval-bge-small-sweep.md).

**E5.4c — bge-large chunk sweep** (commit `44e5e09`). 12 points
(sizes ∈ {800,1200,1600,2000}, overlap_pcts ∈ {0,10,20}) over
~9 h 42 min wallclock. **Peak: `bge-large@1200/0` → 34/60**, up
from 31/60 at the seeded 1200/240 (+3 pts). Dramatic `2000/0`
cliff at 17/60 — biggest chunks with no overlap lose 11 pts vs
neighboring configs; overlap restores them. Default updated. Raw
data in
[`data/retrieval-bge-large-sweep.md`](./data/retrieval-bge-large-sweep.md).

**E5.4d — bge-base chunk sweep** (commit `12152b9`). 12 points,
~3 h 3 min wallclock. **Two-way tie at 36/60**: `1200/240`
(existing default, 3/10 top10_both) and `800/80` (5/10
top10_both). Primary metrics tied; default kept as 1200/240 rather
than churn the historical default on a softer secondary signal.
Both co-peak configs documented in
[`data/retrieval-bge-base-sweep.md`](./data/retrieval-bge-base-sweep.md)
for the E5.4e tie-breaker.

**Cross-model lesson.** bge-small and bge-large both peak at
`1200/0` — overlap is harmful at size 1200 for them. bge-base
uniquely benefits from overlap at 1200 (its peak is 1200/240). The
pattern is NOT monotone in embedding dimension (384 < 768 > 1024
on "tolerates overlap"); plausibly related to bge-base being a
distilled model. Worth carrying forward as a Phase E lesson.

**Scope cut for E5.4e.** Corpus-generalization (rerunning the
per-model peaks against a second corpus) was deferred. Building a
code-corpus rubric that probes semantic understanding beyond
filenames needs domain input; attempting it synthetically risks
fabricating queries that every config aces. See "Next" below.

### E5.6 — gte-base-en-v1.5 + chunk sweep (2026-04-22)

Added `thenlper/gte-base` (768-dim, CLS-pooled + L2-normalized,
no query/passage prefix) as a new built-in embedder alongside the
existing BGE tiers. Ran the same 12-point chunk-geometry sweep grid
used for bge-base (E5.4d) for direct comparability:

  sizes: {400, 800, 1200, 1600}  ×  overlap_pcts: {0%, 10%, 20%}

**Peak: `gte-base@1600/0` → 8/60, 3/10 top10_either, 0/10 top10_both.
Wallclock 974 s for the winning point; total sweep wall ≈ 9 h 38 min.**

gte-base is dramatically below bge-base on this corpus: the peak
geometry (8/60) is a quarter of bge-base@1200/240's 36/60, and is
worse than bge-base's *worst* geometry in the same grid (28/60 at
2000/0). Spot-checking the per-query archives showed gte-base
systematically returns the wrong file from the right meeting
(`notes.md` instead of `summary.md` / `transcript.txt`) on
trademark-price queries — a content-discrimination failure, not a
chunk-geometry one. No grid point rescues it.

**No global-default change.** bge-base@1200/240 (36/60) stays as
the default. gte-base is retained as an opt-in built-in with its
measured peak (1600/0) stamped as its default, not as a default
candidate on markdown-memory. If a second corpus is sweep-tested
under E5.4e, rerunning gte-base@1600/0 there is a cheap second
data point to confirm whether this ranking generalizes.

**Cross-model counter-evidence.** E5.4d hypothesized that bge-base's
unique preference for overlap at 1200 was related to distillation
smoothing the embedding space. gte-base is also distilled (from a
larger gte teacher) but rejects overlap at 1200 like the undistilled
BGE tiers, with scores too low to read much signal from the
overlap-progression anyway. That weakens the distillation-smoothing
story; the bge-base-vs-everything-else gap is more plausibly
training-data / pretraining differences than distillation.

- Commits: `e794c91` (add embedder, provisional default),
  `7504a8c` (sweep results + measured peak default).
- Sweep archive: [`benchmarks/sweep-gte-base/`](./benchmarks/sweep-gte-base/)
- Raw data + observations:
  [`data/retrieval-gte-base-sweep.md`](./data/retrieval-gte-base-sweep.md)

### E5.7 — e5-base-v2 + chunk sweep (2026-04-23)

Added `intfloat/e5-base-v2` (768-dim, **masked mean-pooled** with
`"passage: "` / `"query: "` prefix injection) as a new built-in
embedder alongside the existing BGE tiers and gte-base. Unlike every
other Bert-family embedder in the registry (CLS-pooled via
`Bert.ModelBundle.encode`), `E5BaseEmbedder` drives `bundle.model(...)`
directly so the attention mask flows into both the encoder and the
mean-pool, then L2-normalizes per row. Prefixes are injected
inside the embedder so callers remain prefix-unaware (same
`Embedder` protocol surface as bge-* / gte-base).

Ran the same 12-point chunk-geometry sweep grid used for bge-base
(E5.4d) and gte-base (E5.6) for direct comparability:

  sizes: {400, 800, 1200, 1600}  ×  overlap_pcts: {0%, 10%, 20%}

**Peak: `e5-base@1200/0` → 40/60, 9/10 top10_either, 6/10 top10_both.
Wallclock 1025 s at the winning point; total sweep wall ≈ 4 h 0 min.**
`e5-base@400/40` is a co-peak on total_60 (40/60, 10/10 top10_either,
5/10 top10_both) and loses the tiebreaker on the stricter
top10_both metric.

**e5-base BEATS bge-base@1200/240 on markdown-memory.** +4 on
total_60 (40 vs 36), 2× on top10_both (6 vs 3), and essentially
identical wallclock and storage cost (both 768-dim, both Bert-family
via swift-embeddings). This is the first measured candidate
global-default change since bge-base replaced nomic in Phase D.
**Not self-applied** — the E5.7 commit updates only the e5-base
alias default (1200/240 → 1200/0) and leaves
`IndexingProfileFactory.defaultAlias` as `bge-base`. A follow-up
commit after manager review would flip the global default and
update this plan's Current-state numbers.

**Cross-model finding:** e5-base joins bge-small, bge-large, and
gte-base in rejecting overlap at size 1200. bge-base is now
confirmed as the lone outlier in the registry preferring overlap at
1200. The distillation-smooths-the-space hypothesis from E5.4d is
further weakened: gte-base is distilled and rejects overlap,
e5-base is not distilled and also rejects overlap, only bge-base
wants it. The three-way 768-dim comparison table
(`data/retrieval-e5-base-sweep.md` §3) is the first direct
head-to-head across three Bert-family 768-dim models with different
pooling / prefix conventions on the same corpus + rubric.

**Score distribution is healthy.** Per-query similarity scores at
the peak config span ~0.77–0.87 (wide dynamic range, no tight-cone
anisotropy). The literal-match probe (`"bean counter mode
trademark"`) placed the target transcript.txt at rank 1 and
summary.md at rank 5 — both targets in top 5 on a near-literal query.

- Commits: `ea458a9` (add embedder, provisional 1200/240 default),
  `4792953` (sweep results + measured peak default + plan.md + writeup).
- Sweep archive: [`benchmarks/sweep-e5-base/`](./benchmarks/sweep-e5-base/)
- Raw data + observations:
  [`data/retrieval-e5-base-sweep.md`](./data/retrieval-e5-base-sweep.md)

### E5.8 — mxbai-embed-large-v1 + chunk sweep (2026-04-23)

Added `mixedbread-ai/mxbai-embed-large-v1` (1024-dim, BERT-large,
**CLS-pooled** with explicit L2 normalization) as a new built-in
embedder under the `mxbai-large` alias alongside the existing 1024-dim
bge-large. Shape difference vs every other Bert-family embedder in
the registry: an **asymmetric, query-only prefix** —
`"Represent this sentence for searching relevant passages: "` —
applied inside `MxbaiEmbedLargeEmbedder.embedQuery` per the model
card. Documents take no prefix. Unique among the registry's
Bert-family embedders: BGE/GTE apply no prefix on either side,
e5-base prefixes both sides, mxbai prefixes queries only. Callers
remain prefix-unaware (same `Embedder` protocol surface).

Ran the same 12-point chunk-geometry sweep grid used for bge-large
(E5.4c) for direct 1024-dim head-to-head comparability:

  sizes: {800, 1200, 1600, 2000}  ×  overlap_pcts: {0%, 10%, 20%}

**Peak: `mxbai-large@800/80` → 31/60, 8/10 top10_either, 4/10
top10_both. Wallclock 3638 s at the winning point; total sweep wall
≈ 13 h 56 min** (~4 h longer than bge-large's E5.4c sweep due to two
thermal/placement slowdowns at 1600/160 and 2000/200 — rubric scores
unaffected). `mxbai-large@800/160` is a co-peak on total_60 (31/60)
and loses the tiebreaker on top10_both (3 vs 4).

**mxbai-large does NOT beat bge-large@1200/0 on markdown-memory.** −3
on total_60 (31 vs 34), −1 on top10_either (8 vs 9), +1 on top10_both
(4 vs 3). The +1.5 MTEB-leaderboard headroom over bge-large does NOT
transfer to this corpus's rubric. mxbai is also well below bge-base@1200/240
(36/60, −5) and e5-base@1200/0 (40/60, −9). It is the worst-scoring
sweep-tuned default in the 768/1024-dim tier, and per-rubric-point cost
is the worst in the registry (117 s/pt vs bge-base 28 s/pt and e5-base
26 s/pt).

**No global-default change.** bge-base@1200/240 (36/60) stays as the
default; the open candidate-default question (e5-base over bge-base)
from E5.7 remains the only outstanding global-default decision and is
unaffected by this experiment. mxbai-large is retained as an opt-in
1024-dim alternative to bge-large with its measured peak (800/80)
stamped as its default, but it is NOT a default candidate on
markdown-memory.

**Cross-model finding: mxbai is the only registered embedder peaking
in the size-800 band.** bge-base / bge-small / bge-large / e5-base /
gte-base all peak at size ≥ 1200 (e5-base co-peaks at 400/40 but its
tiebreaker peak is 1200/0). mxbai's peak shift is most plausibly
explained by the query-prefix budget: the prefix tokenizes to ~10
WordPiece tokens, eating a meaningful fraction of the 512-token max
sequence and pushing the optimal chunk size down. mxbai also wants
overlap at *every* size band except the 1200/0-vs-mid-overlap dip
(matching bge-large's pattern at that band). The 2000/0 cliff is
reproduced for the third time (bge-base 28, bge-large 17, mxbai 18) —
strongly confirming this is a markdown-memory corpus property
(~1 KB conversational-turn granularity), not a model artifact.

**Sibling-file content discrimination is mxbai's failure mode.** On
the literal-match probe at the smoke config (1200/0): the right
*meeting* surfaces in top 5 but mxbai ranks `notes.md` at #3 and
target `summary.md` at #14, with target `transcript.txt` outside top
20. Compare e5-base (transcript.txt #1, summary.md #5 on the same
probe). mxbai gets the topic right but the file-within-topic wrong —
a much milder version of gte-base's E5.6 content-discrimination
pathology. The 8/10 top10_either ceiling across the entire grid is
the structural consequence: two queries simply do not surface a
target in top 10 at any geometry mxbai swept.

- Commits: `eb4893f` (add embedder, provisional 1200/0 default),
  `43dac4c` (sweep results + measured peak default + plan.md + writeup).
- Sweep archive: [`benchmarks/sweep-mxbai-large/`](./benchmarks/sweep-mxbai-large/)
- Raw data + observations:
  [`data/retrieval-mxbai-large-sweep.md`](./data/retrieval-mxbai-large-sweep.md)

### E5.9a — e5-base peak refinement (2026-04-23)

9-point mini-sweep around the E5.7 coarse peak (`e5-base@1200/0` →
40/60) to answer whether a ±100-size / ±5%-overlap neighbor hides a
better configuration than the coarse grid surfaced. Grid:

  sizes: 1100, 1200, 1300  ×  overlap_pcts: 0%, 5%, 10%

**Peak unchanged: `e5-base@1200/0` → 40/60, 9/10 top10_either, 6/10
top10_both, wall 861 s at the peak.** Runner-up `1100/110` lands at
39/60 (−1 pt, −1 top10_both). Total sweep wall ≈ 2 h 29 min.

- **Before refinement**: `e5-base@1200/0` → 40/60 (E5.7 coarse, 12
  points, ±400/±10% spacing).
- **After refinement**: `e5-base@1200/0` → 40/60 (E5.9a refine, 9
  points, ±100/±5% spacing around the coarse peak). Every
  refinement-only neighbor scores strictly lower on total_60 — the
  peak is a single-point peak, not a plateau.
- **Global-default flip corroborated.** The coarse grid's "peak
  might be a grid artifact" uncertainty is resolved; 40/60 is robust
  under refinement. `IndexingProfileFactory.defaultAlias` was
  flipped from `bge-base` to `e5-base` earlier on 2026-04-23
  (commit `00e3fd3`) on the strength of the E5.7 coarse result;
  this refinement confirms that was not a grid artifact. Cross-
  corpus validation (E5.9b/c + second-corpus rubric) remains open
  and could still move the default if a different corpus ranks
  candidates differently.

**Reproducibility anchors.** `1200/0` and `1200/120` are in both
this grid and the E5.7 coarse grid. Both reproduced bit-exactly on
total_60, top10_either, top10_both, and chunk count (0-pt deviation).
Wallclock drifted ~15% — expected CoreML/ANE placement variance that
doesn't affect deterministic rubric scores.

**Cross-row finding: overlap behavior is size-dependent for e5-base.**
At size 1100, 10% overlap recovers most of the loss from shrinking
the chunk (33 → 39). At size 1200, any overlap is a small net loss
(40 → 38). At size 1300, overlap is flat (34 → 33 → 33). The
coarse grid's "e5-base rejects overlap at 1200" finding survives at
the finer 5% step — 1200/60 lands at 38, below 1200/0's 40 and tied
with 1200/120's 38. No hidden 5%-overlap sweet spot.

**No default change.** `IndexingProfile.swift` already stamps
`e5-base` with `1200/0` defaults per the E5.7 commit (`4792953`);
this refinement corroborates that value rather than moving it. No
edit to `indexing-profile.md` either.

- Sweep archive: [`benchmarks/sweep-e5-base-refine/`](./benchmarks/sweep-e5-base-refine/)
- Raw data + observations:
  [`data/retrieval-e5-base-refine.md`](./data/retrieval-e5-base-refine.md)

### E5.9b — bge-base peak refinement (2026-04-24)

12-point refinement (two 3×2 sub-grids) around the E5.4d two-way
tie on `bge-base` at 36/60 (`1200/240` vs `800/80`):

  Large-chunk: sizes 1100, 1200, 1300 × overlap_pcts 20%, 25%
  Small-chunk: sizes  700,  800,  900 × overlap_pcts  5%, 10%

Grid intentionally includes both tie-peak anchors (`1200/240` and
`800/80`) for reproducibility checks.

**Large-chunk sub-grid peak: `bge-base@1200/240` → 34/60** (tied
with `bge-base@1300/325` → 34/60 on total_60; `1300/325` wins
`top10_both` 3 vs 2).
**Small-chunk sub-grid peak: `bge-base@800/80` → 32/60**,
`top10_both=4`.
**The tie breaks in favor of the large-chunk regime by 2 pts on
total_60** (34 vs 32 at the sub-grid peaks). `bge-base@1200/240`
remains the correct default; the newly-discovered `1300/325` is
documented as a tied co-peak worth checking on a second corpus.

- **Before refinement**: E5.4d two-way tie at 36/60 between
  `1200/240` and `800/80`; default kept at `1200/240` on historical-
  continuity grounds, not on a clear primary-metric preference.
- **After refinement**: tie broken in favor of the large-chunk
  regime (34 vs 32 at the sub-grid peaks on primary metric).
  `1200/240` remains the best config in the large sub-grid, tied
  with the refinement-only `1300/325` at 34/60. Default unchanged.

**Reproducibility anchors DID NOT reproduce bit-exactly.** Unlike
E5.9a (which reproduced e5-base's `1200/0` anchor with 0-pt
drift), bge-base's two tie-peak anchors drifted on both total_60
and chunk count:

  1200/240:  E5.4d 36 / 8170 ch   →   E5.9b 34 / 8742 ch   (−2 pts, +7.0% chunks)
  800/80:    E5.4d 36 / 11496 ch  →   E5.9b 32 / 12316 ch  (−4 pts, +7.1% chunks)

The ~7% chunk-count growth on both anchors with no changes to
the chunker or embedder source between E5.4d and E5.9b points to
**corpus drift on the live `markdown-memory` folder** as the
cause. E5.4d ran 2026-04-22 (commit `598a072`); E5.9b ran
2026-04-23/24. Two days of user-side additions to the source
folder is the simplest and only consistent explanation. The
E5.9a e5-base refinement reproduced bit-exactly because E5.7
and E5.9a shared a same-day corpus snapshot. This is a finding
about the test corpus, not a bug in the indexer or scorer.

**Implications for the cross-model comparison**: the E5.7
`e5-base@1200/0` vs `bge-base@1200/240` delta (+4 / +3) was
measured on a single-snapshot pre-drift corpus and remains the
canonical flip evidence. Under the E5.9b corpus snapshot
`e5-base` still sits at 40/60 (bit-exact) while `bge-base`
dropped 2-4 pts at its anchors — the *gap* between the two on
the drifted snapshot is 6-8 pts rather than 4-6 pts, but the
pre-drift 4-6 pt gap is the evidence the global-default flip
was made on and does not retroactively weaken. E5.9b does not
move the global default.

**Cross-model finding preserved**: `bge-base` still uniquely
benefits from overlap at size 1200 at the finer (25%) probe.
The 0 → 10% → 20% → 25% shape is 33 → 29 → 34-36 → 33 across
E5.4d+E5.9b — overlap at 20% is the peak, 25% starts to roll
off, no hidden sweet spot.

**No default change.** `IndexingProfile.swift` already stamps
`bge-base` with `1200/240` per commit `c6c2578` (Phase D).
`indexing-profile.md`'s bge-base row (`1200/240 → 36 / 3`)
stays as-is; the footnote ³ commentary about the 1200/240-vs-
800/80 tie is refined by this sweep but the row values are the
canonical pre-drift E5.4d numbers. No edit to
`indexing-profile.md` in this commit.

- Sweep archives: [`benchmarks/sweep-bge-base-refine-large/`](./benchmarks/sweep-bge-base-refine-large/), [`benchmarks/sweep-bge-base-refine-small/`](./benchmarks/sweep-bge-base-refine-small/)
- Raw data + observations:
  [`data/retrieval-bge-base-refine.md`](./data/retrieval-bge-base-refine.md)

---

## In progress

E5.9b is the latest shipped sub-deliverable. Peak refinement
resolves the E5.4d tie in favor of `bge-base@1200/240` by 2 pts
on the primary metric and surfaces a **meaningful anchor-drift
finding**: the live `markdown-memory` folder grew ~7% between
E5.4d and E5.9b, producing −2 to −4 pt score drift on the same
geometry across a 2-day window. The E5.7 global-default flip
(bge-base → e5-base, commit `00e3fd3`) is NOT affected — the flip
evidence (E5.7 40/60 vs E5.4d 36/60) was single-snapshot
comparison between two distinct models, not a geometry shift. But
the drift finding matters for the E5.9 cross-corpus plan (see
"Next" below) and suggests freezing a corpus snapshot for future
refinement runs.

Manager auto-queues next: E5.9c (nomic peak refinement, ~5 h
CPU-only). When E5.9c lands, auto-queues the E6.1 → E6.2 → E6.3 →
E6.4 indexing-speed chain per manager directive 2026-04-23. Full
autonomy through the whole chain; outcomes land in plan.md by
morning.

E5.9a shipped 2026-04-23 and confirmed `e5-base@1200/0` at 40/60,
corroborating the E5.7 result.

---

## Next — E5.9: Fine-tune top candidates + second-corpus validation

Running order now that all queued novel-model sweeps have landed
(E5.6 gte-base, E5.7 e5-base, E5.8 mxbai-large) and E5.9a (e5-base
peak refinement) + E5.9b (bge-base peak refinement) have shipped:

- **E5.9a — e5-base peak refinement** ✅ done (2026-04-23). Peak
  confirmed at `e5-base@1200/0` → 40/60. See Done section above and
  `data/retrieval-e5-base-refine.md`.
- **E5.9b — bge-base peak refinement** ✅ done (2026-04-24). E5.4d
  two-way tie broken in favor of `1200/240` (large-chunk regime
  wins by 2 pts on total_60). Surfaced a corpus-drift finding: the
  live `markdown-memory` folder grew ~7% between E5.4d and E5.9b,
  causing both anchor configs to drift −2 to −4 pts on total_60
  without any indexer/scorer change. See Done section above and
  `data/retrieval-bge-base-refine.md`.
- **E5.9c — nomic peak refinement** — open. 1200/240 → 35/60 from
  the original migration sweep; refine around it (and check whether
  e5-base's 1200/0-rejects-overlap pattern holds for nomic too).
  **Note**: the E5.9b corpus-drift finding means a nomic refinement
  run now will not reproduce the pre-drift 35/60 bit-exactly either.
  Plan for that: either accept the drifted baseline and compare
  within-refinement ranking, or freeze a corpus snapshot first.

Then, after E5.9c lands:

1. Pick the top 2-3 candidates from the refined results and run a
   **fine-grained mini-sweep** around each one's peak to resolve
   the parameter-space shape that the current 12-point grid
   smooths over. (E5.9a/b done this for e5-base and bge-base; c
   is its analog for nomic.)
2. Simultaneously (or immediately after), run those same candidates
   against a **second corpus** — this folds together the previously-
   deferred E5.4e (corpus-generalization) work with the new
   param-space refinement. One batch of sweeps answers both
   questions.
3. **Corpus-snapshotting question** (surfaced by E5.9b): should
   rubric sweeps freeze a corpus snapshot, or keep tracking the
   live folder? Frozen snapshots give bit-exact reproducibility
   (E5.9a-style) but risk the rubric decaying as the live corpus
   evolves. Live folders stay representative but give up
   reproducibility. Decide before the second-corpus work so
   that comparison is clean.

### Why do these together

- Fine-tuning on one corpus risks over-fitting — a peak refined on
  markdown-memory may not replicate elsewhere. Running the refined
  grid against a second corpus immediately keeps us honest.
- The current 12-point grid has wide overlap_pct steps (0 / 10 / 20)
  and wide chunk_size steps (400 / 800 / 1200 / 1600). E5.7 surfaced
  the limits of that: `e5-base` showed **two distinct peaks**
  (1200/0 → 40 and 400/40 → 40 tied) on opposite ends of the grid,
  with no neighboring points between 400 and 800 to tell which
  regime is really better. Refining those neighborhoods is cheap
  signal, but only on candidates worth refining — i.e. after we've
  triaged down from 9 built-ins.

### Candidate selection (applied after E5.8 completion)

Scoring candidates by their measured peak Total /60 on markdown-memory:

| alias         | peak   | Total /60 | advance? |
|---------------|--------|----------:|----------|
| e5-base       | 1200/0 |    **40** | yes (current top) |
| bge-base      |1200/240|        36 | yes (current global default) |
| nomic         |1200/240|        35 | yes (within 5 pts of top) |
| bge-large     | 1200/0 |        34 | maybe (within 6 pts — 1024 dim tier) |
| mxbai-large   |  800/80|        31 | no (9 pts off top, 3 off current default) |
| bge-small     | 1200/0 |        30 | no (10 pts off top) |
| gte-base      | 1600/0 |         8 | no (content-discrimination failure) |
| nl / nl-ctx   |   —    |       6/3 | no (ceiling) |

**Initial advance set: `e5-base`, `bge-base`, `nomic`.** Three
768-dim candidates on the same corpus makes the comparison clean;
storage geometry is shared. `bge-large` is a fence-sitter — the
only 1024-dim model still in contention, but 6 pts below top and
~3× slower. Advance it only if there's spare budget after the
three-way 768-dim mini-sweep completes.

### Fine-tune mini-sweep shape (per candidate)

Two patterns to mix-and-match, picked based on where the coarse
peak landed:

- **"Peak refinement"** — 6-9 points around the measured peak,
  stepping `±100` in chunk_size and `±5%` in overlap_pct. E.g. for
  e5-base@1200/0, try sizes ∈ {1100, 1200, 1300} × overlap ∈ {0,
  60, 120}. Answers "is the peak really at 1200/0 or are we on a
  plateau hiding a better neighbor?"
- **"Regime probe"** — 6-9 points around a surprising second peak,
  to establish whether it's real or a single-point artifact. E.g.
  for e5-base's 400/40 tied peak, probe sizes ∈ {400, 500, 600} ×
  overlap ∈ {0, 40 (10%), 80 (20%)}. Answers "is the small-chunk
  regime competitive across more than one grid point?"

Each candidate gets one of each pattern as warranted by its
measured shape. ~15-20 points per candidate total; ~8-10 h wall
per candidate at 768-dim, more at 1024-dim.

### Second-corpus threading

Per candidate advancing from the triage step, run the refined
mini-grid **against both markdown-memory and a second corpus in
the same batch**. Two interpretations to draw:

- **Same peak, similar ranking across corpora** → confident in the
  default. Update `IndexingProfileFactory.builtIns` with the
  refined peak.
- **Different peak on the second corpus** → flag the default as
  markdown-memory-specific and push per-corpus default selection
  to E6. The model still ships; just with a "YMMV on your corpus"
  note in `data/retrieval-<alias>.md`.
- **Different ranking between candidates across corpora** (e.g.
  e5-base wins on markdown-memory but bge-base wins on vec-source)
  → that's the "no single global default fits all" answer and
  reshapes the E6 backlog toward multi-default or corpus-aware
  selection.

The second corpus is the previously-deferred `vec-source` (vec's
own Swift source tree) per E5.4e. The rubric for it still needs
domain-designed queries — the concrete recipe below still stands
as the checklist for when resuming.

---

## Next — E5.4e: Corpus-generalization of per-model peaks

**Deferred pending a domain-expert-designed rubric.** The three
BGE sweeps (E5.4b/c/d) established peaks on markdown-memory:

- `bge-small@1200/0` → 30/60
- `bge-base@1200/240` → 36/60 (co-tied with `bge-base@800/80`)
- `bge-large@1200/0` → 34/60

Whether these rankings hold on a second corpus is still an open
question. The obvious second corpus is vec's own Swift source
tree, but building a useful rubric against a code corpus needs
domain knowledge: the queries have to probe semantic understanding
*beyond* the filename (otherwise BGE will trivially ace them and
the rubric won't distinguish the configs).

### Concrete E5.4e recipe (when resuming)

1. **Design ~10 queries with 2 target files each.** Queries should
   NOT be answerable by filename alone. E.g. "how does the
   indexing pipeline handle slow files" (targets:
   `IndexingPipeline.swift` + `FileAccumulator` related code) is a
   useful query; "how does the indexing pipeline work" (targets:
   `IndexingPipeline.swift` alone) is not — the filename gives it
   away.
2. **Write the rubric manifest** at `scripts/rubric-vec-source.json`,
   matching the shape of `scripts/rubric-queries.json`.
3. **Init `vec-source` DB** (one-time `vec init` in the repo root).
4. **Run winners against the new corpus** via:
   ```
   vec sweep --db vec-source --embedder bge-small --sizes 1200 --overlap-pcts 0 --out benchmarks/corpus-cross/bge-small --rubric scripts/rubric-vec-source.json --force
   vec sweep --db vec-source --embedder bge-base  --sizes 1200,800 --overlap-pcts 20,10 --out benchmarks/corpus-cross/bge-base --rubric scripts/rubric-vec-source.json --force
   vec sweep --db vec-source --embedder bge-large --sizes 1200 --overlap-pcts 0 --out benchmarks/corpus-cross/bge-large --rubric scripts/rubric-vec-source.json --force
   ```
   (bge-base runs the two co-peak geometries — 1200/240 and 800/80
   — to break the tie on this corpus.)
5. **Outcomes to document:**
   - **Same ranking**: publish with confidence that the defaults
     generalize. Update the per-model data files with the
     second-corpus scores.
   - **Different ranking**: flag the current defaults as
     markdown-memory-specific and defer per-corpus default
     selection to E6.

### What's deliberately out of scope for E5.4

- Other models beyond the three registered BGE variants. E5.4b/c/d
  already exercised the dim×depth curve (384 / 768 / 1024).
- N × batch_size concurrency sweeps — E6 optimization work.
- Retrieval-strategy changes (hybrid BM25, query expansion,
  re-ranker) — those are quality levers orthogonal to chunk
  geometry, pushed to post-E6.
- A vec-source rubric written without domain input. The meta-risk
  is writing "easy" queries that every config aces, yielding no
  signal to distinguish the configs. Pausing here until a
  human-designed rubric is available is the honest call.

---

## Backlog — E6 and beyond

Deferred until E5 resolves. From the E4 next-steps audit.

### Candidate models (original list — all three now tested)

| Candidate              | Size    | Dim  | MTEB  | Status |
|------------------------|---------|------|-------|--------|
| `gte-base-en-v1.5`     | ~110 MB | 768  | 51.14 | E5.6 shipped: 8/60, anisotropy failure, below threshold |
| `e5-base-v2`           | ~110 MB | 768  | 50.3  | E5.7 shipped: 40/60, **new global default** |
| `mxbai-embed-large-v1` | ~670 MB | 1024 | 54.7  | E5.8 shipped: 31/60, below bge-base |

Further unexplored candidates worth considering when E6 wraps:
`intfloat/e5-large-v2` (1024-dim, same family as current default —
most likely to beat 40/60 without new engineering),
`snowflake-arctic-embed-l-v2.0` (2024 SOTA, MTEB ~56), and
instruction-tuned `gte-Qwen2-1.5B/7B` (MTEB ~60+ but needs
substantial pool resize — trades indexing wallclock for quality).

### E6 — e5-base indexing-speed tuning (queued, triggers after E5.9 completes)

Concrete action plan for the first overnight after E5.9 finishes.
All E6.1-E6.4 items target `e5-base` (our current default) and
measure indexing wallclock; retrieval quality must stay
bit-identical (the E4 regression bar). Execution order is fixed —
each step's outcome shapes the next:

**E6.1 — CLI flags for tuning knobs.** Add `--batch-size`,
`--concurrency`, and `--compute-policy` (`auto` | `cpu` | `ane` |
`gpu`) to `vec update-index` AND `vec sweep`. Wire through to
`IndexingPipeline` (which currently takes hardcoded N) and
`EmbedderPool` / batch-former (which currently takes hardcoded b).
Default values MUST reproduce current behavior exactly — no
existing-sweep drift without the flags. Build + 1-point smoke
test confirms retrieval bit-identical to the last
`e5-base@1200/0` archive (the regression bar). ~2 h code. Pure
code work, zero GPU contention.

**E6.2 — ANE feasibility probe for e5-base.** Single e5-base
index run on markdown-memory at the default geometry with
`--compute-policy ane`. Measures: does the graph compile for ANE
(nomic hit `"Incompatible element type for ANE"` on macOS 26.3.1+
and had to pin CPU-only — same class of failure is possible for
e5-base's custom mean-pool path via `bundle.model(...)`)? What's
the wallclock? Does retrieval reproduce bit-identical?
The outcome shapes E6.3's grid. ~20-30 min including model
reload.

**E6.3 — indexing-speed grid for e5-base.** Grid shape depends
on E6.2:
- **If ANE compiles**: 24-point grid `batch_size ∈ {16, 24, 32}`
  × `concurrency ∈ {6, 8, 10, 12}` × `policy ∈ {auto, ane}`,
  ~1025 s × 24 ≈ 7 h.
- **If ANE fails**: CPU-only 12-point grid `batch_size ∈ {16,
  24, 32}` × `concurrency ∈ {6, 8, 10, 12}`, ~3.5 h.
Each point: reindex markdown-memory at the config, measure wall
+ peak RSS + pool utilization, verify retrieval bit-identical to
reference. Output: `data/indexing-speed-e5-base.md` table sorted
by speed.

**E6.4 — Length-bucket width.** Current bucket key is
`chunk.text.count / 500`. After E6.3 identifies the fastest
`(N, b, policy)` config, 2 additional points at that config:
`/300` (finer, less padding waste) and `/700` (coarser, larger
effective batches). ~35 min.

**Defaults update rule.** After E6.4, if the best config beats
the current `N=10 b=16 /500 auto` baseline by ≥5% wallclock with
bit-identical retrieval, update `IndexingPipeline`'s hardcoded
defaults to the new values AND update
[`data/wallclock-e4-per-model.md`](./data/wallclock-e4-per-model.md)
+ the [`indexing-profile.md`](./indexing-profile.md) table rows
for e5-base specifically. Marginal wins (<5%) stay documented
but don't flip defaults — too much risk of corpus-specific
tuning that doesn't generalize.

**Autonomy on overnight execution:** run autonomously through
E6.1 → E6.2 → E6.3 → E6.4 without pausing for review, except:
stop and ask manager via `ib ask` if E6.1 hits a structural
problem (e.g. `swift-embeddings` doesn't expose compute-policy
cleanly) or if any step produces a retrieval-quality drift. Per
manager directive 2026-04-23.

### E6 — Parameter grid fill (original, superseded by E6.1-E6.4 above)

### E6 — Parameter grid fill

Pure tuning; no code changes.

**Batch size toward the BNNS cap.** Phase C swept b=4/8/16 and saw
monotonic improvement. The BNNS fused-attention cap is 32. Untested:

- **b=24** — half-step past 16, cheap to run.
- **b=32** — the ceiling before BNNS falls back; wall-clock win is
  plausibly another 5-10 %, RSS impact unknown.

Guardrail: if pool utilization drops below 95 % as b grows, the
batch-former is starving on heterogeneous length buckets — revisit
bucket width below before pushing further. (95 % is the empirical
"fully-fed" mark from Phase C, where E4-3 and E4-4 both ran at
99 %; a step down to ~80-90 % indicates the batch former is being
held off chunks.)

**Length-bucket width tuning.** Current bucket key is
`chunk.text.count / 500`. Short corpora (code, chat) cluster in
buckets 0-1; long-form (transcripts, prose) cluster 2-5. Try
`/ 300` (finer, less padding waste, more small batches) and
`/ 700` (coarser, larger effective batches at the cost of more
pad tokens). Benchmark against at least two corpora — optimum is
corpus-dependent.

**Concurrency × batch grid.** Phase C tested 4 of 16 interesting
points:

| N \ b | 4 | 8 | 16 | 24 | 32 |
|-------|---|---|----|----|----|
| 2     |   |   | ✓  |    |    |
| 6     |   |   |    |    |    |
| 8     |   |   |    |    |    |
| 10    | ✓ | ✓ | ✓  |    |    |

Known gaps: N=6 / N=8 × b=16 (machine has 10 perf cores + efficiency
cores; N=10 may be past the efficient frontier), N=10 × b=24/32,
N=12/14 oversubscription probe.

**Bucket-width × batch-size mini-grid.** Bucket width and batch
size are coupled — wider buckets only pay off if batches fill:

| bucket \ batch | 16 | 24 | 32 |
|----------------|----|----|----|
| / 300          |    |    |    |
| / 500 (current)| ✓  |    |    |
| / 700          |    |    |    |

**Across corpora.** Everything in E4 ran against markdown-memory.
Optimal (N, b, bucket) is likely corpus-dependent. Before declaring
a new global default, re-run the winner against a code corpus
(shorter chunks, tighter length distribution) and a long-form
corpus (transcripts, books — wider distribution).

**Model × concurrency.** The N=10 default was tuned at bge-base
(768-d, 110 MB). Smaller models (bge-small at 33 MB) might tolerate
higher N before RSS pressure hits; larger models (bge-large at
670 MB) almost certainly want lower N. Each new model from E5 should
re-sweep N at b=16.

### E7 — DB-write parallelism

Only worthwhile once E5/E6 have pulled embed-time down far enough
that the writer is the next bottleneck. The accumulator is
currently the only serialization point after the embedder pool; a
cursory profile showed it's not the bottleneck today.

- WAL-checkpoint batching — commit every N chunks instead of per
  file.
- Separate writer task with its own AsyncStream — keeps the
  embedder pool fully utilized even during checkpoint flushes.

### Extractor parallelism

Extractor runs serially in front of the embedder pool. For
text-only corpora this is fine, but PDF / HTML extraction is
single-threaded and becomes the bottleneck the moment we add a
non-text format. Worth prototyping a small extractor pool (N=2-4)
behind the same backpressure semaphore.

nl-contextual already hit this ceiling: once the embedder got fast
enough, pool utilisation dropped from 98 % → 83 %, meaning extract
became the bottleneck. Making extract faster translates directly
into throughput gains for any fast embedder.

### MLTensor compute-policy experiments

CoreML's `MLComputePolicy` controls CPU / GPU / ANE placement.
Phase C ran with default (compiler-chosen). Worth probing:

- Force `.cpuAndNeuralEngine` — ANE may have headroom at
  batchSize ≤ 16.
- Force `.cpuAndGPU` — useful diagnostic even if not a win; tells
  us where the compiler is currently landing.

### MLX backend (passive watch)

E3 ruled out MLX because `swift-embeddings` didn't expose an MLX
path. If that changes upstream, MLX could unlock the GPU's
unified-memory bandwidth advantage. Track `swift-embeddings` issues
and releases — upstream-gated, not blocked on us.

### Other follow-up levers (carried over from original status)

From the pre-E4 status snapshot, still relevant:

1. **Hybrid retrieval (BM25 + vector)** — a lexical channel rewards
   exact phrase matches ("bean counter", "1.5 million") that pure
   vector smooths out. Expected 5-10 pts on this rubric. Biggest
   quality lever outside model swaps.
2. **Query expansion** — generate 2-3 paraphrases per query (LLM or
   local), aggregate results. Lift on topical queries.
3. **Multi-granularity indexing** — index each file at both
   1200/240 and a smaller size (e.g. 400/80), let the ranker see
   both.
4. **Per-file-type defaults** — `summary.md` files are short
   enough that `.whole` is always the interesting embedding;
   `transcript.txt` benefits from chunking. Branch at index time.
