# Verbose Progress: Rolling Stats Line

## Goal

Replace the current verbose per-file progress output (one line per file event) with a single terminal line that is rewritten in place using `\r`, showing rolling stats:

- files processed (out of total)
- chunks processed
- non-English files detected

Non-verbose mode stays silent (unchanged). The final `"Update complete: ..."` summary still prints on its own line after the rolling line closes.

## Problem

The new `IndexingPipeline` runs N file workers concurrently. The current progress callback emits one line per event (`Added: path (N chunks)`, `Done: path`, `Skipped: path`, per-file non-English warnings on stderr). With parallelism, these lines interleave and are no longer a useful per-chunk trace. The user wants a single, concise rolling line instead.

## Design

### 1. Replace the string-based progress callback with a structured event stream

Current:

```swift
progress: (@Sendable (String) -> Void)?
```

The callback carries pre-formatted strings, which means only the pipeline can decide what the user sees. We need the command layer to own presentation (so it can render a `\r` line), while the pipeline owns the events.

New (in `IndexingPipeline.swift`):

```swift
public enum IndexingEvent: Sendable {
    case fileStarted(path: String, label: String, chunkCount: Int)
    case fileFinished(path: String, chunkCount: Int)       // chunks actually embedded
    case fileSkippedUnreadable(path: String)
    case fileSkippedEmbedFailure(path: String, totalChunks: Int)
    case nonEnglishDetected(path: String, language: String)
}

public typealias IndexingEventHandler = @Sendable (IndexingEvent) -> Void
```

`run(...)` takes `progress: IndexingEventHandler? = nil` instead of the string callback. The handler is called from multiple concurrent contexts, so it must be `@Sendable`. Making the caller's renderer thread-safe is the command layer's responsibility (see §3).

### 2. Pipeline changes

- Remove the pre-formatted progress strings in `processFile` and the DB-writer task. Emit structured events instead.
- Move the non-English stderr warning out of `processFile`. Emit `.nonEnglishDetected` and let the command layer decide whether to print to stderr or just increment a counter. (Keeping the detection logic in the pipeline; just changing the surface.)
- `InsertCommand` currently doesn't pass `progress`, so the API change is backwards compatible — the default `nil` keeps its behavior.

### 3. Rolling renderer in `UpdateIndexCommand`

Add a small actor (file-local in `UpdateIndexCommand.swift`) that:

- Holds counters: `filesDone`, `chunksDone`, `nonEnglish`, `skipped`, plus immutable `totalFiles`.
- Serializes event handling (so concurrent workers can't scramble stdout).
- Renders the line with `\r` and no trailing newline, e.g.:

  ```
  Indexing: 42/128 files • 1,284 chunks • 3 non-English • 1 skipped\r
  ```

- Uses `FileHandle.standardOutput.write(...)` so we can control the lack of newline without worrying about `print` buffering. Follow up each write with `fflush(stdout)` (via `FileHandle`'s write semantics; a single write of the full formatted string is fine — no explicit flush call needed because `FileHandle.standardOutput` is unbuffered in Swift).
- Exposes a `finish()` method that writes a trailing `\n` so the summary prints on a new line.

The renderer should only activate when `verbose` is true. In non-verbose mode, no progress handler is passed to `run(...)`.

### 4. Event → counter mapping

- `.fileStarted` → no counter change. (We only count a file when it *finishes*, so the ratio `filesDone/totalFiles` is accurate.)
- `.fileFinished(chunkCount)` → `filesDone += 1`, `chunksDone += chunkCount`.
- `.fileSkippedUnreadable` / `.fileSkippedEmbedFailure` → `filesDone += 1`, `skipped += 1`. (Skipped files still count as "done processing" so the ratio reaches `totalFiles/totalFiles`.)
- `.nonEnglishDetected` → `nonEnglish += 1`.

After every counter change, re-render the line.

### 5. Terminal width handling

If the formatted line is longer than the terminal width it will wrap and break the `\r` redraw. Mitigation: keep the line short (the format above is well under 80 chars for reasonable counts) and pad to a fixed minimum width (e.g. 80) with trailing spaces so shorter follow-up renders fully overwrite longer prior renders. Do not attempt to query `COLUMNS` — overkill for this feature.

### 6. Non-TTY behavior

If stdout is not a TTY (piped to a file or another process), `\r`-based progress is useless and clutters logs. Check `isatty(fileno(stdout)) != 0`. When not a TTY, just skip rendering (still pass a handler so counts are tracked, but emit nothing). The summary at the end still prints.

### 7. Removed-file and unchanged-file messages

The current verbose output also prints `"  Unchanged: path"` and `"  Removed: path"` lines from the command layer (not via the pipeline callback). In the new design:

- Suppress both. They're per-item lines that don't fit the rolling-stats model.
- Keep the `unchanged` count in the final summary (already present).
- Add a `removed` count to the rolling line? **No** — removal happens in a separate loop after the pipeline finishes, so it doesn't need to be rolling. Keep removed count in the final summary only.

### 8. Non-English stderr warning

Today, non-English warnings go to stderr unconditionally, regardless of verbose. Decision:

- In verbose mode, the rolling counter replaces the stderr warning. Suppress the per-file stderr warning when verbose.
- In non-verbose mode, keep the current stderr behavior. (It's a meaningful warning for users not watching progress closely; removing it would be a silent behavior change unrelated to the progress refactor.)

Implementation: the command layer decides what to do with `.nonEnglishDetected`. In verbose mode it increments the counter. In non-verbose mode, if `UpdateIndexCommand` wants the stderr warning, it passes a non-nil handler even when not verbose, whose only job is to write the stderr line. (Slight overhead, but keeps behavior parity.)

Alternative: leave the stderr write inside the pipeline and have the command layer suppress it via a flag. Rejected — pushing presentation to the command layer is cleaner.

## Files Touched

- `Sources/VecKit/IndexingPipeline.swift` — add `IndexingEvent`, change `run(progress:)` signature, remove string formatting, remove stderr write.
- `Sources/vec/Commands/UpdateIndexCommand.swift` — add renderer actor, wire it to the new event handler, handle TTY check, suppress per-file `Unchanged`/`Removed` lines.
- `Sources/vec/Commands/InsertCommand.swift` — no functional change, but verify it still compiles (it doesn't pass `progress`).
- Tests — see §Testing.

## Testing

- Build cleanly with `swift build`.
- Run `swift test` to catch regressions in anything that currently exercises `IndexingPipeline`. (The public API changed — any test passing a string callback will need to update.)
- Manual: `vec update-index --verbose` against a directory with >100 files, including at least one non-English file. Verify the line redraws in place, non-English count increments, summary prints on a fresh line.
- Manual: `vec update-index --verbose > out.txt` to confirm non-TTY path produces no progress output, only the summary.
- Manual: `vec update-index` (no verbose) — verify silent behavior is preserved and stderr still warns for non-English files.

## Out of Scope

- Changing default verbosity, adding a new `--progress` flag, or introducing a logging framework.
- Reworking `InsertCommand`'s output (single-file, doesn't need progress).
- Colored output / ANSI styling beyond `\r`.
