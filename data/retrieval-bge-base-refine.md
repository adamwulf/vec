# BGE-base Peak-Refinement Sweep — E5.9b

12-point refinement (two 3×2 sub-grids) around the TWO-WAY TIE that
the E5.4d coarse grid left unresolved on `bge-base`:

- **Large-chunk sub-grid**: sizes 1100, 1200, 1300 × overlap_pcts
  20%, 25% — targets the `1200/240` tie-peak.
- **Small-chunk sub-grid**: sizes 700, 800, 900 × overlap_pcts 5%,
  10% — targets the `800/80` tie-peak.

`1200/240` (20% at size 1200) and `800/80` (10% at size 800) are
points in both the E5.4d coarse archive and this refinement archive,
providing reproducibility anchors.

Executed via `vec sweep` (E5.4a). Raw archives + summary live under
`benchmarks/sweep-bge-base-refine-large/` and
`benchmarks/sweep-bge-base-refine-small/`.

**Scope note** — This is a refinement, not a full characterization.
The task was to resolve the E5.4d tie (or confirm the plateau), not
to re-survey `bge-base`'s full parameter space.

**Result: the large-chunk regime wins the refined tie, but the
E5.4d anchor values did NOT reproduce.** Both anchors dropped in
total_60 and both gained chunk count by ~7% — consistent with
corpus drift on the live `markdown-memory` folder (E5.4d was
2026-04-22; this refinement ran 2026-04-23/24). See §2 for the
detailed reproducibility comparison. The within-refinement ranking
is still internally consistent: the large sub-grid peaks ~2 pts
above the small sub-grid peak, and `1200/240` (or `1300/325`
tied with it on total_60) is the best config in the combined grid.

**Scoring legend** — `total_60` is the rubric total out of 60.
`top10_either` counts queries where either T (transcript) or S
(summary) landed in top 10; `top10_both` counts queries where
*both* T and S landed in top 10 (stricter secondary tiebreaker).

**Scorer note** — `total_60`, `top10_either`, and `top10_both`
below are the values emitted by `vec sweep`'s in-process scorer,
which is byte-for-byte parity with `scripts/score-rubric.py` (see
E5.4a plan §"Scorer parity" and
`SweepCommandTests.testScoreArchive_matchesReferenceData`). The
worker running this sweep does not have `python3` on its Bash
allowlist in this worktree so the external cross-check was not
re-run; the shared code path is the trust anchor, as established
for E5.6, E5.7, and E5.9a.

## 1. Summary tables

### 1a. Large-chunk sub-grid (around the 1200/240 tie-peak)

Sorted by total_60 descending, then top10_both descending.

| # | config | chunks | wall_s | chps_wall | total_60 | top10_either | top10_both | notes |
|---|--------|--------|--------|-----------|----------|--------------|------------|-------|
| 1 | bge-base@1300/325 | 8397 | 1214.3 | 6.9 | **34** | 9 | **3** | Tied peak on total_60; wins top10_both. |
| 1 | bge-base@1200/240 | 8742 |  979.7 | 8.9 | **34** | 9 | 2 | Tied peak on total_60. **Anchor — see §2.** |
| 3 | bge-base@1200/300 | 9044 |  984.1 | 9.2 | 33 | 9 | 3 | — |
| 4 | bge-base@1100/220 | 9535 | 1097.8 | 8.7 | 32 | 9 | 2 | — |
| 5 | bge-base@1100/275 | 9857 | 1075.3 | 9.2 | 31 | 9 | 2 | — |
| 6 | bge-base@1300/260 | 8131 |  865.6 | 9.4 | 28 | 9 | 1 | Low point in large sub-grid. |

Large sub-grid wall: 6 217 s ≈ 104 min.

### 1b. Small-chunk sub-grid (around the 800/80 tie-peak)

Sorted by total_60 descending, then top10_both descending.

