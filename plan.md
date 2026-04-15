# vec — Status & Plan

## Current State

The `vec` CLI tool and its `VecKit` library are structurally complete. All five commands are implemented, the project builds cleanly, and 53 tests pass across 8 test suites. The embedding service uses Apple's on-device `NLEmbedding`. The `sqlite-vector` package is integrated via SPM binary target with runtime extension loading.

### What's Implemented

| Component | Status | Notes |
|-----------|--------|-------|
| `vec init` | Done | Creates `.vec/index.db`, scans + indexes all files. `--force` flag works. |
| `vec update-index` | Done | Adds new, re-indexes modified, removes deleted files. |
| `vec search <query>` | Done | Vector similarity search. `--limit`, `-l`, and `--include-preview` flags. |
| `vec insert <path>` | Done | Adds/replaces a single file. Path validation included. |
| `vec remove <path>` | Done | Removes entries for a single file. |
| `VectorDatabase` | Done | SQLite + sqlite-vector wrapper. Insert, search, remove, allIndexedFiles. |
| `EmbeddingService` | Done | Uses `NLEmbedding.sentenceEmbedding(for: .english)`, 512 dimensions. |
| `FileScanner` | Done | Directory walking, skips .git/node_modules/.build/etc, binary detection. |
| `TextExtractor` | Done | Plain text (whole-doc), markdown (overlapping chunks), PDF (per-page). |
| `CSQLiteVec` | Done | System library shim for sqlite3 C API access. |

### What's Tested (53 tests passing)

| Test Suite | Count | Coverage |
|-----------|-------|----------|
| `VecKitTests` | 3 | `ChunkType` raw values, `TextChunk` construction |
| `EmbeddingServiceTests` | 4 | Real embeddings, empty/whitespace input, dimension check |
| `TextExtractorTests` | 5 | Large/small markdown, txt files, empty/whitespace files |
| `FileScannerTests` | 4 | .git skipping, binary detection, node_modules, relative paths |
| `ChunkingStrategyTests` | 3 | Overlap behavior, heading boundaries, custom chunk/overlap sizes |
| `VectorDatabaseTests` | 16 | Initialize, open, insert, search (ordering, similarity, limit, fields), allIndexedFiles, removeEntries, multi-file scenarios |
| `IntegrationTests` | 6 | Full scan+embed+store+search pipeline, update-index flows (modified/deleted/added files), insert-then-search, remove-then-search |
| `CLITests` | 12 | Subcommand registration, argument parsing for all 5 commands, default values, flag parsing, short flags |

---

## What's Left

### Priority 1: Must-fix before production use

#### 1a. `.gitignore` support
`FileScanner` does NOT respect `.gitignore`. It only skips hardcoded directory names (`.git`, `node_modules`, etc.) and hidden files. Run `vec init` in any real repo and it will index `build/`, `DerivedData/`, generated files, vendored dependencies — anything not in the hardcoded skip list. The index will be bloated with junk and search results will be noisy.

**Files to change:** `Sources/VecKit/FileScanner.swift`
**Approach:** Parse `.gitignore` (and nested `.gitignore` files) at scan time. Use `git check-ignore` or implement glob pattern matching. Also consider `.vecignore` for vec-specific exclusions. Hidden files/folders (dotfiles like `.env`, `.config/`) should be skipped by default — already partially done via `skipsHiddenFiles` in the enumerator, but should be explicit and overridable.
**New flag:** `--allow-hidden` on `init` and `update-index` commands to opt-in to indexing hidden files/folders.
**Tests needed:** FileScanner tests verifying that gitignored files are excluded from scan results. Tests verifying hidden files are skipped by default and included with `--allow-hidden`.

#### 1b. Path computation crash risk
`InsertCommand` and `RemoveCommand` both compute relative paths with:
```swift
String(filePath.path.dropFirst(directory.path.count + 1))
```
This assumes the directory path doesn't have a trailing slash and that `+ 1` correctly accounts for the `/` separator. If the path math goes wrong (trailing slashes, symlinks, root-level files), this will crash or produce wrong paths.

**Files to change:** `Sources/vec/Commands/InsertCommand.swift`, `Sources/vec/Commands/RemoveCommand.swift`
**Approach:** Use a shared helper that safely computes relative paths, or use `FileScanner.fileInfo(for:relativeTo:)` which already handles this correctly.
**Tests needed:** CLI or unit tests with edge-case paths (trailing slashes, symlinks, already-relative paths).

#### 1c. Silent failures — no warnings for skipped files
- `TextExtractor.extract()` silently returns `[]` if a file can't be read as UTF-8 — no warning.
- `EmbeddingService.embed()` returns nil for un-embeddable text — callers silently skip with `guard let ... else { continue }`.
- You'll run `vec init`, see "Indexed 50 files", and have no idea that 20 files were silently dropped.

**Files to change:** `Sources/vec/Commands/InitCommand.swift`, `Sources/vec/Commands/UpdateIndexCommand.swift`, `Sources/vec/Commands/InsertCommand.swift`
**Approach:** Add a warnings counter and print a summary at the end (e.g., "Indexed 50 files (3 skipped: 2 unreadable, 1 failed to embed)"). Optionally `--verbose` to list each skipped file.

### Priority 2: Should-fix (quality / correctness)

#### 2a. Duplicated insert logic in UpdateIndexCommand
The "new file" and "updated file" branches in `UpdateIndexCommand.swift:30-71` are identical copy-pasted code. Should be extracted to a shared helper method.

**Files to change:** `Sources/vec/Commands/UpdateIndexCommand.swift`

#### 2b. Dead code in extension loading
`VectorDatabase.loadVectorExtension()` includes `@rpath/vector.framework/vector` as a literal string in the candidate paths. This won't resolve at the SQLite level — it's dead code that adds confusion.

**Files to change:** `Sources/VecKit/VectorDatabase.swift` (line ~219)

#### 2c. Similarity score display may be incorrect
`SearchCommand` displays `1.0 - distance` as a similarity score, but sqlite-vector's cosine distance range needs verification. Could show negative scores or values > 1 depending on the distance metric.

**Files to change:** `Sources/vec/Commands/SearchCommand.swift`
**Verification needed:** Check sqlite-vector docs for cosine distance range.

### Priority 3: Nice-to-have (not blocking)

#### 3a. Edge case tests
- PDF extraction — zero tests exist
- Files with special characters in names (spaces, unicode)
- Markdown edge cases (only headings, every line a heading, very long single line)
- Non-English text embedding behavior
- Empty directory scan
- Symlink behavior

#### 3b. Missing features from original plan
- `--format json` for `search` command (useful for scripting)
- Result grouping — show best match per file instead of all chunks
- `--verbose` / `--quiet` flags on all commands
- `.vecignore` support for vec-specific exclusions
- `vector_quantize()` after updates for better search performance

#### 3c. Error handling improvements
- `VectorDatabase.open()` doesn't verify schema integrity or that the vector extension loads — a corrupted DB will fail on first query, not on open.
