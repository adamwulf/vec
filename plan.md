# vec — Status & Plan

## Current State

The `vec` CLI tool and its `VecKit` library are production-ready for all Priority 1, 2, 3, 4, 5, and 6 items. All seven commands are implemented, the project builds cleanly, and all tests pass (run `swift test` to verify current count). The embedding service uses Apple's on-device `NLEmbedding`. Vector similarity search uses pure-Swift cosine distance (via Accelerate/vDSP) over embeddings stored as Float32 blobs in SQLite — no external dynamic libraries required. File type detection uses Apple's `UTType` framework, and image files are supported via Vision framework OCR.

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
| `VectorDatabase` | Done | SQLite wrapper with pure-Swift cosine similarity search (Accelerate/vDSP). Insert, search, remove, allIndexedFiles, totalChunkCount. Schema creation wrapped in transaction for crash safety. |
| `EmbeddingService` | Done | Uses `NLEmbedding.sentenceEmbedding(for: .english)`. Dimension determined at runtime (see `EmbeddingService.dimension`). Non-English detection lives inline in `IndexingPipeline`'s extract stage (via `NLLanguageRecognizer.dominantLanguage`) and surfaces as a `.nonEnglishDetected` progress event. |
| `FileScanner` | Done | Directory walking, UTType-based file detection (.text, .pdf, .image), .gitignore support via `git check-ignore`, hidden file filtering (dot-prefix), skips .git/node_modules/.build/etc, binary detection. Pipe-safe Process I/O. `knownTextFilenames` set for extensionless files (Makefile, Dockerfile, etc.). Resilient resource value reads (`try?`). |
| `TextExtractor` | Done | Plain text (whole-doc), markdown (overlapping chunks), PDF (per-page), image OCR (Vision framework). |
| `PathUtilities` | Done | Safe relative path computation using NSString.standardizingPath. |
| `CSQLiteVec` | Done | System library shim for sqlite3 C API access. |

### What's Tested

Run `swift test` to see current suite counts. Test files are in `Tests/VecKitTests/` and `Tests/CLITests/`.

| Test Suite | File | Coverage |
|-----------|------|----------|
| `VecKitTests` | `VecKitTests.swift` | `ChunkType` raw values (including image), `TextChunk` construction |
| `EmbeddingServiceTests` | `VecKitTests.swift` | Real embeddings, empty/whitespace input, dimension check |
| `TextExtractorTests` | `VecKitTests.swift` | Large/small markdown, txt files, empty/whitespace files, headings-only, every-line-heading, long single line, binary file, image OCR extraction, PDF extraction (fixture-based) |
| `FileScannerTests` | `VecKitTests.swift` | .git skipping, binary detection (with and without extension), node_modules, relative paths, hidden skip/include, .git still skipped when hidden enabled, gitignore filtering, non-git fallback, disable gitignore, .vecignore patterns, spaces/unicode in names, empty directory, image file detection |
| `PathUtilitiesTests` | `VecKitTests.swift` | Normal paths, trailing slashes, .., outside directory, same path, root dir, deep nesting, prefix collision |
| `ChunkingStrategyTests` | `VecKitTests.swift` | Overlap behavior, heading boundaries, custom chunk/overlap sizes |
| `VectorDatabaseTests` | `VectorDatabaseTests.swift` | Initialize, open, insert, search (ordering, similarity, limit, fields, PDF page), allIndexedFiles, removeEntries, multi-file scenarios, corrupted DB detection |
| `DatabaseLocatorTests` | `DatabaseLocatorTests.swift` | Name validation (alphanumeric, hyphens/underscores, empty, spaces, slashes, special chars, path traversal, reserved names), directory paths, config read/write roundtrip, missing/malformed config, allDatabases listing, resolveFromCurrentDirectory (single match, no match, multiple matches) |
| `IntegrationTests` | `IntegrationTests.swift` | Full scan+embed+store+search pipeline, update-index flows (modified/deleted/added files), insert-then-search, remove-then-search |
| `CLITests` | `CLITests.swift` | Subcommand registration (including info), argument parsing for all 7 commands, default values, flag parsing, short flags, --allow-hidden, default subcommand routing, --db/-d flag parsing for all commands |

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
- No longer applicable — sqlite-vector extension removed entirely. Vector search now uses pure-Swift cosine distance via Accelerate/vDSP.

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
- Remaining items (`--verbose`/`--quiet`) deferred as lower priority

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
- **4k.** Tests: all passing (run `swift test` for current counts across CLI, DatabaseLocator, VectorDatabase, Integration, and other suites)
- **4l.** VecError: added `invalidDatabaseName`, `databaseNotFound`, `sourceDirectoryMissing`, updated messages
- **4m.** `info` added to reserved command names in DatabaseLocator
- **4n.** VectorDatabase schema creation wrapped in transaction (BEGIN/COMMIT with ROLLBACK on failure)
- **4o.** Language detection: `IndexingPipeline` extract stage runs `NLLanguageRecognizer.dominantLanguage` on the first chunk per file and emits a `.nonEnglishDetected` progress event so renderers can count/warn.
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

