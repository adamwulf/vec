# vec — Status & Plan

## Current State

The `vec` CLI tool and its `VecKit` library are structurally complete. All five commands are implemented, the project builds cleanly, and 20 tests pass. The embedding service uses Apple's on-device `NLEmbedding` (not a stub). The `sqlite-vector` package is integrated via SPM binary target with runtime extension loading.

### What's Implemented

| Component | Status | Notes |
|-----------|--------|-------|
| `vec init` | Done | Creates `.vec/index.db`, scans + indexes all files. `--force` flag works. |
| `vec update-index` | Done | Adds new, re-indexes modified, removes deleted files. |
| `vec search <query>` | Done | Vector similarity search. `--limit` and `--include-preview` flags. |
| `vec insert <path>` | Done | Adds/replaces a single file. Path validation included. |
| `vec remove <path>` | Done | Removes entries for a single file. |
| `VectorDatabase` | Done | SQLite + sqlite-vector wrapper. Insert, search, remove, allIndexedFiles. |
| `EmbeddingService` | Done | Uses `NLEmbedding.sentenceEmbedding(for: .english)`, 512 dimensions. |
| `FileScanner` | Done | Directory walking, skips .git/node_modules/.build/etc, binary detection. |
| `TextExtractor` | Done | Plain text (whole-doc), markdown (overlapping chunks), PDF (per-page). |
| `CSQLiteVec` | Done | System library shim for sqlite3 C API access. |

### What's Tested (20 tests passing)

| Test Suite | Count | Coverage |
|-----------|-------|----------|
| `VecKitTests` | 3 | `ChunkType` raw values, `TextChunk` construction |
| `EmbeddingServiceTests` | 4 | Real embeddings, empty/whitespace input, dimension check |
| `TextExtractorTests` | 5 | Large/small markdown, txt files, empty/whitespace files |
| `FileScannerTests` | 4 | .git skipping, binary detection, node_modules, relative paths |
| `ChunkingStrategyTests` | 3 | Overlap behavior, heading boundaries, custom chunk/overlap sizes |
| `CLITests` | 1 | **Placeholder only** (`XCTAssertTrue(true)`) |

---

## What's Missing

### 1. VectorDatabase Tests (Critical Gap)

The most complex and important component has **zero test coverage**. Needs tests for:

- [ ] `initialize()` — creates `.vec/` dir, opens DB, loads extension, creates schema
- [ ] `open()` — opens existing DB, throws `databaseNotInitialized` when missing
- [ ] `insert()` — inserts a chunk with all fields, returns valid row ID
- [ ] `insert()` with nil optional fields (lineStart, lineEnd, pageNumber)
- [ ] `search()` — returns results ordered by distance
- [ ] `search()` — returns empty array on empty database
- [ ] `search()` — respects the `limit` parameter
- [ ] `search()` — result fields map correctly (filePath, lineStart, lineEnd, chunkType, etc.)
- [ ] `allIndexedFiles()` — returns correct paths and modification dates
- [ ] `allIndexedFiles()` — returns empty dict on empty database
- [ ] `removeEntries(forPath:)` — removes entries and returns count
- [ ] `removeEntries(forPath:)` — returns 0 for non-existent path
- [ ] `deinit` — closes the database cleanly (no leaks)
- [ ] Extension loading — verifies sqlite-vector extension loads and `vector_init` works
- [ ] Schema creation is idempotent (`IF NOT EXISTS`)

### 2. CLI Command Tests (Placeholder)

`CLITests` is entirely a placeholder. Needs tests for:

- [ ] `InitCommand` — creates `.vec/index.db` in target directory
- [ ] `InitCommand --force` — reinitializes existing database
- [ ] `InitCommand` — errors when `.vec/` already exists without `--force`
- [ ] `SearchCommand` — validates query argument is required
- [ ] `SearchCommand --limit` — parses limit option correctly
- [ ] `InsertCommand` — validates path argument is required
- [ ] `InsertCommand` — rejects paths outside project directory
- [ ] `RemoveCommand` — validates path argument is required
- [ ] `RemoveCommand` — rejects paths outside project directory

### 3. Integration Tests (None Exist)

No end-to-end tests exercise the full pipeline:

- [ ] Full pipeline: scan files -> extract text -> embed -> store -> search -> get relevant results
- [ ] Update-index: init, modify a file, run update, verify re-indexed
- [ ] Update-index: init, delete a file, run update, verify removed
- [ ] Update-index: init, add a new file, run update, verify added
- [ ] Insert then search: insert a file, search for its content, verify it appears
- [ ] Remove then search: index a file, remove it, search, verify it's gone

