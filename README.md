# vec

A command-line tool for creating and querying local vector databases, powered by SQLite and a pluggable on-device embedder pipeline.

## Overview

`vec` indexes the text content of files in a directory into a named vector database stored under `~/.vec/<db-name>/`. The embedder is pluggable — choose between Apple's NaturalLanguage framework and locally-hosted transformer models (BGE, Nomic) via the `--embedder` flag. The current default is `bge-base` (768-dim BERT-family, ~440 MB on first download). All embedding happens on-device — no API keys or network calls at query time.

Once indexed, you can perform semantic search across your files to find relevant content by meaning, not just keywords.

## Features

- **On-device embeddings** — Choose from six built-in embedders (see below); all run locally with no network round-trip at query time.
- **Pluggable embedder profiles** — `--embedder <alias>` selects the model. The model + chunking parameters are recorded as a profile identity on the DB and re-used on every subsequent command, so a database always re-uses the same embedder it was built with. See `indexing-profile.md` for the grammar.
- **Batched embedding** — The indexing pipeline batches chunks for the BERT-family embedders (BGE, Nomic) via `swift-embeddings` `batchEncode`, with an `EmbedderPool` actor that holds N model instances for real parallel inference.
- **Chunked indexing** — Text is split into overlapping character-bounded chunks via `RecursiveCharacterSplitter` (a port of LangChain's recursive character splitter).
- **PDF support** — Extracts text per page from PDFs and indexes each page separately.
- **Change detection** — Tracks file modification dates to efficiently update only changed files.
- **SQLite-backed** — Stores embeddings as raw Float32 blobs; cosine-similarity search is pure Swift (no dynamic libraries).
- **`.gitignore` / `.vecignore` support** — Automatically respects ignore patterns.

## Built-in embedders

| Alias            | Embedder                | Dim  | Chunk default  | Notes                                           |
| ---------------- | ----------------------- | ---- | -------------- | ----------------------------------------------- |
| `bge-base`       | `bge-base-en-v1.5`      |  768 | 1200 / 240     | **Default.** ~440 MB safetensors via swift-embeddings. Best rubric (36/60, 9/10 top-10) on the markdown-memory benchmark — see `experiments/PhaseD-embedder-expansion/plan.md`. |
| `bge-small`      | `bge-small-en-v1.5`     |  384 | 1200 / 240 †   | ~130 MB safetensors. Fastest of the BGE family per chunk (~1.5× bge-base on the same corpus). Single-point rubric at 1200/240: 25/60 — but the chunk geometry is not tuned yet (E5.4). |
| `bge-large`      | `bge-large-en-v1.5`     | 1024 | 1200 / 240 †   | ~1.3 GB safetensors. Deepest BGE available; ~5× slower than bge-base per chunk. Single-point rubric at 1200/240: 31/60 — also not tuned yet (E5.4). |
| `nomic`          | `nomic-v1.5-768`        |  768 | 1200 / 240     | ~520 MB safetensors. Comparable per-chunk throughput to bge-base; trails on top-10 hit rate. |
| `nl-contextual`  | `nl-contextual-en-512`  |  512 | 1200 / 240     | Apple `NLContextualEmbedding`. Zero install size (system-managed via `requestAssets`); ~6× faster per chunk than bge-base/nomic, but rubric is shallow on the test corpus. |
| `nl`             | `nl-en-512`             |  512 | 2000 / 200     | Apple `NLEmbedding.sentenceEmbedding`. Bundled with the OS; useful as a no-install fallback but the weakest on retrieval quality. |

† `bge-small` and `bge-large` defaults are seeded from `bge-base` for
direct rubric comparability. Their real chunk peaks have not yet been
measured; the E5.4 parameter sweep (in progress) will replace these
with tuned values.

Detailed per-model rubric / throughput / install-size table lives in `experiments/PhaseD-embedder-expansion/plan.md` §"Final comparison".

## Installation

### With [Mint](https://github.com/yonaskolb/Mint)

```bash
mint install adamwulf/vec@main --force
```

### From source

```bash
git clone https://github.com/adamwulf/vec.git
cd vec
swift build -c release
cp .build/release/vec /usr/local/bin/
```

## Usage

### Initialize a vector database

```bash
cd /path/to/your/project
vec init my-project
```

This creates a `~/.vec/my-project/` directory containing `config.json` and the SQLite vector database. Vectors are not written until you run `vec update-index`, where the embedder profile is chosen and locked onto the DB.

Options:
- `--force` — Overwrite an existing database with the same name.

### List all databases

```bash
vec list
```

Shows all databases with their name, source directory, and indexed file count. Warns if a source directory no longer exists. The file count includes files that produced zero chunks (genuinely empty, whitespace-only, binary read as text, malformed-but-readable PDFs); those files are recorded in the index with `linePageCount: 0` so they aren't re-extracted on every `update-index` run.

### Update the index

```bash
vec update-index --db my-project
```

Re-scans the source directory for new, modified, or deleted files and updates the index. Re-uses the embedder profile recorded on the DB; passing a mismatched `--embedder` flag refuses with a clear error (run `vec reset` first to re-index at a different profile). Omit `--db` to resolve the DB from the current directory.

Options:
- `--embedder <alias>` — Required only on the first index of a fresh DB; refused if a different profile is already recorded. Defaults to `bge-base` on first index.
- `--chunk-chars <N>` / `--chunk-overlap <N>` — Override chunk parameters; pass both or neither. Same first-index/recorded-profile caveat as `--embedder`.
- `--allow-hidden` — Include hidden files and folders.
- `--verbose` / `-v` — Print per-stage timings, throughput, pool utilization, and per-file slow-list. Includes a `[verbose-stats]` one-liner suitable for grep/awk/python.

After every run (success, partial-success, *and* silent-failure), `update-index` appends a one-line JSON record to `~/.vec/<db>/index.log` capturing the timestamp, embedder alias and full profile identity, wall time, file counts (scanned/added/updated/removed/unchanged), and the relative paths of every file that was skipped (`skippedUnreadable` or `skippedEmbedFailures`). Files that were indexed but lost some chunks to embed failures are recorded in `partialEmbedFailures` as `{path, failedChunks, totalChunks}` objects (the file IS in the DB with the surviving chunks; this field exists for audit when partial loss occurs). The log is capped at the most recent 200 records — older entries are dropped on the next write. If the log write itself fails (e.g. the file's location is unwritable), `update-index` exits with its normal status and prints `Warning: failed to write index.log: <reason>` to stderr; logging is best-effort and never affects the command's exit code.

To opt in to Markdown extraction, index a fresh or reset database with `vec update-index --db my-project --text-extraction markdown-v1`. Markdown links and images contribute their visible text instead of their destinations; code, bare URLs, frontmatter, and source-line locations are preserved. Reference definition lines and emphasis markers remain literal in this version. Other file formats keep their existing extraction. The default is `raw`. Extraction mode is recorded with the database profile and shown by `vec info`; subsequent updates and single-file inserts reuse it. To change modes, reset and re-index. See [the E10 report](experiments/E10-markdown-extraction/report.md) for the measured comparison and limitations.

#### WebVTT extraction (`vtt-v1`)

For a fresh or reset database, run `vec update-index --db my-project --text-extraction vtt-v1`. WebVTT headers, cue identifiers, timing/settings lines, NOTE/STYLE/REGION blocks, and inline tags are removed before chunking. Supported character references are decoded, speaker names are kept, and adjacent cues become readable paragraphs with conservative rolling-caption deduplication. Malformed blocks are skipped; headerless cues, indented timing lines, and missing blank cue separators are supported.

For a mixed Markdown/caption corpus, use `--text-extraction markdown-v1+vtt-v1` to apply both versioned normalizers. `vtt-v1` alone changes only `.vtt` extraction. Raw remains the default; the database records the chosen mode, updates and inserts inherit it, and changing modes requires reset/reindexing.

Chunks retain coarse source cue line ranges, including the first timing line, so results remain traceable to the caption file. Timestamp metadata is not added to the schema. See the [E11 plan](experiments/E11-vtt-extraction/plan.md) for the extraction rules. In a frozen 16-file sample (1 real, 15 synthetic), correct-file-at-rank-1 improved from 14/15 to 15/15, MRR from 0.956 to 1.000, and chunk count fell from 205 to 88; timestamp/tag noise in extracted chunks fell from 100% to 0%. The only rank improvement was on a synthetic file, so this does not establish an accuracy gain across the full corpus. See the [measured report and provenance](experiments/E11-vtt-extraction/report.md).

#### Image OCR (`image-ocr-v1`)

Index recognized image text on a fresh or reset database:

```bash
vec update-index --db my-project --text-extraction image-ocr-v1 --ocr-concurrency 4
```

Image discovery and OCR are opt-in. Combine with the existing normalizers in
canonical order: `markdown-v1+image-ocr-v1`, `vtt-v1+image-ocr-v1`, or
`markdown-v1+vtt-v1+image-ocr-v1`. The database records this mode; updates and
single-file inserts inherit it. Changing modes requires reset and reindexing.
Raw and the earlier text-only modes skip images, including SVG.

Apple Vision recognizes text locally with accurate recognition, language
correction, and automatic language detection. ImageIO decodes JPEG/JPG, PNG,
WebP, GIF (first frame), HEIC, TIFF/TIF, and BMP. AVIF is discovered only if
ImageIO advertises a decoder on the current Mac. SVG is skipped; rasterize it
externally to index its visible text. Recognized lines are ordered top to
bottom and left to right and joined into paragraphs before the active chunker
runs. Blank images produce no chunks. Image chunks have no source line
numbers; the existing chunk schema has no pixel-size or confidence fields.

Recognized text is cached alongside the database using the image content hash
and OCR version, including empty results. Unchanged files skip extraction via
normal modification-date tracking; changed or reinserted identical bytes can
reuse cached OCR. Reset removes the cache with the database. `--ocr-concurrency`
(default 1) bounds simultaneous image jobs independently of embedding
`--concurrency`; each image releases temporary decoding and Vision objects
inside an autorelease pool. Frames are downscaled to a maximum edge of 4,096
pixels; tiny text in very large images can be lost. A 4,096 × 4,096 RGBA
frame alone uses about 64 MiB per job, in addition to Vision working memory.
Start with 1–4 jobs and use the E12 measurements to choose a value that fits
available memory. Undecodable or unreadable images are retried on later updates
rather than cached as blank; permanently corrupt images can therefore incur
repeated decode attempts.

E12 measured 6.85 / 10.34 / 11.27 images per second at 1 / 4 / 8 OCR jobs on a deterministic 153-image real sample (240–275 MiB peak process RSS). That implies about 13.2 / 8.7 / 8.0 hours of OCR for 325,000 similar images, excluding embedding and database writes. A separate 18-image sample dominated by dense synthetic text took 112–133 extrapolated hours. These are sample-dependent estimates, not a full-corpus forecast. On the frozen 15-query retrieval rubric, OCR reached hit@1 14/15, hit@5 15/15, and MRR 0.967; the baseline had no image chunks, and 11 queries targeted synthetic images.

See the [E12 plan](experiments/E12-image-ocr/plan.md) and
[measurement report](experiments/E12-image-ocr/report.md) for the frozen sample,
retrieval scores, throughput, memory observations, and synthetic-sample limits.

#### PDF OCR (`pdf-ocr-v1`)

The default `raw` mode indexes only a PDF's embedded text. Opt into rendered
page OCR when PDFs may contain scans, diagrams, screenshots, or mixed native
and raster text:

```bash
vec update-index --db my-project --text-extraction pdf-ocr-v1 --ocr-concurrency 2
```

Every page is OCR'd even when it also has embedded text. Native PDF text is
preserved as authoritative; OCR copies are conservatively deduplicated while
distinct raster-only lines remain. Page chunks retain 1-based page numbers.
Reading order uses crop- and rotation-aware geometry, with a lossless
native-first fallback for unusual PDFs whose character bounds cannot fully
reconstruct their text layer. Blank pages produce no chunks.

Combine components in canonical Markdown, VTT, image, PDF order, for example
`markdown-v1+pdf-ocr-v1`, `image-ocr-v1+pdf-ocr-v1`, or
`markdown-v1+vtt-v1+image-ocr-v1+pdf-ocr-v1`. Changing the recorded extraction
mode requires reset/reindexing. PDF page OCR shares `--ocr-concurrency` with
raster-image OCR, renders one page at a time per document, caps the longest
edge at 4,096 pixels at a requested 144 dpi, and releases each page bitmap in
an autorelease pool. Sidecars are keyed by PDF content hash, extraction/Vision
version, page number, and render settings; successful blank results are cached,
while failures are retried.

See the [E13 plan](experiments/E13-pdf-extraction/plan.md) and
[reader validation](experiments/E13-pdf-extraction/report.md) for test coverage,
bounded cold/warm measurements, and synthetic limitations.

### Search

```bash
vec search --db my-project "how does authentication work"
```

Returns matching files ranked by semantic similarity, with line ranges when available:

```
src/auth/middleware.swift:12-58  (0.92)
docs/authentication.md:1-45     (0.87)
README.md:120-165               (0.81)
```

Options:
- `--db <name>` / `-d <name>` — Database name. Omit to resolve from the current directory.
- `--limit <N>` / `-l <N>` — Maximum number of results (default: 10).
- `--preview` / `-p` — Include a content preview for each result.
- `--format <text|json>` — Output format (default: text).
- `--show <lines|chunks>` — Render text chunks as line ranges or chunk indices.
- `--glob <pattern>` — Filter results to files whose basename matches the glob.
- `--min-lines <N>` — Only include files with at least N lines / PDF pages.

#### Default subcommand shorthand

`search` is the default subcommand, so you can omit it:

```bash
vec --db my-project "how does authentication work"
```

### Add a specific file

```bash
vec insert --db my-project path/to/file.md
```

Indexes a specific file. The path must be within the database's source directory.

### Remove a file from the index

```bash
vec remove --db my-project path/to/file.md
```

Removes all embeddings for a file from the index.

### Reset a database

```bash
vec reset --db my-project
```

Deletes and recreates the database, preserving the source directory mapping. The next `vec update-index` can then pick a different embedder. Use `--force` to skip the confirmation prompt.

## Supported File Types

| Type | Indexing Strategy |
|------|-------------------|
| Markdown (`.md`) | Recursive character-bounded chunks (optional `markdown-v1` normalization) |
| WebVTT (`.vtt`) | Whole-document and recursive chunks; optional `vtt-v1` prose normalization |
| Swift (`.swift`) | Whole file |
| Plain text (`.txt`) | Whole file |
| PDF (`.pdf`) | Per-page text extraction |
| Raster images | Recognized text chunks; requires `image-ocr-v1` (see format list above) |
| SVG | Skipped |
| Other text files | Whole file (if detected as text) |
| Binary files | Skipped |

## How It Works

1. **Embedding**: Each chunk is embedded by the profile's embedder. BGE/Nomic load via `swift-embeddings` and run on-device through CoreML (BNNS-accelerated); the NL family uses Apple's NaturalLanguage framework. All processing happens entirely on-device.

2. **Storage**: Embeddings are stored as raw Float32 blobs in a SQLite database. Similarity search is computed in pure Swift using cosine distance.

3. **Search**: Query text is embedded with the same profile recorded on the DB, then compared against stored embeddings using cosine distance.

4. **Change tracking**: Each indexed chunk stores the source file path, line range, and file modification date. On `update-index`, only files with changed modification dates are re-indexed.

## Database Location

Each named database is stored under `~/.vec/<db-name>/`, containing:
- `config.json` — Source directory path, creation date, and recorded embedder profile.
- `index.db` — The SQLite vector database.

Database names may contain letters, numbers, hyphens, and underscores.

## Requirements

- macOS 13.0+
- Swift 5.9+

## License

MIT
