# Single versus batch embedding parity

## Acceptance criteria

- Reproduce and record the five existing parity assertions without changing production code.
- Isolate each cause with a focused reproduction before applying the fix.
- Keep the existing cosine threshold (0.9999), test coverage, and model/pooling conventions.
- Document vector compatibility and reindexing requirements.
- Run the full suite after the fix, accounting for every baseline failure and skip.
- Obtain two independent reviews of the finished changes.

## Baseline

Production baseline: main `c885586e206795982b2766ad3ccd30242c1ddd24`.
The worker ran the branch with the two diagnostic tests from `110845d`
and unchanged production code on 2026-09-06:

```sh
swift test --disable-sandbox --disable-swift-testing -j 4
```

Result: 356 tests, 3 existing opt-in skips, 11 assertion failures in four
test methods. Five assertions are the original embedding failures, five
are from the added diagnostic tests, and one is an unrelated stale
default-alias assertion. Log: `/tmp/embedding-batch-fix-worker-baseline.log`.
The original 354-test clean-main run recorded by `vtt-handler` reproduced
the same five embedding values plus the same default-alias failure.

The reported “five tests” are five assertions in the same test method:
`TrademarkTranscriptFixtureTests.testBatchedEmbedMatchesSingleEmbedForAllBuiltIns`.
Every assertion requires cosine similarity **>= 0.9999** (distance from
perfect agreement <= 0.0001).

| Assertion | Observed cosine | Expected minimum |
| --- | ---: | ---: |
| gte-base, long target | 0.7817819987924215 | 0.9999 |
| gte-base, short target padded beside long filler | 0.732244066070525 | 0.9999 |
| e5-base, long target | 0.864954483364585 | 0.9999 |
| mxbai-large, long target | 0.9225200688996962 | 0.9999 |
| mxbai-large, short target padded beside long filler | 0.8659779075969087 | 0.9999 |

The unrelated baseline failure is
`IndexingProfileTests.testFactoryDefaultAliasIsKnown`: actual `e5-base`,
expected `bge-base`. The `vtt-handler` branch owns that correction.
The existing opt-in skips are the concurrency performance sweep, E10
Markdown retrieval benchmark, and huge-first-file pipeline benchmark.

## Pre-fix isolation

`BertBatchDiagnosisTests.testPrefixedBatchUsesSameCharacterBudgetAsSingle`
shows E5 preprocessing gives **2009 characters in a batch vs 2000 alone**.
The batch helper caps the content before prepending `passage: `, while
the single path caps the entire prefixed string. This happens before
tokenization, attention, mean pooling, or L2 normalization.

`BertBatchDiagnosisTests.testGTEInputAndMaskProbe` uses the identical
12-token input for the single and batched GTE paths. Cosines against
the single unmasked path:

| Comparison | Cosine |
| --- | ---: |
| One-item batch, all-ones mask, no padding | 0.7322439469629322 |
| Two identical rows, no padding | 0.7322439469629322 |
| Target padded to 182 tokens alongside another text | 0.732243797677053 |
| First token extracted from the entire materialized sequence output | 0.732243797677053 |

Thus GTE's discrepancy already exists with identical tokens and shape;
neither length drift, padding, nor CLS output slicing explains it.
The difference is introduced by the attention-mask path.

`BertBatchDiagnosisTests.testAttentionMaskPrecisionProbe` (commit `5210a84`)
then varied only the scalar type of an all-ones attention mask, with
identical input tokens and shape. No production changes had been made.
The diagnostic cosine calculation used Float-normalized vectors, so
values very slightly above one reflect normalization roundoff.

| Model | Output without mask | Output with Float32 mask | Output with Float16 mask | Cosine: no mask vs Float32 mask | Cosine: no mask vs Float16 mask |
| --- | --- | --- | --- | ---: | ---: |
| GTE | Float16 | Float32 | Float16 | 0.7322439469629322 | 0.9999992217268647 |
| MXBAI | Float16 | Float32 | Float16 | 0.8659774506126328 | 0.9999989962910784 |
| BGE-base | Float32 | Float32 | Float32 | 1.0000003031225027 | 1.0000003031225027 |
| E5 | Float32 | Float32 | Float32 | 0.9999999848827219 | 0.9999999848827219 |

Log: `/tmp/embedding-batch-fix-worker-precision.log`.

## Root cause and fix

There are two independent causes:

1. GTE and MXBAI weights load as Float16. The dependency's single
   `Bert.ModelBundle.encode` omits the attention mask; `batchEncode`
   supplies a Float32 mask. Adding the mask to attention scores promotes
   the subsequent tensor calculations and sequence output to Float32.
   This changes the inference precision even when the mask contains only
   ones and the batch has only one row. Casting the final output to Float
   cannot undo earlier low-precision calculations. CPU-only execution
   does not remove a scalar-type difference.
2. E5 single preprocessing prepended its prefix before truncating;
   batched preprocessing did these operations in the reverse order.
   Thus long inputs could tokenize differently despite identical source
   text. Masked mean pooling and L2 normalization were already consistent.

GTE and MXBAI now use the dependency's masked `batchEncode` for single
documents and queries as well. This retains the existing batch path's
precision and vectors, including query prefixing and compute-policy
selection. E5 now shares one prefix-then-cap input normalization function
between single and batch paths. Nomic retains its separate convention of
capping content before prefixing.

No weights, dependency versions, pooling conventions, model identities,
token limits, or tolerances were changed. The exploratory diagnosis tests
are preserved in the pre-fix commits and replaced in the final tree by
`BertBatchParityTests`, which exercises the public embedding contract on
automatic and CPU policies plus character-budget and query-prefix edges.
The original five fixture assertions are unchanged.

## Index compatibility

See [the reindexing note](../embedding-compatibility.md). GTE/MXBAI batch
vectors are retained, but legacy single-document and cached query vectors
change. Long E5 batch vectors can change; its single/query vectors are
retained. No automatic migration is attempted.

## Final validation

The worker ran the complete suite on fix commit `ff3d9dd`, ending on
2026-09-07, with the same command and runtime as the baseline:

```sh
swift test --disable-sandbox --disable-swift-testing -j 4
```

Log: `/tmp/embedding-batch-fix-worker-final.log`.
Result: **359 tests, 355 passed, 3 existing skips, 1 unrelated failure**
in 293.735 seconds. The sole remaining failure is the baseline
`IndexingProfileTests.testFactoryDefaultAliasIsKnown` assertion
(`e5-base` actual vs `bge-base` expected), separately fixed on the
`vtt-handler` branch. This branch does not claim a completely green suite.

- The original fixture's five parity assertions all pass at the unchanged
  0.9999 minimum cosine.
- All five `BertBatchParityTests` pass, including the three model parity
  methods under both automatic and CPU-only policies.
- All **349 baseline-passing test names still pass**; no regressions.
- The three opt-in skips are unchanged. No new skips or expected failures
  were introduced.
- The two initially failing diagnosis methods were replaced by five
  regression methods, so total test count increases from 356 to 359.
  The third precision probe was added and run separately after the full
  baseline; it is also preserved in commit `5210a84`, not in the final tree.

The standalone character-budget test also passed locally without loading
CoreML. Full inference verification used the authorized worker runtime;
the Codex manager runtime could build the suite but crashed while CoreML
loaded model tensors, before inference assertions ran.
