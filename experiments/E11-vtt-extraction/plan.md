# E11 — Opt-in WebVTT extraction before embedding

Status: implementation complete. The versioned WebVTT modes are opt-in, raw remains the default, and no inference code changed. All WebVTT tests and every previously passing clean-main test pass. Five pre-existing embedding-parity assertions remain for a separate task. See [validation and baseline evidence](validation.md).

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

An accuracy improvement is a hypothesis, not a completion requirement.
This experiment makes no measured retrieval-accuracy or indexing-speed
claim. A neutral result is useful and must be reported without tuning
after the fact. The default stays `raw`; no default change is made on the
basis of this work.
