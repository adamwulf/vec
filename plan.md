# vec — Status & Plan

## Current State

The `vec` CLI tool and its `VecKit` library are production-ready for all Priority 1, 2, 3, 4, and 5 items. All seven commands are implemented, the project builds cleanly, and tests pass across 10 test suites (121 tests). The embedding service uses Apple's on-device `NLEmbedding`. The `sqlite-vector` package is integrated via SPM binary target with runtime extension loading.

### What's Implemented

| Component | Status | Notes |
|-----------|--------|-------|
| `vec init <db-name>` | Done | Creates `~/.vec/<db-name>/`, writes config.json, creates DB schema. `--force` flag. Users run `vec update-index` separately to populate. |
| `vec list` | Done | Lists all databases in `~/.vec/` with name, source directory, file count. Missing directory warnings. |
| `vec update-index [-d <name>]` | Done | Re-scans source directory from config.json. `--allow-hidden` flag. Deduplicated insert logic via `indexFile()` helper. |
| `vec search [-d <name>] <query>` | Done | Vector similarity search with result coalescing by file. `--limit` controls file count (not chunk count). `--include-preview`, `--format json`. Default subcommand. Whole-doc chunks show `(whole file)`. JSON output includes `chunk_type`. |
| `vec insert [-d <name>] <path>` | Done | Adds/replaces a single file. Path validation against source directory. |
| `vec remove [-d <name>] <path>` | Done | Removes entries for a single file. Path validation against source directory. |
| `vec info [-d <name>]` | Done | Shows database metadata: name, source directory, created date, file count, chunk count, DB file size. |
| `VectorDatabase` | Done | SQLite + sqlite-vector wrapper. Insert, search, remove, allIndexedFiles, totalChunkCount. Schema creation wrapped in transaction for crash safety. |
| `EmbeddingService` | Done | Uses `NLEmbedding.sentenceEmbedding(for: .english)`, 512 dimensions. Includes `detectLanguage()` and `warnIfNonEnglish()` methods — non-English content is still embedded but warns to stderr once per file. |
| `FileScanner` | Done | Directory walking, .gitignore support via `git check-ignore`, hidden file filtering (dot-prefix), skips .git/node_modules/.build/etc, binary detection. Pipe-safe Process I/O. `knownTextFilenames` set for extensionless files (Makefile, Dockerfile, etc.). Resilient resource value reads (`try?`). |
| `TextExtractor` | Done | Plain text (whole-doc), markdown (overlapping chunks), PDF (per-page). |
| `PathUtilities` | Done | Safe relative path computation using NSString.standardizingPath. |
| `CSQLiteVec` | Done | System library shim for sqlite3 C API access. |

### What's Tested

| Test Suite | Count | Coverage |
|-----------|-------|----------|
| `VecKitTests` | 3 | `ChunkType` raw values, `TextChunk` construction |
| `EmbeddingServiceTests` | 7 | Real embeddings, empty/whitespace input, dimension check, language detection (English, non-English, empty) |
| `TextExtractorTests` | 9 | Large/small markdown, txt files, empty/whitespace files, headings-only, every-line-heading, long single line, binary file |
| `FileScannerTests` | 17 | .git skipping, binary detection (with and without extension), node_modules, relative paths, hidden skip/include, .git still skipped when hidden enabled, gitignore filtering, non-git fallback, disable gitignore, .vecignore patterns, spaces/unicode in names, empty directory |
| `PathUtilitiesTests` | 10 | Normal paths, trailing slashes, .., outside directory, same path, root dir, deep nesting, prefix collision |
| `ChunkingStrategyTests` | 3 | Overlap behavior, heading boundaries, custom chunk/overlap sizes |
| `VectorDatabaseTests` | 17 | Initialize, open, insert, search (ordering, similarity, limit, fields, PDF page), allIndexedFiles, removeEntries, multi-file scenarios, corrupted DB detection |
| `DatabaseLocatorTests` | 21 | Name validation (alphanumeric, hyphens/underscores, empty, spaces, slashes, special chars, path traversal, reserved names), directory paths, config read/write roundtrip, missing/malformed config, allDatabases listing, resolveFromCurrentDirectory (single match, no match, multiple matches) |
| `IntegrationTests` | 6 | Full scan+embed+store+search pipeline, update-index flows (modified/deleted/added files), insert-then-search, remove-then-search |
| `CLITests` | 28 | Subcommand registration (including info), argument parsing for all 7 commands, default values, flag parsing, short flags, --allow-hidden, default subcommand routing, --db/-d flag parsing for all commands |

---

## Completed Items

### Priority 1: Must-fix before production use — DONE

#### 1a. `.gitignore` support — DONE
- `FileScanner` now filters via `git check-ignore --stdin` with graceful fallback for non-git dirs
- Hidden files (dot-prefixed names) skipped by default, `--allow-hidden` flag on `update-index`
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
- Search result coalescing — results grouped by file path, `--limit` controls file count, whole-doc chunks show `(whole file)`, JSON includes `chunk_type`
- Remaining items (`--verbose`/`--quiet`, `vector_quantize()`) deferred as lower priority

#### 3c. Error handling improvements — DONE
- `VectorDatabase.open()` now calls `verifySchema()` to check the chunks table exists
- `VecError.databaseCorrupted(String)` error case added
- Test added for corrupted database detection

---

## Priority 4: Centralized database storage (`~/.vec/`) — DONE

All databases now live under `~/.vec/<db-name>/` instead of per-directory `.vec/` folders. Each database directory contains `index.db` and `config.json` (source directory path, creation date).

