# E12 image-OCR retrieval benchmark

Run identity: `f8029b668a6e25945efe8eb2b3833130777946e8fa2e32dba2fa96022c18af02`  
Frozen at: 2026-09-07T09:00:44Z

Corpus: `/Users/adamwulf/Developer/swift-packages/vec/.ittybitty/agents/agent-f8aa66db/repo/experiments/E12-image-ocr/sample` — 18 image(s). Manifest sha256 `8f778f71545f…` (15 queries). Model files hashed: 7. Build: release, OS Version 26.6.2 (Build 25G83). OCR recognizer v1, requestRevision 3, maxPixelDim 4096.

Settings: `e5-base@1200/0`, chunk 1200/0, concurrency 8, ocrConcurrency 4, batch 32, bucket 500.

## Aggregate (answered queries only)

| arm | rank1 | top3 | top5 | MRR | real rank1 | real MRR | synth rank1 | synth MRR | passage-met | scanned | indexed | chunks | index s | search s | RSS after |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| raw | 0% | 0% | 0% | 0.000 | 0% | 0.000 | 0% | 0.000 | 0% | 0 | 0 | 0 | 0.00 | 1.39 | 485 MB |
| image-ocr-v1 | 93% | 100% | 100% | 0.967 | 75% | 0.875 | 100% | 1.000 | 87% | 18 | 17 | 19 | 10.99 | 1.37 | 3975 MB |

> File rank is authoritative. The `raw` arm indexes ZERO images by design (the production scanner excludes them), so its aggregate is an honest 0% floor, not a bug — it quantifies that image text is unreachable without OCR. `passage-met` is an advisory, case-insensitive check of the criteria against the PRE-TOKENIZER OCR input reconstructed by ordinal via `E5BaseEmbedder.normalizeInputs`; the tokenizer truncates further to 512 tokens, so a match is necessary but NOT sufficient, and it never gates file rank.

## Per-query file rank (answered)

| query | origin | raw rank | image-ocr-v1 rank |
|---|---|---|---|
| q01 | real | — | 1 |
| q02 | real | — | 1 |
| q03 | real | — | 1 |
| q04 | real | — | 2 |
| q05 | synthetic | — | 1 |
| q06 | synthetic | — | 1 |
| q07 | synthetic | — | 1 |
| q08 | synthetic | — | 1 |
| q09 | synthetic | — | 1 |
| q10 | synthetic | — | 1 |
| q11 | synthetic | — | 1 |
| q12 | synthetic | — | 1 |
| q13 | synthetic | — | 1 |
| q14 | synthetic | — | 1 |
| q15 | synthetic | — | 1 |

See `comparison.json`, per-arm `arm-summary.json` (incl. per-file OCR chars), and per-query `<arm>/q*.json` (full ordered groups) for detail.

### Caveats

- Synthetic images are tiny, high-contrast, distinct-topic renders — an easy OCR + retrieval task, so the synthetic subset inflates the aggregate.
- Real targets were hand-picked for legible, text-dominant content (a chart, two diagrams, a title thumbnail); this is NOT representative of the real thumbnail/photo-heavy image corpus.
- Queries target what each image SAYS; no image assertion was fact-checked externally.
- The raw baseline is an empty index; a raw-vs-OCR file-rank comparison is therefore trivially one-sided by construction.
