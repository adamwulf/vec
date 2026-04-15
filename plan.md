# vec — Status & Plan

## Current State

The `vec` CLI tool and its `VecKit` library are production-ready for all Priority 1, 2, and 3 items. All five commands are implemented, the project builds cleanly, and tests pass across 10 test suites. The embedding service uses Apple's on-device `NLEmbedding`. The `sqlite-vector` package is integrated via SPM binary target with runtime extension loading.

### What's Implemented

| Component | Status | Notes |
|-----------|--------|-------|
| `vec init <db-name>` | Done | Creates `~/.vec/<db-name>/`, writes config.json, scans + indexes cwd. `--force` and `--allow-hidden` flags. |
| `vec list` | Done | Lists all databases in `~/.vec/` with name, source directory, file count. Missing directory warnings. |
| `vec update-index <db-name>` | Done | Re-scans source directory from config.json. `--allow-hidden` flag. Deduplicated insert logic via `indexFile()` helper. |
| `vec search <db-name> <query>` | Done | Vector similarity search. `--limit`, `-l`, `--include-preview`, `--format json`. Default subcommand. |
| `vec insert <db-name> <path>` | Done | Adds/replaces a single file. Path validation against source directory. |
| `vec remove <db-name> <path>` | Done | Removes entries for a single file. Path validation against source directory. |
| `VectorDatabase` | Done | SQLite + sqlite-vector wrapper. Insert, search, remove, allIndexedFiles. |
| `EmbeddingService` | Done | Uses `NLEmbedding.sentenceEmbedding(for: .english)`, 512 dimensions. |
| `FileScanner` | Done | Directory walking, .gitignore support via `git check-ignore`, hidden file filtering (dot-prefix), skips .git/node_modules/.build/etc, binary detection. Pipe-safe Process I/O. |
| `TextExtractor` | Done | Plain text (whole-doc), markdown (overlapping chunks), PDF (per-page). |
| `PathUtilities` | Done | Safe relative path computation using NSString.standardizingPath. |
| `CSQLiteVec` | Done | System library shim for sqlite3 C API access. |

### What's Tested

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

### Priority 1: Must-fix before production use — DONE

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

### Priority 2: Should-fix (quality / correctness) — DONE

#### 2a. Duplicated insert logic — DONE
- Extracted `indexFile()` helper with `IndexResult` enum in UpdateIndexCommand
- Both "new file" and "updated file" branches use shared helper

#### 2b. Dead code in extension loading — RESOLVED
- The `@rpath/vector.framework/vector` path is NOT dead code — it's how the test runner finds the sqlite-vector extension via dyld. Added clarifying comment.

#### 2c. Similarity score display — DONE
- Clamped with `max(0, 1.0 - distance)` to prevent negative values

### Priority 3: Nice-to-have — DONE

#### 3a. Edge case tests — DONE
- Files with special characters in names (spaces, unicode) — tested
- Markdown edge cases (only headings, every line a heading, very long single line) — tested
- Empty directory scan — tested
- Binary file detection in TextExtractor — tested
- 7 new tests added

#### 3b. Missing features — DONE (selected items)
- `--format json` for `search` command — implemented with `OutputFormat` enum and `printJSONResults()`
- `.vecignore` support — implemented with `fnmatch()` pattern matching in FileScanner
- Remaining items (result grouping, `--verbose`/`--quiet`, `vector_quantize()`) deferred as lower priority

#### 3c. Error handling improvements — DONE
- `VectorDatabase.open()` now calls `verifySchema()` to check the chunks table exists
- `VecError.databaseCorrupted(String)` error case added
- Test added for corrupted database detection

---

## Priority 4: Centralized database storage (`~/.vec/`) — DONE

All databases now live under `~/.vec/<db-name>/` instead of per-directory `.vec/` folders. Each database directory contains `index.db` and `config.json` (source directory path, creation date).

### CLI interface

| Command | Description |
|---------|-------------|
| `vec init <db-name>` | Create a new database, indexing the current directory. `--force`, `--allow-hidden`. |
| `vec list` | List all databases with name, source directory, and file count. |
| `vec search <db-name> <query>` | Search a database. `--limit`, `--include-preview`, `--format json`. |
| `vec <db-name> <query>` | Shorthand for `vec search` (default subcommand). |
| `vec update-index <db-name>` | Re-scan source directory and update the index. `--allow-hidden`. |
| `vec insert <db-name> <path>` | Add/replace a file in the index. |
| `vec remove <db-name> <path>` | Remove a file from the index. |

### What was done

- **4a.** VectorDatabase refactored: `init(databaseDirectory:sourceDirectory:)`, deprecated init removed
- **4b.** DatabaseLocator + DatabaseConfig: path resolution, name validation, config read/write, allDatabases()
- **4c.** InitCommand: takes `<db-name>`, writes config.json, creates `~/.vec/<db-name>/`
- **4d.** ListCommand: table output with name/source/count, missing directory warnings
- **4e.** SearchCommand: takes `<db-name> <query>`, resolves via DatabaseLocator
- **4f.** UpdateIndexCommand: takes `<db-name>`, scans source from config.json
- **4g.** InsertCommand + RemoveCommand: take `<db-name>`, resolve paths against sourceDirectory
- **4h.** FileScanner: removed `.vec` from skipDirectories
- **4i.** Vec.swift: SearchCommand as defaultSubcommand for `vec <db-name> "query"` shorthand
- **4j.** Tests: 106 tests passing (24 CLI, 14 DatabaseLocator, 17 VectorDatabase, 6 Integration, + others)
- **4k.** VecError: added `invalidDatabaseName`, `databaseNotFound`, updated messages

---

## Deferred (out of scope)

- PDF extraction tests (requires PDF fixture files)
- Non-English text embedding behavior tests
- Symlink behavior tests
- Result grouping — show best match per file instead of all chunks
- `--verbose` / `--quiet` flags on all commands
- `vector_quantize()` after updates for better search performance
- Database migration from old `.vec/` format to new `~/.vec/<name>/` format
