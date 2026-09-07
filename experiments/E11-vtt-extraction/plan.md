# E11 — Opt-in WebVTT extraction before embedding

Status: implementation and retrieval measurement complete (2026-09-07). On 16 frozen captions (1 real, 15 synthetic), rank-1 accuracy improved 14/15 → 15/15 and MRR 0.956 → 1.000; chunks fell 205 → 88 and extracted timestamp/tag noise 100% → 0%. The one rank gain was synthetic, so this is not a full-corpus accuracy estimate. The versioned modes remain opt-in. Both arms use the same inference from main `5ee92ab`, adopted by rebase; the separate parity fix resolves the earlier failures. Full suite: 392 tests, zero failures, 4 expected opt-in skips. See the [measured report](report.md), [run archive](runs/20260907-060151-current-main/summary.md), and [historical validation](validation.md).

## Question

Does stripping WebVTT caption scaffolding — the header, cue identifiers,
timing/settings lines, `NOTE`/`STYLE`/`REGION` blocks, inline cue markup,
and the overlap that rolling captions repeat — before chunking produce
cleaner, more readable transcript prose for embedding? This is a general
`.vtt` file-format capability with the existing default embedder. It does
not recognize any particular caption tool, transcript provider, or the
user's directory layout.

## Fixed scope

- Existing default embedder and character-based splitter; no new models,
  reranking, summaries, or keyword retrieval.
- Raw extraction stays the default. Two opt-in modes are added:
  - `vtt-v1` — normalizes `.vtt` files only; all other formats
    (Markdown included) pass through as raw.
  - `markdown-v1+vtt-v1` — the combined mode; runs the existing
    `markdown-v1` normalizer on `.md` / `.markdown` and the WebVTT
    normalizer on `.vtt`. Both components are the same versioned
    algorithms as the single-format modes.
- The `vtt-v1` normalizer parses cue blocks (rather than treating every
  non-timing line as speech) and:
  - removes the `WEBVTT` header, optional cue identifiers, cue timing
    lines with their positioning/settings, and `NOTE` / `STYLE` /
    `REGION` blocks;
  - removes inline cue markup (`<v>`, `<c>`, `<i>`, `<lang>`, `<ruby>`,
    inline `<hh:mm:ss.fff>` timestamps, `<br>` → space);
  - decodes character references — WebVTT named entities `amp`, `lt`,
    `gt`, `nbsp`, `lrm`, `rlm`, plus `quot` and `apos`, and decimal
    (`&#39;`) and hexadecimal (`&#x27;`) numeric references. An
    unrecognized name or an out-of-range numeric reference is left
    literal on purpose;
  - joins cues into paragraphs, breaking on a speaker change, a silence
    gap of ≥ 5 s, a backwards clock, or ≥ 30 s of a running paragraph;
  - preserves `<v>` speaker labels as inline `Speaker:` prefixes;
  - removes rolling/paint-on overlap conservatively: only against the
    immediately preceding, single-speaker cue whose speaker matches and
    whose start falls within `[prev.start, prev.end + 0.1 s]`. An exact
    repeat is dropped only when the cues actually overlap in time; a
    partial trailing suffix is dropped when it is ≥ 2 words (or 1 word
    during genuine time overlap). Never across a speaker change,
    silence, backwards time, or a multi-speaker cue.
- Tolerant parsing for real exporter output: a missing `WEBVTT` header
  still yields cues, a leading byte-order mark is ignored, `\n` / `\r\n`
  / `\r` line endings are accepted, and a timing line with no preceding
  blank separator starts a new cue instead of leaking into the previous
  prose. Blocks with no valid timing line (or out-of-range clocks) are
  skipped.
- Source cue line ranges are retained (first timing line through last
  payload line of the passage) so results still point back to the
  originating span in the `.vtt` file.
- No schema change: the vector schema carries no timestamp metadata, so
  cue timings are dropped during normalization rather than persisted.
- Persistence and mismatch behavior match `markdown-v1`: the mode is
  recorded on the database profile, inherited by updates and single-file
  inserts, legacy profiles without the key read as `raw`, and an
  incompatible incremental update is refused (reset + re-index to change
  modes).
- Out of scope: sentence-count chunking, cross-file duplicate
  suppression, speaker-diarization heuristics beyond the literal `<v>`
  label, timestamp-aware retrieval, and any default change.

## Success criteria

