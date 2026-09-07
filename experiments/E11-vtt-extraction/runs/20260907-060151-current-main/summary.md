# E11 WebVTT-extraction retrieval benchmark

Run identity: `5b7bbf3787fd7606e6ef99701fd2d17a444408849917e9471bd3896a4b223a2c`  
Frozen at: 2026-09-07T06:10:33Z

Corpus: `/Users/adamwulf/Developer/swift-packages/vec/.ittybitty/agents/agent-98cdd5df/repo/experiments/E11-vtt-extraction/sample` — 16 WebVTT file(s). Manifest sha256 `da9aabff0b4d…` (15 queries). Model files hashed: 7. Build: release.

Settings: `e5-base@1200/0`, chunk 1200/0, concurrency 8, batch 32, bucket 500.

## Aggregate (answered queries only)

| arm | rank1 | top3 | top5 | MRR | passage-all-met | chunks | index s | search s | RSS after |
|---|---|---|---|---|---|---|---|---|---|
| raw | 93% | 100% | 100% | 0.956 | 20% | 205 | 43.54 | 2.29 | 3577 MB |
| vtt-v1 | 100% | 100% | 100% | 1.000 | 80% | 88 | 13.15 | 1.72 | 5357 MB |

> File rank is authoritative. `passage-all-met` is an advisory, case-insensitive check of the criteria against the PRE-TOKENIZER model input, reconstructed BY ORDINAL from the arm's extractor via `E5BaseEmbedder.normalizeInputs` (the `passage: ` prefix prepended, then the combined string capped at the E5 char limit — prefix-then-cap, shared by E5's single and batch document paths under the current-main parity fix). For vtt-v1 the normalizer reflows cue lines, so this by-ordinal reconstruction — not the raw source range — is the text actually embedded. The BERT tokenizer truncates further to 512 tokens, so a match here is necessary but NOT sufficient evidence the model encoded the term; it does not gate file rank. Because the raw arm's passage text still carries cue tags, character entities, and rolling-caption fragmentation, these literal criteria can fail on `raw` even when the content is present — so `passage-all-met` is a structure-sensitive advisory, not an arm-neutral measure of semantic accuracy.

## Scaffolding noise (share of embedded chunks carrying ≥1 WebVTT timing line or inline tag)

| arm | all: noisy/total | all share | passages: noisy/total | passages share |
|---|---|---|---|---|
| raw | 205/205 | 100% | 189/189 | 100% |
| vtt-v1 | 0/88 | 0% | 0/72 | 0% |

> Noise is a syntactic heuristic on the FULL extracted chunk texts, computed BEFORE E5's 2000-char cap and the tokenizer's 512-token truncation — an upper bound on scaffolding reaching the model, not a guarantee it is in the vectors. A timing LINE is a full cue timing line (`HH:MM:SS.fff --> HH:MM:SS.fff`, leading whitespace allowed); an inline tag is a narrow WebVTT tag (`<v …>`, `</v>`, `<c…>`, `<i>`, `<br>`, an inline `<HH:MM:SS.fff>` timestamp, …). A decoded literal `<i>` in genuine prose counts as syntactic noise. It measures residual scaffolding, not retrieval quality.

## Per-query file rank (answered)

| query | raw rank | vtt-v1 rank |
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
| q11 | 1 | 1 |
| q12 | 1 | 1 |
| q13 | 3 | 1 |
| q14 | 1 | 1 |
| q15 | 1 | 1 |

## No-answer probes (top file / score; no cutoff assumed)

| query | raw top / score | vtt-v1 top / score |
|---|---|---|

See `comparison.json`, per-arm `arm-summary.json` (incl. per-file noise), and per-query `<arm>/q*.json` (full ordered groups) for detail.
