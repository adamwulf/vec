# vec — Implementation Plan

## Architecture

Following the same pattern as the `hunch` CLI tool:

```
vec/
├── Package.swift
├── README.md
├── plan.md
├── Sources/
│   ├── vec/                          # Executable target
│   │   ├── Vec.swift                 # @main entry point, CommandConfiguration
│   │   └── Commands/
│   │       ├── InitCommand.swift     # vec init
│   │       ├── UpdateIndexCommand.swift  # vec update-index
│   │       ├── SearchCommand.swift   # vec search "query"
│   │       ├── InsertCommand.swift   # vec insert <path>
│   │       └── RemoveCommand.swift   # vec remove <path>
│   └── VecKit/                       # Library target
│       ├── VectorDatabase.swift      # SQLite + sqlite-vector wrapper
│       ├── EmbeddingService.swift    # NLEmbedding wrapper
│       ├── FileScanner.swift         # Directory walking, file type detection
│       ├── TextExtractor.swift       # Text extraction (plain text, markdown, PDF)
│       ├── ChunkingStrategy.swift    # Markdown chunking logic
│       └── Models/
│           ├── IndexEntry.swift      # File path, line range, mod date, embedding
│           └── SearchResult.swift    # Ranked result with distance
└── Tests/
    ├── VecKitTests/
    └── CLITests/
```

## Dependencies