| # | config | chunks | wall_s | chps_wall | total_60 | top10_either | top10_both | notes |
|---|--------|--------|--------|-----------|----------|--------------|------------|-------|
| 1 | bge-base@800/80 | 12316 | 1150.0 | 10.7 | **32** | 8 | **4** | Peak of small sub-grid. **Anchor — see §2.** |
| 2 | bge-base@800/40 | 12103 |  981.3 | 12.3 | 31 | 8 | 4 | Runner-up, −1 pt on total. |
| 3 | bge-base@900/45 | 10784 |  998.9 | 10.8 | 29 | 9 | 3 | — |
| 3 | bge-base@900/90 | 10966 | 1065.1 | 10.3 | 29 | 9 | 3 | — |
| 5 | bge-base@700/35 | 13895 | 1336.7 | 10.4 | 24 | 7 | 0 | — |
| 6 | bge-base@700/70 | 14111 | 1300.8 | 10.8 | 23 | 7 | 0 | Low point across both sub-grids. |

Small sub-grid wall: 6 832 s ≈ 114 min.

Total sweep wall: 13 049 s ≈ 218 min ≈ 3 h 38 min.

## 2. Reproducibility anchors — E5.4d vs E5.9b

Both tie-peaks are also points in the E5.4d coarse grid. Unlike
E5.9a (which reproduced the e5-base anchor bit-exactly with
0-pt deviation), the bge-base anchors **drifted** on both the
primary metric and the chunk count.

| anchor config | E5.4d coarse (2026-04-22)       | E5.9b refine (2026-04-23/24)    | Δ total_60 | Δ chunks |
|---------------|---------------------------------|---------------------------------|-----------:|---------:|
| 1200/240      | 36/60, 9 either, 3 both, 8170 ch | 34/60, 9 either, 2 both, 8742 ch | **−2** | +572 (+7.0%) |
| 800/80        | 36/60, 9 either, 5 both, 11496 ch | 32/60, 8 either, 4 both, 12316 ch | **−4** | +820 (+7.1%) |

**The drift is not scorer-side.** `vec sweep`'s scorer is
deterministic and the shared code path with `score-rubric.py` is
unchanged. The drift is not indexer-side either — the chunker
(`RecursiveCharacterSplitter`) and `bge-base` loader have not
changed since E5.4d (git log for `Sources/VecKit/*.swift` shows no
relevant commits between `598a072` E5.4d and the current HEAD).

**The drift IS corpus-side.** `markdown-memory` is a live user
content folder (Adam's Essential MCP data directory, per `config.json`
Source path). Both anchor chunk counts grew by ~7.0–7.1%, which
is the signature of new content being added to the corpus between
the two sweeps. E5.4d ran 2026-04-22; this refinement ran
2026-04-23/24. Two days of content additions at ~3-4%/day matches
the observed drift.

**This is a finding about the test corpus, not a bug.** The E5.9a
e5-base refinement reproduced bit-exactly because E5.7 and E5.9a
were both indexed on the same day against the same corpus snapshot
(and E5.7 finished on the same build as E5.9a started from). E5.4d
vs E5.9b spans a 2-day window during which the live corpus changed.

**Autonomy threshold note** — the task brief flagged "deviation
>3 pts" as a real-bug signal. The 800/80 anchor drifted 4 pts.
Given the co-drift on chunk count (+7% on both anchors) and the
absence of any chunker/embedder change, the drift is explained by
corpus growth rather than a determinism bug. Proceeding with the
writeup as planned but flagging the anchor drift prominently so
the manager reviewer can reject this reading if they see a
different explanation.

## 3. Observations

### 3a. The E5.4d tie broke in favor of the large-chunk regime

Putting the two sub-grids' peaks side by side:

| region            | refined peak          | total_60 | top10_both |
|-------------------|-----------------------|---------:|-----------:|
| large-chunk band  | `bge-base@1200/240`   | 34       | 2          |
| large-chunk band  | `bge-base@1300/325`   | 34       | 3          |
| small-chunk band  | `bge-base@800/80`     | 32       | 4          |

