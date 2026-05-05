# E9 — mtime round-trip and unreadable-file re-extract bugs

## Problem

`vec update-index` re-extracts and re-embeds files that have not
changed between runs. On `markdown-memory` (798 files), every
back-to-back invocation reports `0 added, 196 updated, 0 removed
(18 skipped: 18 unreadable)` — the same 196 + 18 files every time.
The 196 emit "non-English content detected" warnings that the
operator can't silence by re-running, because every run does the
work over again. Wasted CPU + ANE cycles on every refresh.

## Diagnosis

Two independent root causes drive the steady-state churn. Both
were confirmed empirically by instrumenting `UpdateIndexCommand`
to print the filesystem mtime and the DB-stored mtime at full
precision for each "Updated" file (instrumentation removed
before this writeup).

### Cause 1 — Date round-trip loses 1 ULP via the `timeIntervalSince1970` bridge (196 files)

**Mechanism.**

`FileScanner` reads `URLResourceKey.contentModificationDateKey`
into a Swift `Date`. Internally a `Date` stores
`timeIntervalSinceReferenceDate` (seconds since 2001-01-01 UTC) as
a 64-bit IEEE 754 double.

`VectorDatabase.markFileIndexed` writes it to SQLite as
`modifiedAt.timeIntervalSince1970` (a `REAL`).

`VectorDatabase.allIndexedFiles` reads it back via
`Date(timeIntervalSince1970: timestamp)`.

The `timeIntervalSince1970` getter and the
`Date(timeIntervalSince1970:)` initializer both apply the constant
`978307200.0` offset between the 1970 and 2001 epochs. SQLite's
`REAL` is a true 8-byte IEEE 754 double and round-trips exactly;
the lossy step is the Foundation arithmetic that crosses epochs.

The file's `timeIntervalSinceReferenceDate` sits at ~7.78e8 (binade
[2^29, 2^30)), where the ULP is 2⁻²³ ≈ 1.1920928955078125e-7.
The round-tripped value differs from the original by exactly one
ULP at that binade — measured deterministically at
`1.1920928955078125e-07` for every affected file.

**Why the strict `>` comparison sees this 1 ULP.**

`UpdateIndexCommand` decides whether a file is unchanged with
`file.modificationDate > existingModDate`. Swift's `Date`
comparison delegates to the underlying `timeIntervalSinceReferenceDate`
double comparison. A 1 ULP difference is enough; the file is
re-processed.

**Why only 196 of 798 files are affected.**

Round-trip-stable mtimes do exist — when the original double
happens to fit cleanly through the 1970-offset subtraction. The
behavior is deterministic per-file (a given mtime either survives
the round-trip exactly or trips the ULP every time), and which
half a file lands in is purely a property of which doubles happen
to be representable bit-exactly on both sides of the offset
arithmetic. The 196/798 split is corpus-specific, not a general
ratio.

**Confirmation.**

Instrumented run output (deterministic, all 196 files):

```
DEBUG: biographical-timeline.md
  fs1970=1756332581.5919762
  db1970=1756332581.5919762
  deltaTs=0
  fsRef=778025381.59197628
  dbRef=778025381.59197617
  deltaRef=1.1920928955078125e-07
```

Identical 1970-form printouts to 7 fractional digits, but
`fsRef > dbRef` by exactly one ULP. All 196 deltaRef values are
identical and positive — pure floating-point round-trip loss, not
mtime drift.

### Cause 2 — Empty/unreadable files never get a completion record (18 files)

**Mechanism.**

`IndexingPipeline.swift:345-364` handles the "extract produced
zero chunks" path (empty file, no extractable text, format we
can't parse). It records `.skippedUnreadable` and accumulates
stats, but it does **not** call `database.markFileIndexed`. The
contract on `markFileIndexed` (`VectorDatabase.swift:340-342`) is
"only call after all chunks for the file have been successfully
written" — and these files have zero chunks.

So `indexed_files` never gets a row for them. Next run,
`UpdateIndexCommand` finds no entry and treats the file as
"Added", re-extracting it just to discover it produces zero chunks
again, and the cycle repeats.

**Confirmation.**

The summary line `(18 skipped: 18 unreadable)` matches the 18
files printed as `ADDED (no DB row)` by the diagnostic. They are
all `transcript.txt` files in `granola/...` directories that are
either empty or contain no extractable text.

## Effect

- Every `update-index` run reprocesses 214 files (196 + 18) on the
  reference corpus, even with zero source-side changes.
- For the 196: full extract → embed → DB-write pipeline runs. On
  ~10 KB markdown averaging 5-10 chunks/file, that's a few
  seconds of CPU + ANE per run plus pointless writes to the
  embeddings table (the `replaceEntries → markFileIndexed`
  sequence atomically rewrites the same data).
- For the 18: extract runs (cheap, but still runs), the language
  detector and the "non-English" warning fire on whatever sliver
  of text the extractor produces before declaring zero chunks.
  Operator sees alarming stderr noise on every refresh.
