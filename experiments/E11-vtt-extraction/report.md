# E11 — WebVTT extraction before embedding

Completed 2026-09-07. On this frozen 16-file sample, `vtt-v1` improved correct-file-at-rank-1 from **14/15 (93.3%) to 15/15 (100%)**, with MRR rising from **0.956 to 1.000**. Top-five accuracy stayed 15/15. Chunk count fell **57.1%**, from 205 to 88, and the share of extracted chunks containing timestamp lines or inline tags fell from **100% to 0%**.

**All but one sample file are synthetic.** The one improved query targets a synthetic recording tutorial. The real-caption query ranked first in both arms. These results support this optional preprocessing capability on the sample; they do not establish an accuracy gain across Adam's full caption corpus. Raw remains the default.

## What changed

The versioned `vtt-v1` normalizer removes WebVTT headers, cue identifiers, timing/settings lines, NOTE/STYLE/REGION blocks, and inline tags. It decodes character references, retains voice names, joins fragmented cues into passages, and conservatively removes rolling-caption overlap before the existing chunker runs. Chunks retain coarse source cue line ranges; no timestamp column or schema redesign was added.

The CLI records the extraction mode and inherits it on updates and inserts. Changing a recorded mode requires reset/reindexing. `markdown-v1+vtt-v1` supports mixed Markdown/caption collections. This experiment compares only `raw` and `vtt-v1`.

## Sample, labels, and provenance

`/tmp/LinksDatabase` contained only one `.vtt`, so Adam authorized generating the rest. The [committed sample](sample/README.md) contains 16 captions, 2,085 cues, and 207,088 bytes: the unchanged Anna Rudolf Minecraft caption plus 15 synthetic files on distinct topics. Six synthetic transcripts have at least 200 cues; nine have 15–60 cues. Cooking and physics use rolling, overlapping windows. Other files cover named dialogue, unvoiced narration, human-style captions, and per-word timestamps, with varied structural blocks, settings, tags, and entities.

The [sample manifest](sample/manifest.json) freezes each path, byte count, SHA-256, and structural inventory. Both deterministic generators reproduced the committed caption bytes after integration. Only `.vtt` files were indexed; source prose, generators, manifests, and README files were excluded.

The manager read the spoken content before writing the [15-query rubric](queries/rubric-queries.json), which uses E10's JSON shape. Queries target specific claims, speakers, and topics spanning cues. Each has one expected file and advisory passage criteria; balcony tomatoes is the sole unlabeled distractor. There are no no-answer probes. Two reviewers checked the labels before rankings. One pre-run correction allowed both `crepeline` and the caption's decoded `crêpeline`; no labels or sample content changed after results were observed.

The code was **rebased onto main `5ee92ab563d348924312747e6631a639b96f1b35`** before the run, preserving the original commits. Both arms ran in one invocation at clean commit `0d013d1bfa9015a498615e0d51f5e4771d80d21c`. That main revision contains the separately authored embedding-parity fixes. E11 adds no inference changes beyond that baseline.

Both arms used local `intfloat/e5-base-v2` revision `f52bf8ec8c7124536f0efb74aca902b2995e5bcd`, profile `e5-base@1200/0`, concurrency 8, batch size 32, bucket width 500, and default compute policy. Documents used the **same batch embedding pipeline**; queries used the **same single-query path**. Search fetched 30 chunk hits and coalesced at most 10 files, matching E10 and the CLI. Only extraction mode differed between arms.

The [run archive](runs/20260907-060151-current-main/summary.md) includes all 30 per-query JSON files, arm summaries, the frozen sample manifest, [input/model/query/build hashes](runs/20260907-060151-current-main/frozen-input-manifest.json), [exact command and environment](runs/20260907-060151-current-main/execution-command.txt), [execution log](runs/20260907-060151-current-main/execution.log), and [independent scores](runs/20260907-060151-current-main/independent-score.json). Seven model files were hashed. The release benchmark passed with exit 0 in 61.659 seconds after a 141.41-second build. Both arms indexed 16/16 files with no skipped files or failed chunks.

## Results

| Measure | Raw | VTT v1 |
|---|---:|---:|
| Correct file at rank 1 | 14/15 (93.3%) | 15/15 (100%) |
| Correct file in top 5 | 15/15 | 15/15 |
| Mean reciprocal rank | 0.9556 | 1.0000 |
| Total chunks, including whole-document chunks | 205 | 88 |
| Passage chunks | 189 | 72 |
| Noisy chunks / all chunks | 205/205 (100%) | 0/88 (0%) |
| Noisy passage chunks / passages | 189/189 (100%) | 0/72 (0%) |
| Advisory passage criteria all present | 3/15 | 12/15 |
| Index wall time | 43.54 s | 13.15 s |
| Search-loop wall time | 2.29 s | 1.72 s |
| Process RSS after indexing | 3,577 MiB | 5,357 MiB |

The measured rank-1 gain is 6.7 percentage points, entirely from one query. There are no file-rank regressions. Total extracted text shrank from 207,052 to 68,939 Swift characters (66.7%); this includes structural removal and rolling deduplication, not just whitespace removal.

