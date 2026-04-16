# Verbose Progress: Rolling Stats Line

## Goal

Replace the current verbose per-file progress output with a single stdout line that is rewritten in place using `\r`, showing rolling counts:

- files processed (out of total)
- chunks embedded
- non-English files detected

Non-verbose mode stays silent (unchanged). The final `"Update complete: …"` summary still prints on a fresh line after the rolling line closes.

## Problem

The new `IndexingPipeline` runs N file workers concurrently. The current progress callback emits one string per event, and those strings interleave across workers. The user wants a single rolling stats line instead.

## Design

The design favors a small, narrow change. Rejected alternatives and why they were rejected are called out in §Rejected Alternatives.

### 1. Minimal pipeline callback change

Current pipeline signature (`IndexingPipeline.swift:59`):

```swift
progress: (@Sendable (String) -> Void)?
```

Replace with a counter-style event enum that carries only the information the renderer actually needs. No paths, no labels, no language strings:

```swift
public enum ProgressEvent: Sendable {
    case fileFinished(chunks: Int)   // a file completed (any outcome that counts toward progress)
    case fileSkipped                 // unreadable, no text, or all-chunks-failed
    case nonEnglishDetected
    case chunksEmbedded(count: Int)  // emitted per embed batch so the chunk counter ticks smoothly
}

public typealias ProgressHandler = @Sendable (ProgressEvent) -> Void
```

`run(progress: ProgressHandler?)` keeps `nil` as default, so `InsertCommand` still compiles untouched.