## Priority 6: UTType-based file detection and image OCR support — DONE

Replaced hard-coded file extension allowlists in FileScanner with Apple's `UTType` (from `UniformTypeIdentifiers` framework) for file type detection. Added image-to-text OCR support using Apple's Vision framework.

### What was done

- **6a.** FileScanner refactored to use `UTType(filenameExtension:)` with `.conforms(to:)` checks for `.text`, `.pdf`, and `.image` instead of maintaining manual extension sets (`textExtensions`, `pdfExtension` removed)
- **6b.** `knownTextFilenames` set and `isLikelyTextFile` fallback preserved for extensionless files that UTType can't identify
- **6c.** `ChunkType.image` case added to the enum for OCR-extracted text chunks
- **6d.** `TextExtractor.extractFromImage(_:)` method added using `VNRecognizeTextRequest` with `.accurate` recognition level, English language, and language correction enabled
- **6e.** Image detection added to `TextExtractor.extract(from:)` using UTType check before UTF-8 text reading
- **6f.** SearchCommand updated to show `(OCR)` label for image chunk types in text output; JSON output handles image `chunk_type` automatically via existing `rawValue` serialization
- **6g.** Tests: `ChunkType.image` raw value test, programmatic PNG image OCR test (CoreGraphics-rendered text), FileScanner test verifying .png files are picked up by scanner

---

## Deferred (out of scope)

- PDF extraction tests (requires PDF fixture files)
- Non-English text embedding behavior tests
- Symlink behavior tests
- `--verbose` / `--quiet` flags on all commands
- Approximate nearest neighbor (ANN) indexing for large-scale search performance
- Database migration from old `.vec/` format to new `~/.vec/<name>/` format

---

## Priority 7: Search output polish and chunk inspection — IN PROGRESS

Goal: make `vec search` output more compact and precise, and provide a way to
inspect an individual chunk by index. Decisions captured here so future work has
a single source of truth.

### 7a. Search output format rewrite — DONE

Current output prints file header + indented lines per match with 2-decimal
scores. New format groups chunks per file onto a single line:

```
filename L18327-18356,18305-18334,7811-7840 (0.1823)
```

Details:

- One line per file. Chunks comma-separated.
- Chunks listed in descending match-score order (top match first).
- File score shown as 4 decimals (`bestScore`, same derivation as today:
  `max(0, 1.0 - distance)`).
- Only the first chunk in a line-range run carries the `L` prefix — subsequent
  line-range chunks drop the `L` (e.g. `L10-20,20-30,30-40`).
- Non-text chunks keep their type marker regardless of mode: `whole`, `P3` (PDF
  page), `OCR` (image text).
- Distance precision is already `Double` under the hood — 4 decimals is well
  within the real signal.

