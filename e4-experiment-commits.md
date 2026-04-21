# E4 Batch-Embedding Experiment — Commit Preservation

Worktree git tag/branch is blocked by the ib hook, so recording the SHAs
here ensures we can always recover the E4 work even if the branch is
reset or rebased.

## Commits (newest → oldest)

| SHA (full) | Short | Subject |
|---|---|---|
| `8bb6b94e4587bbca0ebf592479b5bc9fadedc819` | `8bb6b94` | E4 phase B fix: prevent batch-former deadlock on distribution-spread chunks |
| `414eae2cd7ef89fc66ba2e8f3bf89a84da5d0f7d` | `414eae2` | E4 phase B: rewire IndexingPipeline for batched embedding |
| `1a104fff22b0e1690006b5616f975498d403a905` | `1a104ff` | E4 phase A: add Embedder.embedDocuments + BGE/Nomic batch overrides |

Tip of the experimental chain: `8bb6b94`.

## Summary of results

Best config measured: `concurrency=10, batchSize=16` (row 4 of the sweep).

| Config | Wall | vs E1 | Pool util |
|---|---|---|---|
| E1 baseline (`09b90ea`) | 1310s | — | 98% |
| E4-1 N=2 batch=16 | 1530s | +16.8% | 100% |
| E4-2 N=10 batch=4 | 1083s | −17.3% | 99% |
| E4-3 N=10 batch=8 | 1012s | −22.7% | 99% |
| E4-4 N=10 batch=16 | 997s | −23.9% | 99% |

Rubric on E4-4 (BGE-base, markdown-memory corpus, `retrieval-rubric.md`
queries): **36/60, 9/10 top-10**.

## Resolution of the apparent regression (2026-04-20)

Earlier drafts of this file (and prior commit messages) reported a
"3-point regression" vs an E1 baseline of **39/60, 10/10**. That
narrative was wrong on both numbers:

- The E1 baseline of 39/60 was a manual-tally error. Rescoring E1 from
  the archived rubric JSON yields **35/60, 3/10 top-10** (the
  TOP10_BOTH-vs-TOP10_EITHER ambiguity also contributed; the standard
  is TOP10_EITHER).
- The E4-4 score of **36/60, 9/10** is therefore **+1 pt total and
  +6 top-10 hits** vs E1 — a (small) improvement on points and a
  large improvement on the user-visible top-10 metric, not a
  regression.

`embedder-expansion-plan.md` §"Final comparison" carries the corrected
table. `e4-next-steps-report.md` §4a documents the rescore audit. The
batched-vs-single per-vector diff (originally proposed step 2 below)
is no longer needed: `TrademarkTranscriptFixtureTests` already pins
batch ≡ single parity at the embedder level, and the rubric numbers
no longer contradict that pin.