- Steady-state operations (resync after a Granola sync, or
  CI-style "freshen the index" runs) silently do far more work
  than necessary and emit warnings that don't reflect reality.

## Solution

Fix both causes. They are independent and small.

### Fix 1 — Round-trip-safe mtime comparison

**Change `UpdateIndexCommand`'s comparison from strict `>` to a
tolerance-aware "newer than" test.** Implementation: replace

```swift
if file.modificationDate > existingModDate {
```

with

```swift
if file.modificationDate.timeIntervalSince(existingModDate) > 0.001 {
```

in `Sources/vec/Commands/UpdateIndexCommand.swift:473`.

This sidesteps the round-trip entirely — we still store as
`timeIntervalSince1970` (existing DB schema, no migration needed)
and we still compare via `Date`, but we treat any sub-millisecond
"newer" as a no-op. The 1 ms threshold is ~8000× the observed ULP
(1.19e-7 s) — comfortable headroom against precision drift, well
below any filesystem's coarsest mtime granularity (1 s on FAT/HFS+)
or any meaningful editor-save cadence on APFS. The justification
is purely "ULP headroom + below FS granularity"; this is not a
product-level "we suppress sub-1ms edits" claim.

**Why not store as INTEGER nanoseconds instead.** That fixes the
bug at the source by switching to an exact integer representation,
but requires a schema migration and `vec`'s stated philosophy
(`VectorDatabase.swift:664`) is "single-user tool, no migrations".
A tolerance-based comparison is the cheapest correct fix; if more
precision bugs surface later, revisit.

**Why asymmetric `> 0.001` rather than `abs(...) > 0.001`.** The
categorizer asks "is the source newer than the indexed copy", not
"are they equal". Asymmetric matches the existing intent.

### Fix 2 — Empty/no-text files get marked indexed; transient read errors keep retrying

This needs **two coordinated changes**, because today's code can't
tell "empty file" apart from "permission-denied". Both the
zero-chunk and transient-error paths fall into the same "extract
returned 0 chunks without throwing" branch in the pipeline (the
review-cycle audit confirmed `TextExtractor.extract` is declared
`throws` but contains zero `throw` statements — `try? String(contentsOf:)`
swallows everything). If we naively mark every zero-chunk file as
indexed, transient errors stop retrying.

**Change A — Make `TextExtractor` throw on real read errors.**

In `Sources/VecKit/TextExtractor.swift`, replace `try?` with `try`
on the actual byte-level read. The semantic split we want:

- **Throws**: file couldn't be opened (permission, IO failure,
  missing). The pipeline's catch arm at
  `IndexingPipeline.swift:320-340` handles this — the file is
  recorded as `.skippedUnreadable` and **`markFileIndexed` is
  not called**, so the next run retries. This matches the doc
  comment that's already on that arm.
- **Returns empty `chunks`**: file was opened successfully but had
  no extractable text (genuinely empty, whitespace-only, all
  comments-stripped, malformed but-readable PDF, image with no OCR
  text). The pipeline's zero-chunk arm at
  `IndexingPipeline.swift:345-364` records `.skippedUnreadable`
  and **does** call `markFileIndexed(linePageCount: 0)` — see
  Change B.

The text path:
```swift
// before:
guard let content = try? String(contentsOf: url, encoding: .utf8) else {
    return ExtractionResult(chunks: [], linePageCount: nil)
}
// after:
let data: Data
do {
    data = try Data(contentsOf: url)
} catch {
    throw error  // permission/IO/missing bubbles up; pipeline retries next run
}
guard let content = String(data: data, encoding: .utf8) else {
    return ExtractionResult(chunks: [], linePageCount: nil)  // not-utf8: legitimately no text
}
```

The PDF and image paths get the same treatment: open via
`Data(contentsOf:)` (which throws on read failure), then call into
PDFKit / Vision on the resulting Data (their own failures still
return empty — that's fine, those mean "we read the bytes but
couldn't parse them as PDF/image-text", which is the no-text case,
not the unreadable case).

**Change B — Zero-chunk path calls `markFileIndexed`.**

In `Sources/VecKit/IndexingPipeline.swift:345-364` (the `if
chunks.isEmpty` branch in extract), after the `accumulator.markFileTotal(...)`
call and the existing close-out, add a `markFileIndexed` call so
the file ends up with a completion record (linePageCount: 0).
The exact placement needs to thread through the accumulator —
zero-chunk files currently complete via the writer's "0 records
to write" path at line 605-614, which records the skip but
doesn't mark. We add the mark there, gated on the file being
zero-chunk-via-extract (not zero-chunk-via-all-embeds-failed,
which is the `.skippedEmbedFailure` case at line 591-604 — that
path stays unchanged because embed failures should retry).

**Why not also markIndexed on embed-failure.** Embed failures are
likely-transient model/ANE issues that benefit from a retry,
unlike "file has no text" which is a stable property of the file.
Plan leaves that path alone.

**Behavioral consequence of Fix 2.**