| Query | Target / spoken detail | Raw rank | VTT v1 rank |
|---|---|---:|---:|
| q01 | Real Minecraft caption: underwater breathing space | 1 | 1 |
| q02 | Flatbread: hand stretching preserves bubbles | 1 | 1 |
| q03 | Devin: beginner-friendly French cleat | 1 | 1 |
| q04 | Sam: appointments an hour off and daylight saving | 1 | 1 |
| q05 | Pendulum: quadruple length to double period | 1 | 1 |
| q06 | Lighthouse: identifying flash pattern | 1 | 1 |
| q07 | Battery: pass-through charging | 1 | 1 |
| q08 | Portrait: foam-board fill light | 1 | 1 |
| q09 | Priya Raman: dislodging brake bubbles | 1 | 1 |
| q10 | Wetland: measuring surface accretion | 1 | 1 |
| q11 | Telescope: Polaris on the offset circle | 1 | 1 |
| q12 | Glazing: wax resist and kiln wash | 1 | 1 |
| q13 | Field recording: background ambience for editing | 3 | 1 |
| q14 | Lena Fischer: tram signal priority | 1 | 1 |
| q15 | Textile conservation: supporting split silk | 1 | 1 |

## What the improved query retrieved

**q13:** “Why record half a minute of plain background sound before leaving a nature recording location?”

The [raw result](runs/20260907-060151-current-main/raw/q13.json) ranks the wetland lecture first (score 0.7911), the Minecraft caption second (0.7885), and the correct field-recording tutorial third (0.7820). The raw result is a near-tie, with only 0.0091 separating first and third. Its best match in the expected file is passage ordinal 2, source lines 1–43: opening setup material without the closing room-tone explanation.

The [normalized result](runs/20260907-060151-current-main/vtt-v1/q13.json) ranks the field-recording tutorial first. Its best match is the whole-document chunk, now only 1,551 characters before the E5 prefix, compared with 6,310 raw characters. The reconstructed pre-tokenizer input contains both `room tone` and `coughs and bumps`, the explanation given in the final spoken paragraph. Removing caption structure makes the entire short tutorial fit within E5's character cap; the audit does not establish which words survive the subsequent tokenizer limit.

This is a concrete observed change in ranking and retrieved context. It does not isolate which individual normalization step caused the change.

## Interpreting passage, noise, and performance measures

The advisory passage metric checks fixed strings or regexes in the best retrieved chunk for the expected file. The harness reconstructs that chunk **by ordinal**, then applies the shared E5 prefix-then-cap helper. BERT subsequently truncates to 512 tokens. A positive check is not proof that the model encoded the entire answer, and it is not a human relevance judgment.

The 3/15 to 12/15 passage change is **structure-sensitive**: raw cue breaks, tags, entities, and repeated words can interrupt a literal phrase even when its content is present. It must not be reported as an arm-neutral semantic-accuracy gain. Speaker-name criteria also require the name and answer to appear in the same retrieved chunk. Source ranges remain available for human inspection.

Noise is the union of a timestamp-line match and an inline-tag match, counted once per chunk. Raw has 205 timestamp-bearing chunks and 172 tag-bearing chunks; all 205 are noisy. VTT v1 has neither. This heuristic runs on **full extracted chunk text before model character/token truncation**, including whole-document chunks. It measures caption scaffolding, not retrieval quality or an exact fraction of model tokens. Decoded literal tags can count as noise; ordinary spaced prose comparisons do not.

Timing and RSS are observations from one ordered run in one process: raw first, normalized second. Caches, initialization, batch shapes, and concurrent system activity can affect them. Search-loop time includes passage auditing, and RSS is a point-in-time process measurement, **not peak memory**. The higher second RSS reading cannot be attributed to the normalized arm alone. This experiment does not establish a general speed or memory improvement.

## Validation and decision

The independent scorer reuses E10's rank validator and recomputes ranks from archived ordered groups. It validates query identity, sample fingerprints, complete per-file indexing, chunk totals, and noise arithmetic. Its 10 regression tests pass; all 38 focused WebVTT/CLI/harness tests pass after integration.

The [full suite log](runs/20260907-060151-current-main/full-suite.log) records **392 tests, zero failures, four expected opt-in skips** at the same tested commit, using `swift test --disable-sandbox --disable-swift-testing -j 4`. The old batch-parity test and the new parity regressions pass. The four skips are the concurrency sweep, huge-first-file pipeline test, E10 benchmark, and E11 benchmark; the latter was then run separately and passed. The [earlier validation record](validation.md) preserves the historical failures before the main inference fixes.

Keep `vtt-v1` opt-in. This sample shows one file-finding improvement and substantially less structural noise and fewer chunks. Fifteen synthetic transcripts with mostly distinct topics are an easy, small evaluation: they cannot estimate accuracy across roughly 3,341 real captions. The only real query showed no rank change. There were no no-answer probes or repeated runs.

The protocol, model snapshot, chunker, and settings mirror E10, but **the corpus, query set, and inference revision differ**. E11's scores cannot be compared with E10's absolute scores as an extraction-only effect. The within-E11 comparison holds inference fixed and uses the same batch/single paths for both arms.

The next useful measurement would use more real captions, similar-topic distractors, and user-written recollection queries fixed before ranking, with human passage judgments. This run supplies no evidence for a default flip or an inference change.

```bash
vec update-index --db <fresh-or-reset-name> --text-extraction vtt-v1
python3 experiments/E11-vtt-extraction/scripts/score-vtt-rubric.py \
  experiments/E11-vtt-extraction/runs/20260907-060151-current-main
```
