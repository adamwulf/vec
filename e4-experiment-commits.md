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
queries): **36/60, 9/10 top-10** vs E1's recorded **39/60, 10/10 top-10** —
a 3-point regression across queries Q3 ("muse trademark pricing
discussion") and Q6 ("trademark assignment agreement meeting") which
both lost the transcript target from top-20.

## Pending investigation

User flagged the regression as unexpected: batched embeddings should
arithmetically match single embeddings since `batchEncode` applies the
attention mask internally. Next steps:

1. Re-verify the 39/60 baseline (rescore E1 from scratch, no reliance on
   the archived number).
2. If the regression reproduces, diff per-vector output of
   `embedDocument(x)` vs `embedDocuments([x]).first` for identical input
   to pinpoint whether drift is in CoreML fp16 batched forward, padding/
   masking, or post-processing.
