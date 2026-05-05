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
`978307200.0` offset between the 1970 and 2001 epochs. Because
the file's mtime sits at ~1.77e9 seconds-since-1970 (~7.8e8
seconds-since-2001) and a double has ~15-17 significant decimal
digits, the offset arithmetic is not bit-exact for every input.
The original
`timeIntervalSinceReferenceDate` and the round-tripped
`timeIntervalSinceReferenceDate` differ by exactly one ULP — measured
at `1.1920928955078125e-07` (i.e. 2⁻²³, the resolution of a
double at magnitude ~10⁹).

**Why the strict `>` comparison sees this 1 ULP.**

`UpdateIndexCommand` decides whether a file is unchanged with
`file.modificationDate > existingModDate`. Swift's `Date`
comparison delegates to the underlying `timeIntervalSinceReferenceDate`
double comparison. A 1 ULP difference is enough; the file is
re-processed.

**Why only 196 of 798 files are affected.**

Round-trip-stable mtimes do exist — when the original double
happens to fit cleanly through the 1970-offset subtraction. Roughly
75% of the corpus survives, the other 25% trips the ULP. APFS
mtimes have nanosecond resolution and are uniformly distributed at
this magnitude, so the split is essentially a property of which
doubles happen to be representable on both sides of the constant.

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

### Fix 1 — Round-trip-safe mtime equality

**Change `UpdateIndexCommand`'s comparison from strict `>` to a
tolerance-aware "newer than" test.** The natural tolerance is
1 ULP at the magnitude of the timestamp; in practice, anything
less than the filesystem's claimed mtime resolution is fine. APFS
exposes nanosecond mtimes; HFS+ has 1-second resolution. A 1-ms
tolerance is well below the smallest meaningful "the file actually
changed" signal on either filesystem and well above the
~1.2e-7 s ULP we observed.

Implementation: replace
```swift
if file.modificationDate > existingModDate {
```
with
```swift
if file.modificationDate.timeIntervalSince(existingModDate) > 0.001 {
```
in `Sources/vec/Commands/UpdateIndexCommand.swift:473`.

This sidesteps the bridge entirely — we still store as
`timeIntervalSince1970` (existing DB schema, no migration needed)
and we still compare via `Date`, but we treat any sub-millisecond
"newer" as a no-op.

**Why not store-as-reference-date instead.** Tempting, but it
doesn't solve the general problem (the same kind of round-trip
exists for any double-encoded epoch and adds an unrelated DB
schema change), and the user-facing behavior — "re-index when
the source actually changes" — is what a mtime-tolerance test
expresses directly. A 1-ms tolerance is also a defensible product
behavior independent of any precision bug: editors that touch a
file faster than that aren't producing meaningful edits.

**Test.** Add a unit test in
`Tests/VecKitTests/UpdateIndexLogicTests.swift` (or wherever the
categorization logic gets exercised — the categorizer is currently
inline in the command; we'll either inline-test via a public
helper or leave it as-is and rely on an integration test). The
integration test: build `FileInfo` and an `indexedFiles` map with
mtimes that round-trip-differ by 1 ULP, run the categorizer,
assert the file lands in `unchanged` not `workItems`.

### Fix 2 — Empty/unreadable files get marked indexed too

**Change `IndexingPipeline`'s zero-chunk path to call
`markFileIndexed(linePageCount: 0)` instead of leaving the row
absent.** The contract for `markFileIndexed` becomes "the file
has been *processed*, with N chunks where N may be 0", which
matches the comment that's already there. This stops the
re-extract loop on truly empty/unreadable files.

The integration consequence to think through: if a previously-empty
file later gets content, the mtime check will catch it (the
filesystem mtime *will* be newer) and re-extract it. Good.

If a file is genuinely unreadable due to a transient error
(permission glitch, IO failure mid-read), marking it indexed at
mtime=now would suppress the next run's retry. The current
zero-chunk path is invoked from `IndexingPipeline.swift:345-364`
which is the "extractor returned zero chunks but didn't throw"
path — i.e. the extractor *succeeded* in saying "no text here",
which is different from "I crashed trying to read this". The
unreadable-as-error path has its own handling further up. Need to
confirm this distinction holds in `TextExtractor` before
implementing — specifically, that a permissions error or read
failure throws rather than returning empty chunks. Will verify
during implementation.

**Test.** Integration test: create a file with zero extractable
content, run update-index twice, assert the second run categorizes
it as `unchanged` (or rather, does *not* call into the pipeline
for it).

### Out of scope

- The non-English warning itself isn't broken; once the
  re-extract loop stops, the warnings stop firing on no-op runs
  by construction. No change needed to the language-detection
  logic or the warning text.
- The DB schema — `file_modified_at REAL` stays as is. No
  migration needed.

## Acceptance criteria

1. After a successful `vec update-index --db markdown-memory`,
   running it again immediately reports `0 added, 0 updated,
   0 removed` and prints zero non-English warnings.
2. Editing one source file (`touch -a -m -t YYYYMMDDHHMM file`)
   then running update-index reports exactly `0 added, 1 updated,
   0 removed`.
3. The 18 currently-unreadable transcript files show up as
   `unchanged` (or are otherwise no longer re-extracted) on the
   second run.
4. No existing test regresses; new tests cover both causes.

## Post-fix verification recipe

```bash
swift run vec update-index --db markdown-memory   # baseline run
swift run vec update-index --db markdown-memory   # must be no-op
```

Second invocation must end with `0 added, 0 updated, 0 removed`
and no warnings. Same DB, same source, same operator state.