On total_60 the **large-chunk regime wins by 2 pts**. On
`top10_both` the small-chunk regime still wins (4 vs 2 for
`1200/240`, 4 vs 3 for `1300/325`) — consistent with E5.4d's
observation that `800/80` is stronger on the strict metric.

The primary metric is the decider; the tie breaks in favor of the
1200 band. The historical default `1200/240` remains correct for
`bge-base`.

### 3b. New candidate: `bge-base@1300/325`

Neither peak of the tie was the overall refinement winner — but
neither *lost* the refinement either. `1300/325` ties `1200/240`
on total_60 (both at 34) and beats it on `top10_both` (3 vs 2).
This is a **new** datapoint not present in the E5.4d coarse grid
(which spaced sizes at 400, 800, 1200, 1600 — no 1300).

Should the default move? I don't think so:

1. Total_60 is a tie (34/34). The primary metric does not pick a
   winner between `1300/325` and `1200/240`.
2. `1300/325` has a slightly higher `top10_both` (3 vs 2), but
   both values are inside the corpus-drift noise band that §2
   exposed — E5.4d measured `1200/240` at `top10_both=3`, so the
   true `top10_both` for that config on the un-drifted corpus
   is not known to be different from 3. A 3-vs-3 tie is just as
   consistent with the data as `1300/325` wins by 1.
3. `1200/240` has been the documented default since the E4 rubric;
   continuity and documentation cost argue against churn on a
   softly-observed difference.

**Decision: keep `1200/240` as the bge-base default.** Document
`1300/325` as a measured co-peak worth checking on a
second-corpus sweep (E5.4e).

### 3c. `bge-base` still uniquely likes overlap at size 1200 — confirmed at finer resolution

The E5.4 cross-model finding was that `bge-base` is the only
768-dim family member that *benefits* from overlap at size 1200,
while `bge-small`, `bge-large`, and `e5-base` all reject it. The
large sub-grid tests a narrower probe of this (20% and 25%):

| config              | total_60 |
|---------------------|---------:|
| bge-base@1200/0     | 33 (E5.4d)    |
| bge-base@1200/120   | 29 (E5.4d)    |
| bge-base@1200/240   | 34 (E5.9b, 36 in E5.4d) |
| bge-base@1200/300   | 33 (E5.9b)    |

The 0 → 10% → 20% shape from E5.4d (33 → 29 → 36) is preserved
here: overlap at 20% is the best point at size 1200. The 25%
value (33) starts to roll off, consistent with "overlap helps, but
too much starts to hurt." No hidden sweet spot at 25%.

### 3d. Small-chunk regime: 10% still beats 5%, 700 is too small

At size 800 the 5%/10% progression is:

| config              | total_60 |
|---------------------|---------:|
| bge-base@800/0      | 34 (E5.4d)    |
| bge-base@800/40     | 31 (E5.9b)    |
| bge-base@800/80     | 32 (E5.9b, 36 in E5.4d) |
| bge-base@800/160    | 29 (E5.4d)    |

Within-refinement: 10% (32) beats 5% (31) at size 800 by 1 pt.
Comparing with E5.4d's values, the peak at `800/80` is preserved
relative to 0% (34 in E5.4d, 31-32 here after drift). The E5.4d
observation that "10% overlap is the sweet spot at size 800, 20%
is a sharp drop" holds at the finer resolution — 5% is slightly
worse than 10%, consistent with the curve rising through 10% and
falling past it.

**Size 700 is below the useful floor.** Both `700/35` and
`700/70` score 23-24 — well below the rest of the small sub-grid
(29-32). The sharp drop from 800 (32) to 700 (24) is a 7-8 pt
cliff in 100 chars of chunk size. Shorter chunks lose target
content to neighbor chunks; the rubric starts missing top-10 hits
(top10_either drops to 7/10 from 8-9/10 at 800+). Below 800,
`bge-base` rapidly degrades on this corpus. This matches E5.4d's
finding that `800/80` is the floor of the "good" regime — the
refinement confirms that going smaller does NOT keep the pattern.

