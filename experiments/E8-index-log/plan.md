# E8 — `index.log` for `update-index` runs

## Motivation

`vec update-index` reports skip *counts* in its summary line ("18
skipped: 18 unreadable") but not the *paths*. Without `--verbose`,
the offending files are unrecoverable after the run unless you
re-execute. We want a persistent, per-DB record of every indexing
run — what was added/updated/skipped, why, and how long it took —
so an operator can audit corpus drift without re-running.

Concrete trigger: a 752-file e5-base reindex on `markdown-memory`
finished with 18 unreadable skips. Identifying which 18 required
either a verbose re-run or an external scan. Both are wasteful when
the pipeline already knows the answer.

## Scope

A new file `~/.vec/<db>/index.log`, written by `update-index` after
each run, containing one record per run.

### Out of scope

- Logging from other subcommands (`search`, `insert`, `remove`).
- Logging from `vec sweep`. It calls `pipeline.run` for each grid
  point and would multiply log volume by the sweep size with
  little operator value. Future-additive if needed.
- Streaming progress to the log mid-run. The log is post-run only.
- Structured aggregation / query tooling. The log is human-readable
  and greppable; analysis is left to ad-hoc tools.
- Resilience to corrupt log lines. JSONL is a convenience format
  here, not a guarantee. If a future bug truncates a line, the
  next rotation pass simply over-counts and trims one extra entry.
  Acceptable.

## Format

JSONL. One record per `update-index` invocation, appended on
completion (success, partial-success, *and* silent-failure — see
"Silent-failure path" below). Each record:

```json
{
  "schemaVersion": 1,
  "timestamp": "2026-04-26T18:30:42Z",
  "embedder": "e5-base",
  "profile": "e5-base@1200/0",
  "wallSeconds": 963.4,
  "filesScanned": 752,
  "added": 734,
  "updated": 0,
  "removed": 0,
  "unchanged": 0,
  "skippedUnreadable": ["path/a.bin", "path/b.mermaid"],
  "skippedEmbedFailures": []
}
```

- **Type pinning:** `IndexLogEntry.timestamp` is a Swift `Date`
  encoded via `JSONEncoder.dateEncodingStrategy = .iso8601`
  (UTC, `Z`-suffix). Round-trip tests assert this concretely.
- **Path format:** `skippedUnreadable` / `skippedEmbedFailures`
  contain the same relative-to-source-dir strings the pipeline
  emits in `IndexResult.skippedUnreadable(filePath:)` /
  `.skippedEmbedFailure(filePath:)`. Tests pin this.
- **Why JSONL:** append-friendly, line-oriented (greppable,
  tail-able), parseable. Plain-text would lose the path lists at
  scale.
- **Why `schemaVersion`:** cheap forward-compat anchor. Future
  field changes can branch on it without a forensic exercise.

## Silent-failure path

`UpdateIndexCommand` throws `VecError.indexingProducedNoVectors`
when every attempted file fell into `.skippedEmbedFailure` with
zero `added`/`updated`. **The log entry is still written before
the throw** — this is exactly the case operators most need to
audit. The entry's `added=0, updated=0, skippedEmbedFailures=[…]`
is itself the diagnostic.

## Concurrency

`UpdateIndexCommand.swift:406` already refuses to start if another
indexing process is live (PID-file check, throws
`indexingAlreadyRunning`). The log inherits the same single-writer
assumption: at most one `update-index` writes the log at a time.
No file lock added.

## Reset behavior

`vec reset` already calls `FileManager.removeItem(at: dbDir)` which
wipes everything in the DB folder, including `index.log`. **No code
change needed in `ResetCommand`** — the requirement is satisfied by
existing behavior. A new test locks this in as a regression guard.

## Size cap

Cap at **200 records** (last-N policy). When a run is about to
append:

1. Read the existing log if present (`String` contents).
2. Split on `\n`, drop empty trailing lines.
3. If line count ≥ 200, keep the trailing 199 lines verbatim
   (no decode → re-encode — preserves any future additive fields
   we might not know about).
4. Append the new line.
5. Atomic-replace the file: write to `index.log.tmp`, then
   `FileManager.moveItem(at:to:)` over the original. Matches the
   atomic-replace pattern at `UpdateIndexCommand.swift:103`.

Why last-N and not byte-cap: cap-by-bytes requires read-decode-
truncate-rewrite and produces a "single record > cap" edge case
that the cap can't actually enforce. Cap-by-count is two `split`
calls and a slice. With realistic skip lists (<100 KB per record),
200 entries is well under any disk concern. Byte-cap can be added
later as an additive change if real-world logs ever blow up.

## Implementation sketch

### New module: `Sources/VecKit/IndexLog.swift`

```swift
public struct IndexLogEntry: Codable {
    public let schemaVersion: Int      // always 1 in this version
    public let timestamp: Date
    public let embedder: String        // alias, e.g. "e5-base"
    public let profile: String         // identity, e.g. "e5-base@1200/0"
    public let wallSeconds: Double
    public let filesScanned: Int
    public let added: Int
    public let updated: Int
    public let removed: Int
    public let unchanged: Int
    public let skippedUnreadable: [String]
    public let skippedEmbedFailures: [String]
}

public enum IndexLog {
    public static let filename = "index.log"
    public static let maxRecords = 200
    public static func append(_ entry: IndexLogEntry, to dbDir: URL) throws
}
```

`append` does the read-tail-rewrite-rename dance. JSONEncoder
configured with `.iso8601` date strategy. Write is atomic via
tmp + move.

### Wiring in `UpdateIndexCommand.swift`

After the existing summary `print(...)` (line 632), and *before*
the silent-failure `throw` at line 642:

1. Capture skipped paths during the existing result loop
   (lines 565-584). Today it counts; we extend it to also collect
   into `var skippedUnreadablePaths: [String]` and
   `var skippedEmbedFailurePaths: [String]`.
2. Resolve the alias for the entry:
   `let alias = (try? IndexingProfile.parseIdentity(activeProfile.identity).alias) ?? activeProfile.identity`.
3. Build `IndexLogEntry` from in-scope values: `Date()`,
   `alias`, `activeProfile.identity`, `wallSeconds`, `files.count`,
   `added`, `updated`, `removed`, `unchanged`, the two path arrays.
4. Call `try? IndexLog.append(entry, to: dbDir)`. On failure, log
   to stderr in the format:
   ```
   Warning: failed to write index.log: <localized error>
   ```
   Indexing succeeded; we don't roll that back over a log issue.

### Test coverage

- `IndexLogTests`:
  - Round-trip encode/decode of one entry (asserts ISO-8601 format
    in raw JSON, decodes back to equal `Date`).
  - Append to fresh dir → file has one line, parses.
  - Append twice → two lines, both parse.
  - Last-N rotation: pre-fill with 250 lines, append → file has
    exactly 200 lines, *kept tail contains entries 51-250 of input
    plus the new one* (i.e., not just the new entry).
  - Atomic-replace: assert no `index.log.tmp` artifact remains
    after a successful append.
- `ResetCommandTests` (new file — none exists today):
  - Reset of a DB whose folder contains `index.log` deletes the
    log along with the rest of the directory.
- `UpdateIndexCommand` integration coverage (extend existing test
  file):
  - After a run with ≥1 unreadable file, log contains an entry
    where `skippedUnreadable` contains the *relative* path
    matching `IndexResult.filePath` semantics.
  - After a no-op run (everything unchanged), log still gets an
    entry with `added=0, updated=0`.
  - After a silent-failure run (all `.skippedEmbedFailure`), the
    log entry is written before `VecError.indexingProducedNoVectors`
    is thrown. Test catches the throw and asserts the file exists
    with the expected entry.
  - Best-effort write failure: point the log location at an
    unwritable path (e.g., create `index.log` as a directory) →
    `update-index` still exits 0 (or the same exit code it would
    have produced sans-logging) and emits the documented stderr
    warning.

## Docs

- `README.md`: short paragraph in the `update-index` section
  describing `index.log`, its format, the 200-record cap, and the
  exact stderr warning string used on best-effort failure.
- `plan.md`: add a "Done" entry under §Done linking plan + report
  + commit when shipped.

## Risk / open questions

1. **`schemaVersion` migration story.** Bumping to v2 requires a
   reader. v1 has no reader; the field is forward-only insurance.
   Acceptable.
2. **Non-English warnings.** Already go to stderr; not added to
   the log in v1. Could be added as a `warnings: [String]` field
   in v2 if asked.
3. **Per-run files vs JSONL.** Considered and rejected: per-run
   files multiply the file count and complicate "did file X get
   skipped recently" greps. JSONL is the simpler primary view.

## Success criteria

- After a fresh `update-index` run, `~/.vec/<db>/index.log` exists
  and contains a JSONL line whose `skippedUnreadable` array lists
  the exact relative paths the pipeline skipped.
- After a silent-failure `update-index` run (one that throws
  `indexingProducedNoVectors`), the log still contains an entry
  for that run.
- An `update-index` run whose log write fails does not change the
  command's exit status; a stderr warning is emitted in the
  documented format.
- After a `vec reset`, `index.log` is gone.
- A log file pre-filled with 250 lines shrinks to exactly 200
  lines after the next `update-index` run, with the most recent
  199 prior lines plus the new one preserved (kept tail is *not*
  just the new entry).
- After every `update-index` run, no `index.log.tmp` artifact
  remains in the DB directory.
- Existing `update-index` behavior (summary, exit codes,
  silent-failure detection, PID guard) is unchanged.
- Tests cover all of the above.
