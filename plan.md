# vec — Status & Plan

## Current State

The `vec` CLI tool and its `VecKit` library are production-ready for all Priority 1 and Priority 2 items. All five commands are implemented, the project builds cleanly, and 72 tests pass across 10 test suites. The embedding service uses Apple's on-device `NLEmbedding`. The `sqlite-vector` package is integrated via SPM binary target with runtime extension loading.

### What's Implemented

| Component | Status | Notes |
|-----------|--------|-------|
| `vec init` | Done | Creates `.vec/index.db`, scans + indexes all files. `--force` and `--allow-hidden` flags. Skip summary for unreadable/failed files. |
| `vec update-index` | Done | Adds new, re-indexes modified, removes deleted files. `--allow-hidden` flag. Skip summary. Deduplicated insert logic via `indexFile()` helper. |
| `vec search <query>` | Done | Vector similarity search. `--limit`, `-l`, and `--include-preview` flags. Score clamped to [0,1]. |
| `vec insert <path>` | Done | Adds/replaces a single file. Path validation with prefix collision fix. Warning when chunks fail to embed. |
| `vec remove <path>` | Done | Removes entries for a single file. Path validation with prefix collision fix. |
| `VectorDatabase` | Done | SQLite + sqlite-vector wrapper. Insert, search, remove, allIndexedFiles. |
| `EmbeddingService` | Done | Uses `NLEmbedding.sentenceEmbedding(for: .english)`, 512 dimensions. |
| `FileScanner` | Done | Directory walking, .gitignore support via `git check-ignore`, hidden file filtering (dot-prefix), skips .git/node_modules/.build/etc, binary detection. Pipe-safe Process I/O. |
| `TextExtractor` | Done | Plain text (whole-doc), markdown (overlapping chunks), PDF (per-page). |
| `PathUtilities` | Done | Safe relative path computation using NSString.standardizingPath. |
| `CSQLiteVec` | Done | System library shim for sqlite3 C API access. |

### What's Tested (72 tests passing)

| Test Suite | Count | Coverage |
|-----------|-------|----------|
| `VecKitTests` | 3 | `ChunkType` raw values, `TextChunk` construction |
| `EmbeddingServiceTests` | 4 | Real embeddings, empty/whitespace input, dimension check |
| `TextExtractorTests` | 5 | Large/small markdown, txt files, empty/whitespace files |
| `FileScannerTests` | 10 | .git skipping, binary detection, node_modules, relative paths, hidden skip/include, .git still skipped when hidden enabled, gitignore filtering, non-git fallback, disable gitignore |
| `PathUtilitiesTests` | 10 | Normal paths, trailing slashes, .., outside directory, same path, root dir, deep nesting, prefix collision |
| `ChunkingStrategyTests` | 3 | Overlap behavior, heading boundaries, custom chunk/overlap sizes |
| `VectorDatabaseTests` | 16 | Initialize, open, insert, search (ordering, similarity, limit, fields), allIndexedFiles, removeEntries, multi-file scenarios |
| `IntegrationTests` | 6 | Full scan+embed+store+search pipeline, update-index flows (modified/deleted/added files), insert-then-search, remove-then-search |
| `CLITests` | 15 | Subcommand registration, argument parsing for all 5 commands, default values, flag parsing, short flags, --allow-hidden |

---

## Completed Items

### Priority 1: Must-fix before production use

#### 1a. `.gitignore` support — DONE
- `FileScanner` now filters via `git check-ignore --stdin` with graceful fallback for non-git dirs
- Hidden files (dot-prefixed names) skipped by default, `--allow-hidden` flag on `init` and `update-index`
- Pipe-safe I/O: stdin written on background DispatchQueue, stdout read before waitUntilExit(), stderr redirected to /dev/null
- Tests: hidden skip/include, .git still skipped with hidden enabled, gitignore filtering, non-git fallback, disable gitignore

#### 1b. Path computation crash risk — DONE
- New `PathUtilities.relativePath(of:in:)` helper using NSString.standardizingPath
- All 4 call sites (InsertCommand, RemoveCommand, FileScanner static + private) updated
- Guard prefix collision fixed in InsertCommand and RemoveCommand (append "/" before hasPrefix)
- Tests: 10 edge cases including trailing slashes, .., prefix collision, root directory

#### 1c. Silent failures — DONE
- InitCommand and UpdateIndexCommand track unreadable files and embed failures
- Summary printed: "Indexed N files (M skipped: X unreadable, Y failed to embed)"
- Progress output correctly distinguishes "Skipped" vs "Updated"/"Added"
- InsertCommand warns when chunks extracted but none could be embedded

### Priority 2: Should-fix (quality / correctness)

#### 2a. Duplicated insert logic — DONE
- Extracted `indexFile()` helper with `IndexResult` enum in UpdateIndexCommand
- Both "new file" and "updated file" branches use shared helper

#### 2b. Dead code in extension loading — RESOLVED
- The `@rpath/vector.framework/vector` path is NOT dead code — it's how the test runner finds the sqlite-vector extension via dyld. Added clarifying comment.

#### 2c. Similarity score display — DONE
- Clamped with `max(0, 1.0 - distance)` to prevent negative values

---

## What's Left

### Priority 3: Nice-to-have (not blocking production use)

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
