# vec — Status & Plan

## Current State

The `vec` CLI tool and its `VecKit` library are production-ready for all Priority 1, 2, and 3 items. All five commands are implemented, the project builds cleanly, and tests pass across 10 test suites. The embedding service uses Apple's on-device `NLEmbedding`. The `sqlite-vector` package is integrated via SPM binary target with runtime extension loading.

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

## Priority 4: Centralized database storage (`~/.vec/`)

**Goal:** Move from per-directory `.vec/` databases to a centralized `~/.vec/<db-name>/` model. This lets any directory on the system create, list, and search named vector databases without requiring a local `.vec/` folder.

### Current architecture (what changes)

- **VectorDatabase** takes a `directory: URL` and computes `dbPath` as `directory/.vec/index.db`
- **InitCommand** creates `.vec/` in the current working directory, scans that directory
- **UpdateIndexCommand**, **SearchCommand**, **InsertCommand**, **RemoveCommand** all derive the database location from the current working directory's `.vec/` subfolder
- **FileScanner** `skipDirectories` includes `.vec`

### New architecture

All databases live under `~/.vec/<db-name>/`. Each database directory contains:
- `index.db` — the SQLite + sqlite-vector database
- `config.json` — metadata: the source directory path that was indexed, creation date, etc.

#### New CLI interface

| Command | Description |
|---------|-------------|
| `vec init <db-name>` | Create a new database named `<db-name>`, indexing the current directory. Stores source directory path in `config.json`. Fails if `<db-name>` already exists (unless `--force`). |
| `vec list` | List all databases in `~/.vec/`, showing name, source directory, and file count. |
| `vec search <db-name> <query>` | Search the named database. Supports `--limit`, `--include-preview`, `--format json`. |
| `vec update-index <db-name>` | Re-scan the source directory recorded in the database's `config.json` and update the index. |
| `vec insert <db-name> <path>` | Add/replace a specific file in the named database. Path resolved relative to the database's source directory. |
| `vec remove <db-name> <path>` | Remove a file from the named database. |

#### Shorthand

`vec <db-name> "search string"` as a convenience alias for `vec search <db-name> "search string"`.

### Implementation tasks

#### 4a. VectorDatabase refactor
- **Change `init` to accept a `databaseDirectory: URL`** (the `~/.vec/<db-name>/` path) and a `sourceDirectory: URL` (the directory being indexed)
- `dbPath` becomes `databaseDirectory/index.db`
- `initialize()` creates the `databaseDirectory`, not a `.vec/` subfolder
- `open()` looks for `databaseDirectory/index.db`
- Add a `config.json` read/write: stores `{ "sourceDirectory": "/abs/path", "createdAt": "ISO8601" }`

#### 4b. New `DatabaseLocator` utility
- Computes `~/.vec/` base path
- `databaseDirectory(for name: String) -> URL` returns `~/.vec/<name>/`
- `allDatabases() -> [(name: String, config: DatabaseConfig)]` lists all subdirs of `~/.vec/` that contain a valid `config.json`
- Validates database names (alphanumeric, hyphens, underscores; no slashes or spaces)

#### 4c. Update `InitCommand`
- Takes `<db-name>` as a required argument
- Creates `~/.vec/<db-name>/` via `DatabaseLocator`
- Writes `config.json` with `sourceDirectory` = current working directory
- Scans current directory (unchanged scan logic)
- Stores embeddings in the centralized database

#### 4d. New `ListCommand`
- `vec list` — iterates all databases via `DatabaseLocator.allDatabases()`
- Displays: name, source directory, indexed file count (from `allIndexedFiles().count`)
- For databases whose source directory no longer exists, show a warning marker

#### 4e. Update `SearchCommand`
- Takes `<db-name>` as first argument, `<query>` as second
- Resolves database via `DatabaseLocator.databaseDirectory(for:)`
- All other logic (embedding, display, `--format json`) unchanged

#### 4f. Update `UpdateIndexCommand`
- Takes `<db-name>` as a required argument
- Reads `config.json` to determine the source directory
- Scans that source directory (not cwd)
- Otherwise same logic for add/update/remove files

#### 4g. Update `InsertCommand` and `RemoveCommand`
- Take `<db-name>` as first argument
- Resolve `<path>` relative to the database's source directory (from `config.json`)
- Otherwise same logic

#### 4h. Update `FileScanner`
- Remove `.vec` from `skipDirectories` (no longer relevant — the database isn't in the source tree)

#### 4i. Update `Vec.swift` (root command)
- Add `ListCommand` to subcommands
- Consider adding a default command or custom parsing to support the `vec <db-name> "query"` shorthand

#### 4j. Update tests
- `VectorDatabaseTests` — update to use a temp `~/.vec/test-db/` style directory
- `CLITests` — update argument parsing tests for new `<db-name>` argument on all commands
- `IntegrationTests` — update to use centralized database paths
- New tests for `DatabaseLocator`: valid/invalid names, listing, missing config
- New tests for `ListCommand`
- Test that `config.json` is written and read correctly

#### 4k. Update `VecError`
- Add `databaseNotFound(String)` for when `<db-name>` doesn't exist in `~/.vec/`
- Add `invalidDatabaseName(String)` for names that fail validation
- Update `databaseNotInitialized` message to reference `vec init <db-name>`

---

## Deferred (out of scope)

- PDF extraction tests (requires PDF fixture files)
- Non-English text embedding behavior tests
- Symlink behavior tests
- Result grouping — show best match per file instead of all chunks
- `--verbose` / `--quiet` flags on all commands
- `vector_quantize()` after updates for better search performance
- Database migration from old `.vec/` format to new `~/.vec/<name>/` format
