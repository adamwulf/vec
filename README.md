# vec

A command-line tool for creating and querying local vector databases, powered by [sqlite-vector](https://github.com/sqliteai/sqlite-vector) and Apple's `NLEmbedding`.

## Overview

`vec` indexes the text content of files in a directory into a local vector database stored in `.vec/` at the project root. It uses Apple's on-device `NLEmbedding` (from the NaturalLanguage framework) to generate sentence embeddings — no API keys or network access required.

Once indexed, you can perform semantic search across your files to find relevant content by meaning, not just keywords.

## Features

- **On-device embeddings** — Uses Apple's `NLEmbedding.sentenceEmbedding(for:)` for fast, private, offline vector generation
- **Chunked indexing** — Markdown files are split into ~50-line overlapping chunks for fine-grained search results
- **Whole-document embeddings** — Each file also gets a full-document embedding for broader matches
- **PDF support** — Extracts text per page from PDFs and indexes each page separately
- **Change detection** — Tracks file modification dates to efficiently update only changed files
- **SQLite-backed** — Uses sqlite-vector for high-performance vector similarity search

## Installation

### With [Mint](https://github.com/yonaskolb/Mint)

```bash
mint install adamwulf/vec
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
vec init
```

This creates a `.vec/` directory containing the SQLite vector database and indexes all supported files in the current directory.

### Update the index

```bash
vec update-index
```

Re-scans the directory for new, modified, or deleted files and updates the index accordingly.

### Search

```bash
vec search "how does authentication work"
```

Returns matching files ranked by semantic similarity, with line ranges when available:

```
src/auth/middleware.swift:12-58  (0.92)
docs/authentication.md:1-45     (0.87)
README.md:120-165               (0.81)
```

### Add a specific file

```bash
vec insert path/to/file.md
```

Indexes a specific file. The path must be within the project directory.

### Remove a file from the index

```bash
vec remove path/to/file.md
```

Removes all embeddings for a file from the index.

## Supported File Types

| Type | Indexing Strategy |
|------|-------------------|
| Markdown (`.md`) | ~50-line overlapping chunks + whole document |
| Swift (`.swift`) | Whole file |
| Plain text (`.txt`) | Whole file |
| PDF (`.pdf`) | Per-page text extraction |
| Other text files | Whole file (if detected as text) |
| Binary files | Skipped |

## How It Works

1. **Embedding**: Text content is converted to vector embeddings using `NLEmbedding.sentenceEmbedding(for:revision:)` from Apple's NaturalLanguage framework. This produces 512-dimensional vectors entirely on-device.

2. **Storage**: Embeddings are stored in a SQLite database using the sqlite-vector extension, which provides SIMD-accelerated similarity search.

3. **Search**: Query text is embedded using the same model, then compared against stored embeddings using cosine distance to find the most semantically similar content.

4. **Change tracking**: Each indexed chunk stores the source file path, line range, and file modification date. On `update-index`, only files with changed modification dates are re-indexed.

## Database Location

The vector database is stored in `.vec/index.db` within the project directory. Add `.vec/` to your `.gitignore`.

## Requirements

- macOS 13.0+
- Swift 5.9+

## License

MIT