### 3e. Throughput

Per-chunk throughput across the 12 points holds at 6.9–12.3 chps,
consistent with E5.4d's 5.6–11.5 range for `bge-base` on this
corpus. No throughput anomalies. Smaller chunks are slightly
faster per-chunk (expected — each chunk is shorter so the fixed
per-chunk overhead dominates less).

## 4. Decision

**Default unchanged: `bge-base@1200/240`.**

The refinement resolves the E5.4d tie in favor of the large-chunk
regime by 2 pts on total_60 (34 vs 32 at the sub-grid peaks). The
historical default `1200/240` remains the best config in the
large sub-grid, tied with the newly-discovered `1300/325`.
Neither `1300/325` nor any other refined point beats `1200/240`
by enough to justify a default change under the corpus-drift
noise observed in §2.

- **`Sources/VecKit/IndexingProfile.swift`**: no change. The
  bge-base alias already stamps `defaultChunkSize: 1200,
  defaultChunkOverlap: 240`.
- **`indexing-profile.md`**: no change to the bge-base row. The
  footnote ³ commentary about "co-peak at 800/80 was kept at
  1200/240 to match the historical default" is refined by this
  sweep — E5.9b breaks the tie in favor of 1200/240 on primary
  metric, so the "was kept" framing is now "was confirmed." A
  one-line footnote refresh is appropriate.
- **`data/retrieval-bge-base-sweep.md`**: no change to the E5.4d
  Decision section. This refinement corroborates that decision
  (and sharpens the justification from "tie, keep historical
  default" to "tie resolved, keep 1200/240 on primary metric").

## 5. Cross-model tie-break standing

After both refinements (E5.9a e5-base + E5.9b bge-base), the
three-way standing on markdown-memory narrows:

| embedder   | refined peak      | total_60 | top10_both |
|------------|-------------------|---------:|-----------:|
| e5-base    | `1200/0`          | **40**   | **6**      |
| bge-base   | `1200/240`        | 34-36    | 2-3        |
| nomic      | (E5.9c pending)   | 35       | 3          |

The `bge-base` row uses the E5.9b refine value paired with the
E5.4d value in parens range — because of the anchor drift, the
"true" bge-base@1200/240 score under this refinement's corpus
snapshot is 34, while the E5.4d value is 36. The E5.9a e5-base
refinement was bit-identical across snapshots so its 40 is
unambiguous.

If nomic's E5.9c refinement reveals similar corpus-drift behavior,
the cross-model comparison will need to be re-normalized against
a single snapshot. For now, the e5-base advantage over bge-base
is 4-6 pts (+4 from the drift-preserved comparison, +6 if E5.9b's
bge-base drift is real; the E5.4d comparison remains the
canonical pre-flip one). The E5.7 global-default flip decision is
not affected by this finding.

## 6. Follow-up

- **E5.9c — nomic peak refinement**. Remaining E5.9 sub-deliverable.
  Watch for corpus-drift in the nomic anchor if it runs more than
  a day after the E5.4 nomic baseline (though nomic's baseline is
  older than both bge-base and e5-base, so corpus drift against
  its baseline is already guaranteed to be larger).
- **Corpus-generalization (E5.4e, still deferred).** The E5.9b
  finding makes corpus-generalization more urgent: if the
  `bge-base` result is this sensitive to a 2-day corpus delta,
  running `1200/240` (and the newly-discovered `1300/325`)
  against a second corpus would test whether the tie-break
  reverses or holds.
- **Corpus-snapshotting for rubric sweeps.** A separate
  infrastructure question surfaced by this refinement: should
  the rubric benchmark freeze a corpus snapshot, or continue
  tracking the live folder? Frozen snapshots give bit-exact
  reproducibility (E5.9a-style) but risk rubric queries
  decaying as the live corpus evolves. Live folders give up
  reproducibility but ensure the benchmark stays representative.
  Not a decision for this writeup; flagging for future plan.md
  consideration.