- [x] Normalize cue structure, supported character references, speaker labels and rolling overlap into readable prose.
- [x] Cover malformed input, Unicode/BOM, all three line endings, missing separators, indented timing, long rolling cues and multiple voices.
- [x] Keep extraction opt-in and reproducible; preserve raw/Markdown behavior and support the combined mode.
- [x] Map split passages back to coarse source cue line ranges; verify scanner discovery.
- [x] Preserve profile recording, update/insert inheritance, legacy raw defaults and rejection of every incompatible mode pair.
- [x] Run full suites on clean main and the feature branch; confirm all previously passing main tests and all WebVTT tests pass. Record the five unchanged baseline inference failures separately, per the user's scope decision.
- [x] Obtain two independent implementation approvals and merge the CLI worker.

An accuracy improvement was a hypothesis, not a completion requirement. The completed run found one rank-1 improvement on the synthetic-heavy sample, documented in [report.md](report.md), and makes no general indexing-speed or full-corpus accuracy claim. No captions or query labels were tuned after ranking. The default stays `raw`.

## Retrieval evaluation follow-up (2026-09-07)

Status: run complete at clean commit `0d013d1`, on main `5ee92ab`. Both arms indexed 16/16 files and ran all 15 queries; the independent scorer agrees with the harness. Query q13 moved from rank 3 to rank 1, while the other 14 stayed at rank 1. The protocol below records the pre-run design; see [report.md](report.md) for results and limitations.

Adam authorized a mixed real/synthetic sample after the supplied corpus
contained only one WebVTT file. Use 16 files: that real Minecraft video
caption file and 15 newly authored synthetic transcripts. The synthetic
files span distinct topics, short and long recordings, named and unnamed
speakers, and at least two rolling-caption exports. Commit all caption
bodies under `sample/` and identify their origins. Synthetic results
cannot establish accuracy on the real 3,341-file caption corpus.

Before either arm runs, commit a sample manifest with SHA-256 hashes and
a fixed rubric of approximately 15 answered queries. Assign expected
files and advisory passage criteria by reading the spoken text, including
a specific claim, a named speaker, and explanations spanning several cues.
Do not change captions, query wording, or labels after seeing ranks.

Mirror E10: pinned `e5-base@1200/0`, local E5 revision `f52bf8ec8c7124536f0efb74aca902b2995e5bcd`, concurrency 8, batch 32, bucket width 500, default compute policy, fetch 30 chunk hits and coalesce to 10 files. Both arms use the same batch document-embedding pipeline and the same single-query embedding path. Per Adam’s updated instruction, the feature was rebased onto current main `5ee92ab563d348924312747e6631a639b96f1b35` before either arm. This includes the separately authored inference fixes, including aligned E5 prefix/truncation behavior. Neither arm may change inference code. The settings and protocol mirror E10, but its earlier inference revision differs; cross-experiment metric differences cannot be attributed solely to extraction. No rankings had been observed when this baseline update was made.

Index the same frozen sample into fresh raw and vtt-v1 databases, then
archive every query result. Report per-query file ranks, hit@1, hit@5,
MRR, advisory pre-tokenizer passage checks, chunk counts, and the share
of chunks containing a timestamp line or inline cue tag. Report noise for
all chunks (including whole-document chunks) and passage chunks
separately; count the union once when both noise types occur.

The run archive must include frozen corpus/model/query/build provenance,
per-arm summaries, per-query JSON, execution log, independent scorer
output, and summary.md. Write report.md with plain measured results,
including neutral or negative results and the synthetic-sample,
distinct-topic, tokenizer, arm-order, and inference limitations.

Completion checks: reviewed/committed inputs and harness before ranking; complete indexing in both arms; independent scoring and provenance audit; two reviewers approve the results; README and this plan link the measured report rather than calling accuracy unmeasured.

Pre-run review decisions: passage-string checks are structure-sensitive, because raw tags, entities and cue fragmentation can break an otherwise relevant phrase. Report these separately from file rank and do not call them an arm-neutral semantic-accuracy measure. Speaker criteria q03 and q14 were checked to share a short turn with their answers; future speaker/detail labels must verify that co-location. The scorer deliberately imports the E10 ranking validator to reuse the same scoring rules; preserve that relative dependency if either experiment is moved.

The complete sample is frozen in sample/manifest.json: 16 files (1 real, 15 synthetic), with hashes and structural inventory. Both deterministic generators reproduced the committed caption bytes after integration, and freeze-sample.py --check verified every hash and sampling requirement before indexing. The q15 accent correction was made during review, before any rankings, to accept both crepeline and the decoded crêpeline spelling.