### CLI interface (superseded by Priority 5 below)

| Command | Description |
|---------|-------------|
| `vec init <db-name>` | Create empty database for cwd. `--force` to reinitialize. |
| `vec list` | List all databases with name, source directory, and file count. |
| `vec update-index <db-name>` | Re-scan source directory and update the index. `--allow-hidden`. |
| `vec search <db-name> <query>` | Search a database. `--limit`, `--include-preview`, `--format json`. |
| `vec <db-name> <query>` | Shorthand for `vec search` (default subcommand). |
| `vec insert <db-name> <path>` | Add/replace a file in the index. |
| `vec remove <db-name> <path>` | Remove a file from the index. |
| `vec info <db-name>` | Show database metadata (name, source, created date, files, chunks, DB size). |

### What was done

- **4a.** VectorDatabase refactored: `init(databaseDirectory:sourceDirectory:)`, deprecated init removed
- **4b.** DatabaseLocator + DatabaseConfig: path resolution, name validation, config read/write, allDatabases()
- **4c.** InitCommand: takes `<db-name>`, writes config.json, creates `~/.vec/<db-name>/`. No longer scans/indexes — users run `vec update-index` separately.
- **4d.** ListCommand: table output with name/source/count, missing directory warnings
- **4e.** SearchCommand: takes `<db-name> <query>`, resolves via DatabaseLocator. Results coalesced by file path.
- **4f.** UpdateIndexCommand: takes `<db-name>`, scans source from config.json
- **4g.** InsertCommand + RemoveCommand: take `<db-name>`, resolve paths against sourceDirectory
- **4h.** FileScanner: removed `.vec` from skipDirectories
- **4i.** Vec.swift: SearchCommand as defaultSubcommand for `vec <db-name> "query"` shorthand
- **4j.** InfoCommand: takes `<db-name>`, shows name, source directory, created date, file count, chunk count, DB file size
- **4k.** Tests: 116 tests passing (26 CLI, 18 DatabaseLocator, 17 VectorDatabase, 6 Integration, + others)
- **4l.** VecError: added `invalidDatabaseName`, `databaseNotFound`, `sourceDirectoryMissing`, updated messages
- **4m.** `info` added to reserved command names in DatabaseLocator
- **4n.** VectorDatabase schema creation wrapped in transaction (BEGIN/COMMIT with ROLLBACK on failure)
- **4o.** Language detection: `EmbeddingService.detectLanguage()` and `warnIfNonEnglish()` — warns to stderr once per file for non-English content
- **4p.** FileScanner fixes: binary file scan bug fixed, scanner resilience (`try?` for resourceValues), `knownTextFilenames` set added, cmake extension restored

---

## Priority 5: Optional `--db` flag and cwd-based database resolution — DONE

Currently, every command except `init` and `list` requires a positional `<db-name>` argument. This priority makes that argument optional by adding cwd-based database resolution.

### Design

- All commands except `init` and `list` get an optional `-d`/`--db <name>` flag (using `@Option`, not `@Argument`)
- When `-d` is omitted, resolve the database by matching cwd against all known databases' `sourceDirectory` in `config.json`
- When `-d` is provided, use it directly (same as current `DatabaseLocator.resolve()` behavior)
- `init` keeps its positional `dbName` argument (you're naming a new DB)
- `list` has no database argument (lists all)
- The default subcommand (`vec <query>`) works with cwd-based resolution — no db-name needed from cwd

### CLI interface (updated)

| Command | Description |
|---------|-------------|
| `vec init <db-name>` | Create empty database for cwd. `--force` to reinitialize. |
| `vec list` | List all databases. |
| `vec update-index [-d <name>]` | Scan and index files. `--allow-hidden`. |
| `vec search [-d <name>] <query>` | Search. `--limit`, `--include-preview`, `--format json`. |
| `vec <query>` | Shorthand for `vec search` (default subcommand, resolves db from cwd). |
| `vec insert [-d <name>] <path>` | Add/replace a file. |
| `vec remove [-d <name>] <path>` | Remove a file. |
| `vec info [-d <name>]` | Show database metadata. |

### Implementation plan

- **5a.** Add `DatabaseLocator.resolveFromCurrentDirectory()` that scans `~/.vec/*/config.json` for a matching `sourceDirectory`
- **5b.** Add new `VecError` cases:
  - `.noDatabaseForDirectory` — clear message: "No database found for current directory. Use `-d <name>` or run `vec init <name>` here first."
  - `.multipleDatabasesForDirectory` — lists conflicting database names
- **5c.** Change `UpdateIndexCommand`, `SearchCommand`, `InsertCommand`, `RemoveCommand`, `InfoCommand` to use `@Option(name: .shortAndLong) var db: String?` instead of `@Argument var dbName: String`
- **5d.** In each command's `run()`, resolve via: `db != nil ? DatabaseLocator.resolve(db!) : DatabaseLocator.resolveFromCurrentDirectory()`
- **5e.** Update `CLITests` for new argument patterns (commands no longer require positional db-name, accept `-d` flag)
- **5f.** Run `swift test` to verify all tests pass

---

## Deferred (out of scope)

- PDF extraction tests (requires PDF fixture files)
- Non-English text embedding behavior tests
- Symlink behavior tests
- `--verbose` / `--quiet` flags on all commands
- `vector_quantize()` after updates for better search performance
- Database migration from old `.vec/` format to new `~/.vec/<name>/` format