| Dependency | Purpose |
|-----------|---------|
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | CLI argument parsing and subcommand routing |
| [sqlite-vector](https://github.com/sqliteai/sqlite-vector) | Vector similarity search in SQLite |
| NaturalLanguage (system framework) | `NLEmbedding` for on-device sentence embeddings |
| PDFKit (system framework) | PDF text extraction |

### sqlite-vector Integration

sqlite-vector distributes an Apple xcframework (`vector-apple-xcframework-*.zip`) from their GitHub releases. We have a few options for integration:

1. **Vendored xcframework** — Download the xcframework and include it in the repo. Simple but adds binary to git.
2. **Binary target in Package.swift** — Use SPM's `.binaryTarget(url:checksum:)` to fetch the xcframework from GitHub releases at build time.
3. **System SQLite extension** — Build sqlite-vector from source and load it as a dynamic extension via `sqlite3_load_extension()`.

**Recommended: Option 2** (binary target) for clean SPM integration, falling back to Option 3 if needed.

For the SQLite database itself, we can use the system SQLite via the `CSQLite` system library target or a Swift SQLite wrapper.

## Package.swift Structure

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "vec",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "VecKit", targets: ["VecKit"]),
        .executable(name: "vec", targets: ["vec"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        // sqlite-vector Swift package or binary target TBD
    ],
    targets: [
        .target(
            name: "VecKit",
            dependencies: [
                // sqlite-vector dependency
            ]
        ),
        .executableTarget(
            name: "vec",
            dependencies: [
                "VecKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .testTarget(name: "VecKitTests", dependencies: ["VecKit"]),
        .testTarget(name: "CLITests", dependencies: [
            "vec",
            .product(name: "ArgumentParser", package: "swift-argument-parser")
        ])
    ]
)
```

## Command Details

### `vec init`

1. Check if `.vec/` already exists — warn and exit if so (unless `--force`)
2. Create `.vec/` directory
3. Create SQLite database at `.vec/index.db`
4. Initialize sqlite-vector extension
5. Create the embeddings table:
   ```sql
   CREATE TABLE IF NOT EXISTS chunks (
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       file_path TEXT NOT NULL,
       line_start INTEGER,        -- NULL for whole-document embeddings
       line_end INTEGER,          -- NULL for whole-document embeddings
       chunk_type TEXT NOT NULL,   -- 'whole', 'chunk', 'pdf_page'
       page_number INTEGER,       -- For PDF pages
       file_modified_at REAL NOT NULL,  -- Unix timestamp
       content_preview TEXT,      -- First ~200 chars for display
       embedding BLOB NOT NULL
   );
   CREATE INDEX idx_chunks_file_path ON chunks(file_path);

   SELECT vector_init('chunks', 'embedding', 'dimension=512,type=FLOAT32,distance=cosine');
   ```
6. Scan all files in the directory (respecting `.gitignore` if present)
7. For each supported file, generate embeddings and insert

### `vec update-index`

1. Open existing database (error if not initialized)
2. Scan all files in the directory
3. For each file:
   - If not in index → insert embeddings
   - If in index but modification date changed → delete old entries, insert new
   - If in index and unchanged → skip
4. For indexed files no longer on disk → delete entries
5. Re-run `vector_quantize()` after updates

### `vec search "query"`

1. Open existing database (error if not initialized)
2. Generate embedding for the query string using `NLEmbedding`
3. Run vector similarity search:
   ```sql
   SELECT c.file_path, c.line_start, c.line_end, c.chunk_type, c.content_preview, v.distance
   FROM chunks AS c
   JOIN vector_full_scan('chunks', 'embedding', ?, 20) AS v
   ON c.id = v.rowid
   ORDER BY v.distance ASC;
   ```
4. Group results by file, show best match per file with line range
5. Output format: `file_path:line_start-line_end  (similarity_score)`

Options:
- `--limit N` — Maximum number of results (default: 10)
- `--format` — Output format: `text` (default), `json`
- `--include-preview` — Show content preview snippet

### `vec insert <path>`

1. Validate path is within the project directory
2. Open existing database
3. Remove any existing entries for this file
4. Generate embeddings and insert
5. Re-quantize if using quantized search

### `vec remove <path>`

1. Validate path is within the project directory
2. Open existing database
3. Delete all entries for this file path
4. Re-quantize if using quantized search

## Embedding Strategy

### NLEmbedding Details

- Framework: `NaturalLanguage`
- Method: `NLEmbedding.sentenceEmbedding(for: .english, revision: 1)`
- Dimension: 512 (Float32)
- Fully on-device, no network required
- Language: Start with `.english`, could support auto-detection later

### Chunking (Markdown)

For markdown files, split into overlapping chunks:
- **Chunk size**: ~50 lines
- **Overlap**: 10 lines (so chunk 1 = lines 1-50, chunk 2 = lines 41-90, etc.)
- **Respect boundaries**: Try to split at heading boundaries (`#`, `##`, etc.) when near the target chunk size
- Each chunk gets its own embedding
- The whole document also gets a single embedding

### PDF Extraction

- Use `PDFKit` (`PDFDocument`, `PDFPage`)
- Extract text per page via `page.string`
- Each page gets its own embedding with `page_number` stored
- Store concatenated text as whole-document embedding too (if not too long)

### Text Detection

- Use UTI/file extension to determine if a file is text
- Known text extensions: `.md`, `.txt`, `.swift`, `.py`, `.js`, `.ts`, `.json`, `.yaml`, `.yml`, `.toml`, `.xml`, `.html`, `.css`, `.sh`, `.bash`, `.zsh`, `.rb`, `.go`, `.rs`, `.c`, `.h`, `.cpp`, `.hpp`, `.java`, `.kt`, `.scala`, `.r`, `.sql`, `.dockerfile`, `.makefile`, `.cmake`, `.env`, `.ini`, `.cfg`, `.conf`, `.log`
- PDF handled specially via PDFKit
- All other files: attempt to read as UTF-8, skip if it fails

## Implementation Phases

### Phase 1: Foundation
- [ ] Package.swift with all targets and dependencies
- [ ] VecKit: `VectorDatabase` — SQLite wrapper with sqlite-vector extension loading
- [ ] VecKit: `EmbeddingService` — NLEmbedding wrapper
- [ ] CLI: `Vec.swift` entry point with command configuration

### Phase 2: Core Commands
- [ ] VecKit: `FileScanner` — directory walking with gitignore support
- [ ] VecKit: `TextExtractor` — plain text and markdown extraction
- [ ] VecKit: `ChunkingStrategy` — markdown chunking
- [ ] CLI: `InitCommand` — create database, index all files
- [ ] CLI: `SearchCommand` — query and display results

### Phase 3: Management Commands
- [ ] CLI: `UpdateIndexCommand` — incremental re-indexing
- [ ] CLI: `InsertCommand` — add single file
- [ ] CLI: `RemoveCommand` — remove single file

### Phase 4: PDF + Polish
- [ ] VecKit: PDF text extraction via PDFKit
- [ ] Progress output during indexing
- [ ] Respect `.gitignore` and `.vecignore`
- [ ] Error handling and user-friendly messages

### Phase 5: Tests
- [ ] VecKitTests: embedding service, chunking, file scanning
- [ ] CLITests: command parsing, path validation

## Open Questions

1. **sqlite-vector distribution**: Should we vendor the xcframework, use a binary SPM target, or build from source? Need to test which approach works best for a CLI tool (not an app bundle).
   - For a CLI tool, the xcframework approach may not work since there's no app bundle. We may need to compile sqlite-vector from source as a C target or use `sqlite3_load_extension()` with a dylib.

2. **NLEmbedding dimensions**: Need to verify the exact dimension of `.sentenceEmbedding(for: .english)` at runtime. Documentation suggests 512 but this should be confirmed.

3. **Large files**: Should we cap file size for embedding? NLEmbedding may truncate very long inputs. Need to determine the practical limit.

4. **Concurrency**: Should indexing be parallelized? `NLEmbedding` is thread-safe but we need to be careful with SQLite writes.

5. **`.vecignore`**: Should we support a custom ignore file in addition to `.gitignore`?
