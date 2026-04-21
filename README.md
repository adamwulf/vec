# vec

A command-line tool for creating and querying local vector databases, powered by SQLite and a pluggable on-device embedder pipeline.

## Overview

`vec` indexes the text content of files in a directory into a named vector database stored under `~/.vec/<db-name>/`. The embedder is pluggable — choose between Apple's NaturalLanguage framework and locally-hosted transformer models (BGE, Nomic) via the `--embedder` flag. The current default is `bge-base` (768-dim BERT-family, ~440 MB on first download). All embedding happens on-device — no API keys or network calls at query time.

Once indexed, you can perform semantic search across your files to find relevant content by meaning, not just keywords.

## Features

- **On-device embeddings** — Choose from four built-in embedders (see below); all run locally with no network round-trip at query time.
- **Pluggable embedder profiles** — `--embedder <alias>` selects the model. The model + chunking parameters are recorded as a profile identity on the DB and re-used on every subsequent command, so a database always re-uses the same embedder it was built with. See `indexing-profile.md` for the grammar.
- **Batched embedding** — The indexing pipeline batches chunks for the BERT-family embedders (BGE, Nomic) via `swift-embeddings` `batchEncode`, with an `EmbedderPool` actor that holds N model instances for real parallel inference.
- **Chunked indexing** — Text is split into overlapping character-bounded chunks via `RecursiveCharacterSplitter` (a port of LangChain's recursive character splitter).
- **PDF support** — Extracts text per page from PDFs and indexes each page separately.
- **Change detection** — Tracks file modification dates to efficiently update only changed files.
- **SQLite-backed** — Stores embeddings as raw Float32 blobs; cosine-similarity search is pure Swift (no dynamic libraries).
- **`.gitignore` / `.vecignore` support** — Automatically respects ignore patterns.

## Built-in embedders

| Alias            | Embedder                | Dim | Chunk default | Notes                                           |
| ---------------- | ----------------------- | --- | ------------- | ----------------------------------------------- |
| `bge-base`       | `bge-base-en-v1.5`      | 768 | 1200 / 240    | **Default.** ~440 MB safetensors via swift-embeddings. Best rubric (36/60, 9/10 top-10) on the markdown-memory benchmark — see `embedder-expansion-plan.md`. |
| `nomic`          | `nomic-v1.5-768`        | 768 | 1200 / 240    | ~520 MB safetensors. Comparable per-chunk throughput to bge-base; trails on top-10 hit rate. |
| `nl-contextual`  | `nl-contextual-en-512`  | 512 | 1200 / 240    | Apple `NLContextualEmbedding`. Zero install size (system-managed via `requestAssets`); ~6× faster per chunk than bge-base/nomic, but rubric is shallow on the test corpus. |
| `nl`             | `nl-en-512`             | 512 | 2000 / 200    | Apple `NLEmbedding.sentenceEmbedding`. Bundled with the OS; useful as a no-install fallback but the weakest on retrieval quality. |

Detailed per-model rubric / throughput / install-size table lives in `embedder-expansion-plan.md` §"Final comparison".

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

Shows all databases with their name, source directory, and indexed file count. Warns if a source directory no longer exists.

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
| Markdown (`.md`) | Recursive character-bounded chunks |
| Swift (`.swift`) | Whole file |
| Plain text (`.txt`) | Whole file |
| PDF (`.pdf`) | Per-page text extraction |
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