### 7b. `--show lines|chunks` flag on `vec search` — DONE

Controls how text line-range chunks render. Default: `lines`.

- `--show lines` → `L10-20,20-30,30-40`
- `--show chunks` → `C1,5,2` where the numbers are stable 1-based chunk IDs
  (ordered by DB `id ASC` within the file). List order still reflects score
  ranking, so the positions tell you the ranking and the numbers tell you the
  stable identity of each chunk.
- Non-text chunks (`whole`, `P3`, `OCR`) render identically in both modes.

### 7c. `vec chunk <index> <filename>` — DONE

New command. Prints the `content_preview` for the Nth chunk of a file,
1-based, ordered by DB `id ASC`. Supports `-d` / `--db` and cwd-based database
resolution just like other commands. Single integer index — one identifier
space covers line-range chunks, PDF pages, OCR, and whole-file chunks.

Argument order: `vec chunk <index> <filename>`.

Chunk indices are stable for a given indexed state. Re-indexing a file resets
row IDs, but extractor output is deterministic from file content, so an
unchanged file gets the same chunk IDs back.

### 7d. Skip `.whole` chunk for oversize files — DONE

`TextExtractor.extract` (Sources/VecKit/TextExtractor.swift:48) always appends a
`.whole` chunk, but `EmbeddingService.embed` silently truncates text longer than
`maxEmbeddingTextLength` (10,000 chars). So the "whole-document" embedding for a
100 MB log is really just an embedding of its first ~10 KB — misleading.

Fix: skip the `.whole` chunk when trimmed text exceeds
`EmbeddingService.maxEmbeddingTextLength`. Apply the same guard to
`extractFromPDF` (TextExtractor.swift:122-129), which concatenates all page text
before embedding. Expose `maxEmbeddingTextLength` as `public` so `TextExtractor`
can reference the authoritative constant.

No backward-compat concerns: re-indexing deletes and re-inserts, so stale
`.whole` rows clean themselves up.

### 7e. Stream large files instead of loading into memory — TODO

Tracked in detail in `large-file-memory-issue.md`. Summary:

`TextExtractor.extract` uses `String(contentsOf:)` which loads the entire file
into RAM. For 100 MB+ log files this is wasteful and risks OOM. Options:

1. `Data(contentsOf:options:.mappedIfSafe)` — let the OS page contents in on
   demand.
2. Line-by-line streaming via `FileHandle` with a ring buffer large enough for
   chunk overlap.
3. Size-gated fallback (simplest but least thorough).

The chunker currently needs random access to the full line array to build
overlapping windows, so option 2 requires moving to a sliding-window chunker
that only keeps the recent `chunkSize + overlapSize` lines in memory.

### 7f. `vec reset` — DONE

Convenience command that combines `deinit` + `init` while preserving the
configured source directory. Deletes `~/.vec/<db-name>/` and re-creates an
empty database pointing at the same source. `-d` / `--db` optional (resolves
from cwd otherwise), `--force` skips the confirmation prompt.

Implementation: `Sources/vec/Commands/ResetCommand.swift`. Registered as a
subcommand of `Vec`. Added to `DatabaseLocator.reservedNames`.

### 7g. `vec list` size column — DONE

Added a Size column to `vec list` showing the on-disk size of each database's
`index.db` file, formatted via `ByteCountFormatter`. Missing or unreadable
files show "unknown" rather than failing the whole listing.

### 7h. Cosine similarity display clarity — DONE

Already resolved (Priority 2c). Display score is `max(0, 1.0 - distance)`,
which clamps negative (opposite) cosine similarities to 0. In practice
NLEmbedding rarely produces truly negative similarities — most unrelated text
lands near 0 (perpendicular) — so clamping rarely hides useful signal.

Noted here so future-me doesn't wonder whether "opposite" matches need special
handling: they'd still appear in results if they made the top-N by distance,
just displayed as `0.00`.
