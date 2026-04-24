# vec — Plan

The rolling plan for the `vec` project. Covers what has shipped,
what's in progress, and what should happen next.

- **Reference** (stable): [`README.md`](./README.md) • [`indexing-profile.md`](./indexing-profile.md) • [`retrieval-rubric.md`](./retrieval-rubric.md)
- **Raw experiment data**: [`data/`](./data/)
- **Cited external research**: [`research/`](./research/)
- **Per-experiment plans + reports**: [`experiments/`](./experiments/)
- **Superseded snapshots**: [`archived/`](./archived/)

Last updated: 2026-04-23.

---

## Current state (as of 2026-04-23, post-E5.8)

**Default embedder**: `bge-base@1200/240` (BGE-base-en-v1.5, 768-dim).

**Rubric score on markdown-memory**: 36/60, 9/10 top-10 hits
(scored with `.score-rubric.py` against the 10-query trademark
rubric). See [`retrieval-rubric.md`](./retrieval-rubric.md) for
the rubric definition.

**Wallclock on markdown-memory**: ~1028 s at N=10 workers,
batchSize=16 on a 10-core Apple Silicon machine. Per-model
comparison in [`data/wallclock-e4-per-model.md`](./data/wallclock-e4-per-model.md).

**Built-in embedders**: `bge-base` (default), `bge-small`, `bge-large`,
`gte-base`, `e5-base`, `mxbai-large`, `nomic`, `nl-contextual`, `nl`.
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
same rubric and near-identical wallclock (~1025 s vs ~1003 s). This
is a candidate global-default change pending manager review and a
second-corpus confirmation; the E5.7 commit updates the e5-base
alias default to 1200/0 but leaves `IndexingProfileFactory.defaultAlias`
as `bge-base`. See `data/retrieval-e5-base-sweep.md` §4.

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

---

## In progress

None. E5.8 is the latest shipped experiment. The open question
escalated to the manager is still whether to flip the global default
from `bge-base` to `e5-base` based on E5.7's evidence; E5.8 did not
produce a new default candidate (mxbai-large peaked at 31/60, below
all four sweep-tuned 768/1024-dim defaults on this corpus).

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

### Candidate models (after bge-small / bge-large)

| Candidate              | Size    | Dim  | MTEB  | Why it's interesting |
|------------------------|---------|------|-------|----------------------|
| `gte-base-en-v1.5`     | ~110 MB | 768  | 51.14 | Direct BGE-base peer; same dim lets us swap-test without changing index storage geometry |
| `e5-base-v2`           | ~110 MB | 768  | 50.3  | Query-prefix convention (`query:` / `passage:`) is different — validates prefix handling |
| `mxbai-embed-large-v1` | ~670 MB | 1024 | 54.7  | Current open-weights SOTA in the ~1 GB class; competitor to bge-large |

Per candidate, measure: rubric score vs bge-base 36/60,
wallclock at N=10 b=16, peak RSS + CPU%, chunks/sec at steady state.

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