The handler is called from multiple concurrent contexts. It must be `@Sendable` and it must be **synchronous** — a sync `@Sendable` closure cannot `await` into an actor. The renderer therefore uses `NSLock` (or `OSAllocatedUnfairLock` on platforms where it's available; `NSLock` is fine for our support floor) to serialize counter updates and stdout writes. No actor, no `Task { … }` wrapping, no event reordering.

### 2. Per-batch chunk counter

`processFile` already splits chunks into batches and embeds each batch in a child task. Emit `.chunksEmbedded(count: records.count)` from inside each batch's child task after embedding returns. That makes the chunk counter advance smoothly during a single large file instead of jumping in a big burst at file completion.

Emit `.fileFinished(chunks:)` at the end of `processFile` (for success) and at the DB-writer for the empty-records path (`IndexingPipeline.swift:113-115`). Emit `.fileSkipped` for unreadable/no-text/all-chunks-failed cases. `label` and per-file paths are no longer passed through progress — they only existed to format strings the command layer no longer prints.

### 3. Leave the stderr non-English warning alone

The pipeline currently writes a non-English warning directly to stderr (`IndexingPipeline.swift:178-181`). Leave that write in place, unchanged, for **both** verbose and non-verbose modes. The plan emits `.nonEnglishDetected` in addition to the stderr write so the rolling line's counter can track it.

This intentionally accepts a small duplication in verbose mode (stderr warning + counter), because:

- It keeps one code path for the warning.
- Stderr is a separate stream; it doesn't corrupt the stdout `\r` line (terminals render them on independent buffers).
- The prior revision of this plan routed warnings through the handler to suppress them in verbose mode. That was scope creep — the user did not ask for stderr changes.

### 4. Rolling renderer in `UpdateIndexCommand`

A small file-local `final class ProgressRenderer` (not an actor — see §1) with:

- An `NSLock`.
- Counters: `filesDone`, `chunksDone`, `nonEnglishCount`, plus immutable `totalFiles`.
- `lastRenderedLen: Int` so each render pads with spaces to the previous length, then the string terminates. This overwrites any leftover characters from the previous longer render without relying on a fixed terminal width. No `ioctl`, no `COLUMNS` parsing.
- `handle(_ event: ProgressEvent)` — mutates counters under the lock and writes one formatted line with a leading `\r`.
- `finish()` — writes `\n` so the summary prints on a new line. Must be **idempotent**: if called twice (e.g. once from `defer`, once from normal flow) the second call is a no-op. Also a no-op if no render has happened yet (zero work items), to avoid a blank line before the summary.

Format (no thousands separators, to sidestep locale issues):

```
Indexing: 42/128 files • 1284 chunks • 3 non-English\r
```

If `totalFiles == 0`, the renderer is never instantiated — the update command goes straight to the removal loop and summary.

Writes go through `FileHandle.standardOutput.write(_:)`. We do **not** rely on any "unbuffered in Swift" claim; instead we call `fsync`/`fflush` semantics via an explicit:

```swift
setbuf(stdout, nil)  // at renderer init
```

…or simpler: use `FileHandle.standardOutput` consistently and do nothing about buffering, because on a TTY (the only case we render on) stdout is line-buffered by default, and `\r` without a newline still gets flushed promptly on macOS Terminal / iTerm. If flush-laziness shows up during manual testing, fall back to `fflush(stdout)` after each write. Decide during implementation; not worth pre-optimizing.

### 5. TTY gate

Gate rendering on TTY:

```swift
let isTTY = isatty(FileHandle.standardOutput.fileDescriptor) != 0
```

When not a TTY (piped / redirected), pass no handler at all (`progress: nil`). Counts are not needed because the summary at the end already reports totals. This keeps piped output clean.

### 6. Error safety

In verbose mode, call `renderer.finish()` from a `defer` block *and* after successful pipeline completion. `finish()` is idempotent (§4), so either path leaves stdout on a fresh line before the summary or before any thrown error propagates.

### 7. Removed-file and unchanged-file messages

Today the command layer prints `"  Unchanged: path"` and `"  Removed: path"` when verbose. Suppress both — they don't fit a rolling-stats line. Counts are already in the final summary.

Note: the removal loop runs *after* the pipeline finishes. During removal, no rolling line updates (the renderer has already called `finish()`). That's fine — removal is typically fast and not worth its own progress display. If a user reports needing removal progress later, add it then.

## Rejected Alternatives

- **Structured event enum carrying paths/labels/languages.** Rejected: renderer doesn't use those fields. Narrow enum keeps the API small.
- **Actor-based renderer.** Rejected: forces async event handling, which either makes the callback type `async` (viral through the pipeline) or requires `Task { await … }` wrapping that reorders events. Lock-guarded class is simpler and correct.
- **Fixed 80-column padding.** Rejected: breaks on narrow terminals by causing the line to wrap — `\r` then only rewinds the last wrapped row. Tracking the previous render's length handles any width without querying the terminal.
- **Suppress stderr non-English warning in verbose mode.** Rejected: scope creep. Accepts one line of duplication (stderr + counter) in exchange for zero change to existing warning code paths.
- **Emit `.fileStarted` / include current filename in rolling line.** Rejected: user didn't ask for it; each extra render token is another thing to get wrong across locales / widths. Easy to add later if asked.
- **Include `skipped` in the rolling line.** Rejected: user asked for "files, chunks, non-English." Skips are rare and captured in the final summary.

## Files Touched

- `Sources/VecKit/IndexingPipeline.swift` — add `ProgressEvent` enum, change `progress` parameter type, remove string-formatting calls, emit `.chunksEmbedded` per batch, emit `.fileFinished` / `.fileSkipped` / `.nonEnglishDetected`. Keep stderr warning write untouched.
- `Sources/vec/Commands/UpdateIndexCommand.swift` — add `ProgressRenderer` class, TTY gate, wire handler, suppress per-item `Unchanged` / `Removed` verbose lines, add `defer { renderer?.finish() }`.
- `Sources/vec/Commands/InsertCommand.swift` — no change (doesn't pass `progress`).
- Tests — update any test that constructs a string-based progress callback against `IndexingPipeline.run`.

## Testing

- `swift build`
- `swift test`
- Manual (TTY): `vec update-index --verbose` against a directory with >100 files including one non-English file. Verify: line redraws in place, chunks counter advances smoothly during large files (not only at file boundaries), non-English counter increments, summary prints on a fresh line. Verify stderr warning still appears for the non-English file.
- Manual (pipe): `vec update-index --verbose | cat` — no `\r` junk, no progress output, only summary and any stderr warnings.
- Manual (non-verbose): `vec update-index` — silent stdout progress, stderr warning still fires for non-English files. Parity with current behavior.
- Manual (empty): `vec update-index` in a directory with zero new/updated/removed files — no progress line, only summary, no stray blank line.

## Out of Scope

- Changing default verbosity or adding a `--progress` flag.
- Reworking `InsertCommand` output.
- Colored / ANSI-styled output beyond `\r`.
- Per-file or per-batch timing / throughput metrics.
