# E10 — Markdown extraction before embedding

Status: comparison complete; final report review and agent cleanup pending. See [the report](report.md) and [successful run archive](runs/20260906-225138-metal/summary.md).

## Question

Does removing Markdown presentation and link destinations before chunking
improve file retrieval with the existing E5 model? This experiment tests a
general file-format capability. It does not recognize Notion bundles,
YouTube IDs, transcript timestamps, or the user's directory layout.

## Fixed scope

- Existing `e5-base@1200/0` model and character-based splitter.
- Raw extraction remains the default; `markdown-v1` is an explicit option.
- Markdown link labels and image descriptions remain searchable; their
  destinations are omitted. Bare URLs and code remain literal.
- Preserve source-line correspondence and paragraph/list/heading boundaries.
- Preserve frontmatter; extracting metadata or repeating titles is deferred.
- No keyword retrieval, reranking, summaries, sentence-count chunking,
  duplicate suppression, or new embedding models.

## Controlled comparison

Freeze the Markdown files from `/tmp/LinksDatabase` in a scratch directory
and record their relative paths, hashes, and sizes. Include the large
Markdown attachment. Exclude other formats identically from both arms to
isolate Markdown extraction; this is an experiment input selection, not a
new production scanner policy. Do not commit source document bodies.

Commit a fixed query manifest and expected files before observing rankings.
Include exact names, vague recollections, details within long documents,
and separate no-answer probes. Build independent raw and normalized indexes
from the same snapshot. Record profile, extraction version, build/runtime
settings, candidate results, chunk counts, indexing and search elapsed time.
Report memory measurements only with their measurement scope made clear.

Prioritize rank 1, top 3/top 5, and reciprocal rank. With only nine Markdown
files, top-10 success is not informative. Keep file rank separate from
whether the returned passage actually supports the query. Preserve negative
probes for inspection without inventing an uncalibrated similarity cutoff.

## Success criteria

- [x] Parser-backed normalization handles links/references, Unicode, malformed input, code, frontmatter, multiline syntax and CRLF.
- [x] Opt-in extraction occurs before chunking, preserves source locations, and leaves non-Markdown extraction unchanged.
- [x] Persist extraction mode, inherit it for updates/inserts, read legacy profiles as raw, and reject incompatible incremental updates.
- [x] Relevant automated tests pass.
- [x] Freeze queries/corpus, run both real-model arms, archive reproducible results and audit representative source ranges/passages.
- [x] Write a report distinguishing observed changes from hypotheses and noting the small corpus and coverage limitations.
- [ ] Two independent reviewers approve; all workers are merged or retired.

An accuracy improvement is a hypothesis, not a completion requirement. A
neutral or negative result is useful and must be reported without tuning
queries after seeing the outcome. No default changes based on this sample.