### 4. Edge Case Tests Missing

#### FileScanner
- [ ] Scan an empty directory — returns empty array
- [ ] Files with no extension but text content — detected correctly
- [ ] Symlinks — are they followed or skipped?
- [ ] Very deeply nested directories
- [ ] Files with special characters in names (spaces, unicode)
- [ ] `.vecignore` support (not yet implemented, see below)

#### TextExtractor
- [ ] PDF extraction — no PDF tests exist at all
- [ ] PDF with empty pages
- [ ] PDF with only images (no extractable text)
- [ ] Markdown file with only headings, no body text
- [ ] Markdown file where every line is a heading
- [ ] Very long single line (no newlines)
- [ ] File that fails UTF-8 decoding gracefully

#### EmbeddingService
- [ ] Very long input text — does `NLEmbedding` truncate or fail?
- [ ] Non-English text — returns nil or a vector?
- [ ] Embeddings for similar text are closer than for dissimilar text (sanity check)
- [ ] Thread safety — concurrent calls to `embed()`

#### VectorDatabase
- [ ] Inserting duplicate file paths (same path, different chunks is normal; same path+lineStart is an overwrite?)
- [ ] Very large number of entries (performance)
- [ ] Special characters in file paths and content previews
- [ ] Concurrent read/write access
- [ ] Database file permissions

### 5. Missing Functionality

#### Not yet implemented (mentioned in original plan)
- [ ] `.gitignore` support — `FileScanner` does NOT respect `.gitignore`. It only skips hardcoded directory names (`.git`, `node_modules`, etc.) and hidden files. A repo with custom gitignore patterns (e.g., `build/`, `*.generated.swift`) will index files it shouldn't.
- [ ] `.vecignore` support — custom ignore file for vec-specific exclusions
- [ ] `--format json` for `search` command — original plan mentions it, not implemented
- [ ] `vector_quantize()` after updates — original plan mentions re-quantizing after insert/remove/update, not implemented
- [ ] Result grouping — original plan says "group results by file, show best match per file." Current implementation shows all results ungrouped.

#### Robustness gaps
- [ ] `InsertCommand` path computation — uses `String(filePath.path.dropFirst(directory.path.count + 1))` which will crash if the file is at the root (off-by-one on the `+ 1` for the `/` separator). Same pattern in `RemoveCommand`.
- [ ] `UpdateIndexCommand` has duplicated insert logic — the "new file" and "updated file" branches are identical copy-pasted code. Should be extracted to a shared method.
- [ ] `VectorDatabase.loadVectorExtension()` tries `@rpath/vector.framework/vector` as a literal string path — this won't resolve at the SQLite level. It's dead code.
- [ ] `SearchCommand` displays similarity as `1.0 - distance` but cosine distance from sqlite-vector may not be in [0, 1] range — needs verification.
- [ ] No `--verbose` or `--quiet` flags on any command for controlling output verbosity.
- [ ] No progress indication on `update-index` (the init command has progress, update-index only prints per-file).

#### Error handling gaps
- [ ] `TextExtractor.extract()` silently returns `[]` if the file can't be read as UTF-8 — no warning to the user that a file was skipped.
- [ ] `EmbeddingService.embed()` returns nil for un-embeddable text — callers silently skip with `guard let ... else { continue }`, no warning.
- [ ] `VectorDatabase.open()` doesn't verify the schema is intact or that the vector extension loads correctly — a corrupted DB will fail on first query, not on open.

### 6. Architecture Notes from Original Plan (Resolved)

These open questions from the original plan have been answered by the implementation:

- **sqlite-vector distribution**: Resolved. Using SPM package dependency + runtime `sqlite3_load_extension()` with multiple candidate paths.
- **NLEmbedding dimensions**: Confirmed 512 at runtime via `embedding.dimension`.
- **ChunkingStrategy as separate file**: Not created. Chunking lives inside `TextExtractor`, which is fine for the current complexity.

---

## Suggested Priority Order

1. **VectorDatabase tests** — highest risk, most complex component, zero coverage
2. **Integration tests** — prove the full pipeline works end-to-end
3. **CLI tests** — replace the placeholder with real command parsing/validation tests
4. **Edge case tests** — PDF extraction, special characters, long input, etc.
5. **`.gitignore` support** — functional gap that will cause real user problems
6. **Robustness fixes** — dedup update-index logic, fix path computation, dead code cleanup
7. **Missing features** — `--format json`, result grouping, `--verbose`/`--quiet`
