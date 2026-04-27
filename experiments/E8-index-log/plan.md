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
- Streaming progress to the log mid-run. The log is post-run only.
- Structured aggregation / query tooling. The log is human-readable
  + greppable; analysis is left to ad-hoc tools.

## Format

JSONL. One record per `update-index` invocation, appended on
completion (success or partial-success). Each record:

```json
{
  "timestamp": "2026-04-26T18:30:42Z",
  "embedder": "e5-base",
  "profile": "e5-base@1200/0",
  "wallSeconds": 963.4,
  "filesScanned": 752,
  "added": 734,
  "updated": 0,
  "removed": 0,
  "unchanged": 0,
  "skippedUnreadable": ["path/a.bin", "path/b.mermaid", ...],
  "skippedEmbedFailures": []
}
```

Why JSONL: append-friendly, line-oriented (greppable, tail-able),
parseable when needed, and survives partial writes (one bad line
doesn't kill the rest of the file). Plain-text would be friendlier
to read but loses the path lists when they get long.

## Reset behavior

`vec reset` already calls `FileManager.removeItem(at: dbDir)` which
wipes everything in the DB folder, including `index.log`. **No code
change needed in `ResetCommand`** — the requirement is satisfied by
existing behavior. Tests should still cover this explicitly so a
future refactor can't silently regress it.

## Size cap

Cap at **10 MB**. When a run is about to append and the existing
log is already ≥10 MB:

1. Read the existing log.
2. Drop oldest records until total size ≤ 10 MB *minus* the new
   record's size.
3. Rewrite the file with the kept tail, then append the new record.

Edge cases:
- If the new record alone exceeds 10 MB (massive skip list):
  truncate the log to *just* the new record. The cap is a soft
  limit; preserving the latest run beats enforcing the byte
  ceiling.
- File doesn't exist yet: skip rotation, just write.

## Implementation sketch

### New module: `Sources/VecKit/IndexLog.swift`

- `struct IndexLogEntry: Codable` — fields above.
- `enum IndexLog` (namespace):
  - `static func append(_ entry: IndexLogEntry, to dbDir: URL) throws`
  - `static func rotateIfNeeded(_ url: URL, maxBytes: Int) throws` — internal helper.
  - `static let maxBytes = 10 * 1024 * 1024`
  - `static let filename = "index.log"`

### Wiring in `UpdateIndexCommand.swift`

After the existing summary `print(...)` (line 632), before the
silent-failure `throw`:

1. Collect skipped paths into two `[String]` arrays during the
   existing result loop (lines 565-584). These already iterate the
   `[IndexResult]` — we just need to capture paths instead of
   counting only.
2. Build `IndexLogEntry` from the values already in scope:
   `activeProfile.alias`, formatted profile string, `wallSeconds`,
   `files.count`, `added`, `updated`, `removed`, `unchanged`, the
   two path arrays.
3. Call `IndexLog.append(entry, to: dbDir)`.

The log write is best-effort: a write failure logs to stderr but
does not fail the command. Indexing succeeded; we don't roll that
back over a log issue.

### Test coverage

- `IndexLogTests`:
  - Round-trip encode/decode of one entry.
  - Append two entries → file has two lines, both parse.
  - Rotation: pre-fill log to >10 MB, append, assert size ≤10 MB
    and newest entry is preserved.
  - Rotation edge: single new entry larger than 10 MB → log
    contains exactly that entry.
- `ResetCommandTests` (or extend existing):
  - Reset deletes `index.log` along with the rest of the DB
    directory. Regression guard for the "free win" above.
- `UpdateIndexCommandTests` (or integration):
  - After a run with ≥1 unreadable file, log contains an entry
    listing that path.
  - After a no-op run (everything unchanged), log still gets an
    entry with `added=0, updated=0`.

## Docs

- `README.md`: one paragraph in the `update-index` section
  describing the log.
- `CLAUDE.md`: brief mention under "Where docs live" → not
  applicable; this is runtime data, not a doc. Skip.
- `plan.md`: add a "Done" entry when shipped, link plan + report.

## Risk / questions for review

1. **JSONL vs structured (per-run subdirectory)?** JSONL is
   simpler; per-run files (e.g. `runs/2026-04-26T18-30-42.json`)
   would side-step rotation entirely but multiply file count. JSONL
   wins on grep-ability for "did file X get skipped recently."
2. **Should the log include every non-English warning too?** The
   warnings already go to stderr and are arguably noisier than
   useful in a persistent log. **Proposal: skip them in v1.**
   Easy to add later if missed.
3. **Best-effort vs hard-fail on log write?** Best-effort. Index
   succeeded; we should not error out a 16-min reindex because the
   log filesystem is full.
4. **Timestamp format:** ISO-8601 UTC with `Z` suffix. Standard,
   sortable, and matches what `Date.ISO8601FormatStyle` produces
   by default.

## Success criteria

- After a fresh `update-index` run, `~/.vec/<db>/index.log` exists
  and contains a JSONL line whose `skippedUnreadable` array lists
  the exact paths the pipeline skipped.
- After a `vec reset`, `index.log` is gone.
- A log file pre-filled to 12 MB shrinks to ≤10 MB after the next
  `update-index` run, with the newest entry preserved.
- Existing `update-index` behavior (summary, exit codes, silent-
  failure detection) is unchanged.
- Tests cover all four bullets above.
