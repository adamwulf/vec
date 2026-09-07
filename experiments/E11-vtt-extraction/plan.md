# E11 — Opt-in WebVTT extraction before embedding

Status: in progress. Follows the E10 Markdown-extraction pattern: a new
versioned, opt-in text-extraction mode that normalizes a single file
format before chunking, leaving every other format untouched and the
default unchanged.

## Question

Does stripping WebVTT caption scaffolding — the header, cue identifiers,
timing/settings lines, `NOTE`/`STYLE`/`REGION` blocks, inline cue markup,
and the overlap that rolling captions repeat — before chunking produce
cleaner, more readable transcript prose for embedding? This experiment
tests a general `.vtt` file-format capability with the existing default
embedder. It does not recognize any particular caption tool, transcript
provider, or the user's directory layout.

## Fixed scope

- Existing default embedder and character-based splitter; no new models,
  reranking, summaries, or keyword retrieval.
- Raw extraction stays the default. Two new opt-in modes are added:
  - `vtt-v1` — normalizes `.vtt` files only; all other formats
    (Markdown included) pass through as raw.
  - `markdown-v1+vtt-v1` — the combined mode; runs the existing
    `markdown-v1` normalizer on `.md` / `.markdown` and the new WebVTT
    normalizer on `.vtt`. Both components are the same versioned
    algorithms as the single-format modes.
- The `vtt-v1` normalizer:
  - removes the `WEBVTT` header line (and any header metadata), optional
    cue identifiers, cue timing lines with their positioning/settings,
    and `NOTE` / `STYLE` / `REGION` blocks;
  - removes inline cue markup (`<v Speaker>`, `<c>`, `<i>`, timestamp
    tags, etc.) and decodes HTML entities;
  - joins consecutive cues into flowing paragraphs;
  - preserves `<v>` speaker labels as inline speaker prefixes;
  - conservatively removes the rolling/paint-on overlap that repeats the
    tail of the previous cue, dropping only text that clearly repeats.
- Source cue line ranges are retained so results still point back to the
  originating span in the `.vtt` file.
- No schema change: the vector schema carries no timestamp metadata, so
  cue timings are dropped during normalization rather than persisted. This
  mode changes preprocessing only.
- Persistence and mismatch behavior are identical to `markdown-v1`: the
  mode is recorded on the database profile, inherited by updates and
  single-file inserts, legacy profiles without the key read as `raw`, and
  an incompatible incremental update is refused (reset + re-index to
  change modes).
- Out of scope for this experiment: sentence-count chunking, duplicate
  suppression across files, speaker-diarization heuristics beyond the
  literal `<v>` label, timestamp-aware retrieval, and any default change.

## Boundary with the integrated feature

This plan's CLI-and-docs slice adds the two mode cases to both mode enums
(`TextExtractionMode` and the CLI `TextExtractionOption`), threads them
through `update-index`, extends the CLI test suite, and documents the
behavior. The WebVTT normalizer, its wiring into `TextExtractor`, the
VecKit-level normalizer tests, and the final passage/dedup validation
document are owned by the feature manager and land alongside this slice.
The exact conservative-overlap and cue-join behavior is finalized there;
this plan describes the intended contract those pieces implement.

## Success criteria

- [ ] The `vtt-v1` normalizer produces noise-free, readable prose: no
  header, identifiers, timing/settings lines, `NOTE`/`STYLE`/`REGION`
  blocks, cue markup, or undecoded entities survive into the embedded
  text.
- [ ] Normalizer tests cover malformed input (missing header, bad timing
  lines, stray blocks, truncated cues), Unicode (multi-byte text and
  entities), rolling/paint-on overlap removal, and `<v>` speaker-label
  preservation.
- [ ] Extraction is opt-in and reproducible: the same input yields the
  same normalized output; `raw` is unchanged; non-`.vtt` files under
  `vtt-v1` are untouched; under `markdown-v1+vtt-v1`, `.md`/`.markdown`
  and `.vtt` are each normalized by their versioned component.
- [ ] Source cue line ranges are preserved so search results map back to
  the originating `.vtt` span.
- [ ] Mode persistence matches `markdown-v1`: recorded on the profile,
  inherited on updates/inserts, legacy-reads-as-`raw`, and every mode
  mismatch pair is refused until reset — covered by the CLI test suite.
- [ ] The full automated suite passes (VecKit normalizer tests + CLI mode
  tests).
- [ ] Two independent reviewers approve the integrated feature; all
  workers are merged or retired.

An accuracy improvement is a hypothesis, not a completion requirement.
This experiment does not claim a measured retrieval-accuracy or
indexing-speed gain. A neutral result is useful and must be reported
without tuning after the fact. The default stays `raw`; no default change
is made on the basis of this work.
