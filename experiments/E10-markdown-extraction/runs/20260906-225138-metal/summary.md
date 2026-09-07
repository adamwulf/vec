# E10 Markdown-extraction retrieval benchmark

Run identity: `86bd27eb0be805d0bf81929c056aa76bbc92a3477d6b287cba9491b0bc160d6f`  
Frozen at: 2026-09-06T22:51:38Z

Corpus: `/private/tmp/LinksDatabase` — 9 Markdown file(s). Manifest sha256 `4001957eef74…` (15 queries). Model files hashed: 7. Build: release.

Settings: `e5-base@1200/0`, chunk 1200/0, concurrency 8, batch 32, bucket 500.

## Aggregate (answered queries only)

| arm | rank1 | top3 | top5 | MRR | passage-all-met | chunks | index s | search s | RSS after |
|---|---|---|---|---|---|---|---|---|---|
| raw | 100% | 100% | 100% | 1.000 | 50% | 3093 | 665.95 | 82.04 | 5940 MB |
| markdown-v1 | 100% | 100% | 100% | 1.000 | 67% | 2973 | 667.02 | 47.09 | 4817 MB |

> File rank is authoritative. `passage-all-met` is an advisory, case-insensitive check of the criteria against the PRE-TOKENIZER model input (content capped at the E5 char limit, then the `passage: ` prefix). The BERT tokenizer truncates further to 512 tokens, so a match here is necessary but NOT sufficient evidence the model encoded the term; it does not gate file rank.

## Per-query file rank (answered)

| query | raw rank | markdown-v1 rank |
|---|---|---|
| q01 | 1 | 1 |
| q02 | 1 | 1 |
| q03 | 1 | 1 |
| q04 | 1 | 1 |
| q05 | 1 | 1 |
| q06 | 1 | 1 |
| q07 | 1 | 1 |
| q08 | 1 | 1 |
| q09 | 1 | 1 |
| q10 | 1 | 1 |
| q14 | 1 | 1 |
| q15 | 1 | 1 |

## No-answer probes (top file / score; no cutoff assumed)

| query | raw top / score | markdown-v1 top / score |
|---|---|---|
| q11 | content.md / 0.789 | content.md / 0.770 |
| q12 | content.md / 0.766 | content.md / 0.768 |
| q13 | content.md / 0.754 | content.md / 0.754 |

See `comparison.json`, per-arm `arm-summary.json`, and per-query `<arm>/q*.json` (full ordered groups) for detail.