- 18 transcript files in markdown-memory that today re-process on
  every run will get `indexed_files` rows with `linePageCount: 0`.
- `vec info` and `vec list` will report 18 more files in their
  count. This is more honest — those files *have* been processed;
  they just produced no embeddings — but the user-visible number
  changes. README §"vec info" output description gets a one-line
  note.
- Truly transient unreadable files (permission glitch resolved
  before next run) now retry correctly thanks to Change A. This
  is a behavior *improvement* over today.

### Out of scope

- The non-English warning itself isn't broken; once the
  re-extract loop stops, the warnings stop firing on no-op runs
  by construction. No change needed to the language-detection
  logic or the warning text.
- The DB schema — `file_modified_at REAL` stays as is. No
  migration needed.

### Known tradeoff (PDF + image extraction switched to Data-based APIs)

To make the throw-vs-empty split work for PDFs and images,
`extractFromPDF` and `extractFromImage` switched from URL-based
APIs (`PDFDocument(url:)`, `VNImageRequestHandler(url:)`) to their
Data-based counterparts (`PDFDocument(data:)`,
`VNImageRequestHandler(data:)`) preceded by `try Data(contentsOf:)`.
The motivation is correctness: `PDFDocument(url:)` returns nil
indistinguishably for "couldn't read the file" and "the bytes
aren't a valid PDF", which is exactly the distinction Fix 2 needs.

Tradeoff: previously the OS could potentially memory-map the
file; now we read the entire file into RAM eagerly before parsing.
For markdown-memory's typical PDFs (a few MB at most) this is
fine. For pathological inputs — multi-hundred-MB PDFs or images —
peak memory rises by the file size. If that ever becomes a real
problem, the fix is to keep the URL-based path for the parse step
and add a separate `Data(contentsOf:url, options: [.alwaysMapped])`
probe upfront purely to detect read errors before handing off the
URL. Not worth the complexity today; flag for future work.

## Tests

The categorizer is currently inline in `UpdateIndexCommand.run`.
Pull it into a small testable helper (e.g. `categorizeFiles(scanned:
indexed:) -> (workItems: [...], unchanged: Int)`) so the boundary
cases below can be unit-tested without spinning up a full pipeline.

**Categorizer boundary tests** (`Tests/vecTests/UpdateIndexCategorizerTests.swift`):

1. mtime equal to indexed value → `unchanged`.
2. mtime newer by 1 ULP at the reference-date binade → `unchanged`
   (the bug today; pinned by the fix).
3. mtime newer by ~1 ms (just under threshold) → `unchanged`.
4. mtime newer by 2 ms → `Updated`.
5. mtime *older* than indexed value (clock-skew or
   restored-from-backup) → `unchanged` (asymmetric `>` semantics).
6. file absent from indexed map → `Added`.

**Round-trip property test** (same file): generate ~1000 random
plausible APFS mtimes spanning 2020-2030, push each through the
`Date → timeIntervalSince1970 → Double round-trip → Date`
sequence, run the categorizer with the round-tripped value as the
indexed entry and the original as the scanned `FileInfo`. Assert
**all** are categorized `unchanged`. This pins the precision claim
across the entire mtime distribution we care about.

**Pipeline integration tests** (`Tests/VecKitTests/IndexingPipelineTests.swift`
or wherever the pipeline integration tests live):

7. **Empty-file no-op on re-run.** Index a corpus containing one
   genuinely-empty `.txt` file; run `update-index` twice; assert
   the second run categorizes the file as `unchanged` (i.e. it
   never reaches the extractor) and that `allIndexedFiles()`
   contains the file with `linePageCount = 0`.
8. **Permission-error file retries on re-run.** Index a corpus
   containing one file with `chmod 000` (or otherwise unreadable);
   assert the file does **not** get a row in `indexed_files` and
   the second run re-attempts extraction. Skip the test if the
   CI environment can't reliably make a file unreadable.
9. **fileCount visibility.** After indexing a corpus with N
   genuinely-empty files, `database.allIndexedFiles().count`
   should include those N files. Pins the `info`/`list` count
   behavior change.

## Acceptance criteria

1. After a successful `vec update-index --db markdown-memory`,
   running it again immediately reports `0 added, 0 updated,
   0 removed` and prints zero non-English warnings.
2. Editing one source file (e.g. `touch -m`) then running
   update-index reports exactly `0 added, 1 updated, 0 removed`.
3. The 18 currently-zero-chunk transcript files appear in
   `indexed_files` with `linePageCount = 0` after one run, and
   are categorized as `unchanged` on subsequent runs.
4. A file made unreadable (`chmod 000`) is **not** marked indexed,
   so it retries on the next run.
5. All existing tests pass; new tests cover both causes per the
   list above.

## Post-fix verification recipe

```bash
swift run vec update-index --db markdown-memory   # baseline run
swift run vec update-index --db markdown-memory   # must be no-op
```

Second invocation must end with `0 added, 0 updated, 0 removed`
and no warnings. Same DB, same source, same operator state.
