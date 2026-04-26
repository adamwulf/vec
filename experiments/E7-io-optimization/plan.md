# E7 — I/O-side optimizations for the indexing pipeline

Status: PLAN ONLY (not yet executed).

## Why this experiment

E6.6 left `e5-base@1200/0` on markdown-memory at **891.1 s wall**
(8070 chunks, 38 m:s, see `data/wallclock-2026-04-25.md`). Embed
stage dominates that wall, but the DB-writer stage is now the only
remaining single-task serial consumer in the pipeline (Stage 3b in
`Sources/VecKit/IndexingPipeline.swift:580`). Before declaring it
out of scope it should be **measured**, not just hand-waved.

Back-of-envelope: 8070 chunks × 768 floats × 4 B ≈ 24 MB of
embedding bytes total, plus ~3 KB/row of metadata strings. That's
trivial throughput-wise. The risk isn't bandwidth — it's per-call
overhead:

- Each `replaceEntries(forPath:with:)` call wraps a fresh
  `BEGIN/COMMIT` (`VectorDatabase.swift:163-184`). On default
  SQLite settings (no `PRAGMA journal_mode=WAL`, no `PRAGMA
  synchronous=NORMAL`) every COMMIT does a full fsync of the
  rollback journal — one fsync per *file*, not per *chunk*, but
  still one per file. markdown-memory has ~674 files → ~674
  fsyncs.
- Each chunk inside that transaction calls `_insert(...)` which
  re-does `sqlite3_prepare_v2` → bind → step → finalize
  (`VectorDatabase.swift:513-561`). 8070 prepare/finalize cycles
  per reindex.
- Every embedding crosses the actor boundary as `[Float]`, gets
  copied into `Data` via `withUnsafeBufferPointer`, then bound as
  a SQLite blob with `SQLITE_TRANSIENT` (the `unsafeBitCast(-1,
  ...)` constant at `VectorDatabase.swift:550`) — meaning SQLite
  *makes its own copy* of the 3 KB blob before stepping. Three
  copies per insert: pipeline → `Data` → SQLite-internal.

Estimated headroom: 1–3 % on `e5-base`. This is a small-stakes
experiment: ship it if it clears 2 %, archive it as "measured,
not worth it" otherwise. A negative result here is also valuable
— it lets future I/O-blame conversations be settled by pointing
at this experiment instead of re-litigating the question.

## Context to read first

1. **Embed → DB handoff**: `Sources/VecKit/IndexingPipeline.swift:578-636`
   (Stage 3b — DB writer). One save per file, three sequential
   actor-hop calls per save (`unmarkFileIndexed` →
   `replaceEntries` → `markFileIndexed`).
2. **Per-chunk insert**: `Sources/VecKit/VectorDatabase.swift:513-561`
   (`_insert`). Prepare/bind/step/finalize cycle, plus the
   `Data(buffer:)` copy at line 547 and the `SQLITE_TRANSIENT`
   bind at line 550.
3. **Transaction shape**: `Sources/VecKit/VectorDatabase.swift:163-184`
   (`replaceEntries`). One `BEGIN TRANSACTION` per file.
4. **SQLite open**: `Sources/VecKit/VectorDatabase.swift:598-604`
   (`openDatabase`). Plain `sqlite3_open` — no PRAGMAs set after
   open. Default journal_mode = DELETE, default synchronous =
   FULL on every COMMIT.
5. **Stats reporting**: `Sources/vec/Commands/UpdateIndexCommand.swift:644-686`
   prints `db=<seconds>` already. We can read it from
   `--format json` runs without extra instrumentation.

## 1. Current I/O shape — quoted code

### Per-file save (one BEGIN/COMMIT per file)

`Sources/VecKit/IndexingPipeline.swift:614-623`:

```swift
let dbStart = DispatchTime.now()
// Crash-safe: unmark → replace (atomic delete+insert) → mark
try await database.unmarkFileIndexed(path: path)
try await database.replaceEntries(forPath: path, with: work.records)
try await database.markFileIndexed(
    path: path,
    modifiedAt: work.file.modificationDate,
    linePageCount: work.linePageCount
)
let dbSeconds = Self.elapsed(since: dbStart)
```

Three actor-boundary calls per file. `replaceEntries` itself
wraps a transaction at `VectorDatabase.swift:163-184`:

```swift
public func replaceEntries(forPath path: String, with records: [ChunkRecord]) throws {
    try _execute("BEGIN TRANSACTION")
    do {
        try _removeEntries(forPath: path)
        for record in records {
            try _insert(...)
        }
        try _execute("COMMIT")
    } catch {
        try? _execute("ROLLBACK")
        throw error
    }
}
```

But `unmarkFileIndexed` and `markFileIndexed` run **outside**
that transaction — each is its own implicit auto-commit. So
the per-file shape is actually:

1. `DELETE FROM indexed_files WHERE file_path = ?` (auto-commit, fsync)
2. `BEGIN; DELETE FROM chunks WHERE file_path = ?; INSERT … (×N); COMMIT` (one fsync)
3. `INSERT OR REPLACE INTO indexed_files …` (auto-commit, fsync)

**That's 3 fsyncs per file**, not 1, on default `synchronous=FULL`.
For 674 files: ~2000 fsyncs over the run.

### Per-chunk insert

`Sources/VecKit/VectorDatabase.swift:513-561` (excerpt):

```swift
private func _insert(...) throws -> Int64 {
    let sql = """
        INSERT INTO chunks (file_path, line_start, line_end, chunk_type, page_number, file_modified_at, content_preview, embedding)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { ... }
    defer { sqlite3_finalize(stmt) }

    sqlite3_bind_text(stmt, 1, filePath, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    // … binds …

    // Store embedding as raw Float32 bytes
    let data = embedding.withUnsafeBufferPointer { buffer in
        Data(buffer: buffer)
    }
    let bindResult = data.withUnsafeBytes { rawBuffer in
        sqlite3_bind_blob(stmt, 8, rawBuffer.baseAddress, Int32(rawBuffer.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
    // …
    guard sqlite3_step(stmt) == SQLITE_DONE else { ... }
    return sqlite3_last_insert_rowid(db)
}
```

Three things to flag:

- **Prepare/finalize per row.** No statement caching — every
  insert re-parses the SQL string. SQLite parses are cheap
  (~µs) but there are 8070 of them per reindex.
- **`Data(buffer:)` allocates and copies** the 3 KB embedding
  on every insert. 8070 × 3 KB = ~24 MB of malloc/free traffic
  just for blob staging.
- **`SQLITE_TRANSIENT`** (the `unsafeBitCast(-1, ...)` 8th arg)
  tells SQLite to make its **own internal copy** of the blob
  before `sqlite3_step` returns. So each blob is copied
  twice: pipeline `[Float]` → `Data` → SQLite. We could pass
  `SQLITE_STATIC` if we held the `[Float]` storage live across
  the step (which we already do — `data` lives until end of
  function), saving one copy.

### SQLite open — no PRAGMAs

`Sources/VecKit/VectorDatabase.swift:598-604`:

```swift
private func openDatabase() throws {
    var opened: OpaquePointer?
    guard sqlite3_open(dbPath, &opened) == SQLITE_OK else {
        throw sqlError("Failed to open database at \(dbPath)")
    }
    handle = SQLiteHandle(opened)
}
```

No `PRAGMA journal_mode=WAL`, no `PRAGMA synchronous=NORMAL`,
no `PRAGMA temp_store=MEMORY`, no `PRAGMA cache_size=...`.
Plain SQLite defaults. Confirmed by grep across `Sources/`:
zero hits for `journal_mode`, `synchronous`, `WAL`, or any
PRAGMA.

### Pipeline-level: is the DB stage on the critical path?

Stage 3b (DB writer) is a **single serial task** consuming
`saveStream`, parallel to all the other stages. The save
stream is unbounded (`IndexingPipeline.swift:286-288`,
documented at lines 274-285 as "no upstream backpressure"):

```swift
let (saveStream, saveContinuation) = AsyncStream<SaveWork>.makeStream(
    bufferingPolicy: .unbounded
)
```

Comment at line 280-285 already predicts this experiment's
question: _"realistic depth stays in single digits because
sqlite writes are O(10 MB/s) on this stack and file-completion
is paced by chunk extraction. If a future embedder pairs wide
vectors with a slow DB stage, this is the first stream to add
an explicit bound on."_

Whether DB is on the critical path is the **first thing** the
experiment must resolve — if `saveStream` depth always stays
≤1 (writer drains as fast as files complete) then DB is *not*
on the critical path and any optimization is invisible at the
wall-clock level. If depth grows, DB lags and there's room.

## 2. What could be wasteful — specifics

In rough order of suspected impact:

| # | Suspicion | Estimated cost on e5-base run |
|---|-----------|-------------------------------|
| 1 | 3 fsyncs/file × 674 files = ~2000 fsyncs at default `synchronous=FULL` | 2000 × ~1ms on APFS SSD ≈ 2s, but contention with embed reads can amplify |
| 2 | `Data(buffer:)` copy + `SQLITE_TRANSIENT` second copy per insert | 8070 × 2× 3 KB ≈ 48 MB malloc traffic; <1s wall but cache-pollutes embed |
| 3 | `sqlite3_prepare_v2` / `sqlite3_finalize` per row | 8070 × ~10µs ≈ 80 ms; rounding error |
| 4 | `unmark`/`mark` outside the `replace` transaction → 3 commits/file | rolls into #1 — those are 2 of the 3 fsyncs |
| 5 | DB writer single task; no async between save-completion and next-file pickup | only matters if #1 is large |
| 6 | actor-boundary hop on every `database.…` call (3 hops/file) | hard to measure isolated; baked into stats already |

The hypothesis ranking is: **#1 (fsync) is the only one big
enough to move the needle**. #2 might shave ms but isn't
wallclock-visible at this scale. #3-#6 are below the noise
floor of run-to-run wallclock variance (~3 % per E6.6 noise
band).

## 3. Levers (ordered by expected ROI)

### L1 — `PRAGMA journal_mode=WAL` + `synchronous=NORMAL` (cheapest, most likely win)

One-line change in `openDatabase()` after `sqlite3_open`:

```swift
try _execute("PRAGMA journal_mode=WAL")
try _execute("PRAGMA synchronous=NORMAL")
```

- WAL eliminates the rollback-journal fsync on every COMMIT
  in favor of an append to `index.db-wal`, with one
  consolidating fsync at checkpoint time.
- `synchronous=NORMAL` further drops fsync-on-COMMIT — durable
  across app crashes, lossy only on OS/power crash mid-write.
  Acceptable for this tool: a `vec update-index` after a power
  failure simply re-derives the missing chunks, and the
  `unmark → replace → mark` ordering already guarantees no
  half-indexed files survive.

Pure config flip. Not a schema change. Existing DBs will pick
up WAL on next open (SQLite migrates the journal mode
in-place). No re-index required to apply it; no re-index
required to revert it.

### L2 — Combine `unmark + replace + mark` into a single transaction

Move the three `database.…` calls inside one
`BEGIN/COMMIT`. Drops 3 fsyncs/file → 1 fsync/file, **even
without WAL**. Composable with L1 (under WAL it drops 3
WAL-frame syncs → 1).

Implementation: add
`replaceEntriesWithMark(forPath:records:modifiedAt:linePageCount:)`
to `VectorDatabase` that wraps all three statements in one
transaction; switch the pipeline DB-writer to use it. Old
methods stay (used by tests and by single-shot CLI commands).

### L3 — Prepared-statement reuse via cached `OpaquePointer`s

Cache one prepared `INSERT INTO chunks …` statement on the
actor; `sqlite3_reset` + rebind per row instead of
prepare/finalize per row. Same for `DELETE FROM chunks WHERE
file_path = ?`.

Smaller win than L1+L2 — savings are µs per insert, ~80 ms
total — but composes cleanly and doesn't change semantics.
Skip unless L1+L2 land below the 2 % bar and we're hunting
for the last fraction.

### L4 — `SQLITE_STATIC` on the embedding blob

Drop the 8th-arg destructor from `SQLITE_TRANSIENT` (the
`unsafeBitCast(-1, ...)` magic constant) to `SQLITE_STATIC`
(pass `nil` for the destructor pointer) — only safe if the
underlying `[Float]` / `Data` buffer outlives the
`sqlite3_step` call, which it does in the current code shape
(both are local lets in `_insert`).

Saves one 3 KB memcpy per insert. ~24 MB of avoided memcpy
traffic. Tiny on its own; bundle it with L3 if and only if
L3 happens.

### L5 — Defer DB writes to a background actor (already structurally done)

Stage 3b is *already* a separate task and the save stream is
unbounded — the DB writer can't block the embedder by design.
There's no work to do here; the existing pipeline already
matches this lever's intent. **Mention only to record that
the lever is already pulled.**

### L6 — Out of scope

- **mmap for vector files / raw binary blob output**: would
  require a schema change (chunks table → external blob file)
  to be meaningful. Schema changes are explicitly out of
  scope.
- **Per-chunk write instead of per-file**: would multiply the
  fsync count by ~12× and is the wrong direction.
- **Async/non-actor SQLite**: the actor boundary is the
  serialization point for SQLite; SQLite is not thread-safe in
  serialized mode by default and we'd need an opt-in. Out of
  scope at this experiment's headroom estimate.

## 4. Quality guard — outputs must be byte-identical

The experiment changes **how** rows are written, not **what**
is written. After each variant, verify:

1. `vec info --db markdown-memory` chunk count matches the
   E6.6 baseline (8070 chunks for `e5-base@1200/0`).
2. `python3 scripts/score-rubric.py` on a freshly captured
   sweep produces the **same TOTAL** as the canonical e5-base
   baseline. Per-query rank brackets must match exactly — any
   rank shift means we've broken determinism.
3. Spot-check: pick 3 chunk IDs at fixed positions, dump the
   `embedding` blob via the SQLite CLI, hash it, compare
   pre/post. Bytes must match — same `[Float]` in, same blob
   out.
4. `indexed_files` row for every file in the source dir; same
   `file_modified_at` timestamps as baseline.

If rubric TOTAL changes by even 1 point, the variant has
introduced ordering/determinism drift and must be rejected
regardless of wallclock improvement.

## 5. Experiment protocol

All commands run from anywhere — pass `--db markdown-memory`,
do not `cd`. (Per CLAUDE.md "DO NOT `cd`".)

### Pre-check: is DB even on the critical path?

Before implementing anything, instrument the existing
pipeline once:

```bash
swift run vec reset --db markdown-memory --force
swift run vec update-index --db markdown-memory --embedder e5-base --format json > /tmp/e7-baseline.json
```

The current `IndexingStats` already reports
`stats.dbSeconds` (summed across files; includes actor-hop
time and SQLite work). Compute `dbSeconds / wallSeconds` and
the `db_pct` already printed by `UpdateIndexCommand.swift:662`.

**Decision gate**:
- If `db_pct < 1 %` (under ~9 s on a 891 s run): DB stage is
  in the noise, max possible win is ≤1 %, **archive the
  experiment as "measured, not worth implementing"** and stop.
- If `db_pct ∈ [1 %, 5 %]`: marginal but worth one variant
  (L1+L2 bundled). Skip L3/L4.
- If `db_pct > 5 %`: do the full sweep below.

Add a fresh signpost to make it more measurable. In
`IndexingPipeline.swift:614-623`, instrument the three calls
separately so `dbSeconds` becomes `unmarkSeconds +
replaceSeconds + markSeconds`, surfaced in stats. (Throwaway
instrumentation — revert before committing the final variant.)

### Variant runs — same protocol, three configurations

Run each variant the same way:

```bash
swift run vec reset --db markdown-memory --force
time swift run vec update-index --db markdown-memory --embedder e5-base --format json > /tmp/e7-<variant>.json
python3 scripts/score-rubric.py benchmarks/e5-base-1200-0/
```

(Capture rubric outputs into `benchmarks/e5-base-1200-0-e7-<variant>/`
to keep the per-variant archive. The directory name encodes
the alias-chunk-overlap geometry.)

Variants, in order, with stop-rules:

| Tag | Code change | Stop if … |
|-----|-------------|-----------|
| **A0** | none — baseline re-confirm | (always run for noise-floor reset) |
| **A1** | L1 only (WAL + synchronous=NORMAL) | rubric TOTAL drift → reject |
| **A2** | L1 + L2 (single-transaction unmark+replace+mark) | A2 wallclock not better than A1 by ≥1 % → stop, ship A1 |
| **A3** | L1 + L2 + L3 + L4 | only run if A2 clears the 2 % bar — going for the long tail |

Each variant: 3 wallclock runs minimum; report median ± min/max. The
E6.6 noise band is ~3 %, so a single run is not enough to
declare a 2 % win.

### Signpost data to record per variant

For each run dump from `--format json`:

- wall seconds (top-level)
- `extractSeconds`, `embedSeconds`, `dbSeconds` from stats
- `unmarkSeconds`, `replaceSeconds`, `markSeconds` (if the
  throwaway instrumentation is in)
- save-queue depth peak (one `print` from the DB writer
  recording `max(saveStream backlog)`); if saveStream backlog
  always = 0 we have direct proof DB is not on the critical
  path
- chunk count (must equal 8070)
- rubric TOTAL (must equal baseline)

Append a row to `data/wallclock-e7-io.md` per variant.

## 6. Success criteria

Ship the variant that:

1. **Passes byte-identity** — chunk count exact, rubric TOTAL
   exact (per-query rank brackets identical).
2. **Achieves ≥2 % wallclock drop on `e5-base@1200/0`** vs the
   E6.6 891.1 s baseline, **measured as median of 3 runs**
   (single-run wins inside the 3 % noise band don't count).
3. **No data loss** — re-running `vec update-index` on a fully
   indexed corpus is a no-op (zero re-embeds).
4. **No schema change** — the `chunks` and `indexed_files`
   tables match pre-experiment column-by-column. Schema
   migrations are a separate experiment.

Cross-model spot-checks before declaring win: re-run on
`bge-base@1200/240` and `bge-small@1200/0` to confirm the
gain isn't e5-base-specific. We don't need full sweeps —
single runs are fine since the change is config/transactional,
not embedder-specific. If either regresses by >1 %, gate the
PRAGMA behind a flag rather than flipping the default.

If no variant clears 2 %: write up the negative result in
`experiments/E7-io-optimization/report.md` with the measured
`db_pct` so this question doesn't get re-asked.

## 7. Blockers / open questions

- **Q1 — Save-stream depth (the load-bearing question).** Does
  `saveStream` ever queue more than one item under the current
  e5-base run? If queue depth max = 1 then the DB stage drains
  faster than file completions and is **off the critical path**;
  any wallclock win from L1-L4 collapses to noise. Resolved by
  the pre-check instrumentation above. **This question gates
  whether we proceed past variant A1.**

- **Q2 — Existing DB compatibility under WAL.** Does flipping
  `journal_mode=WAL` on an existing markdown-memory DB cleanly
  migrate the journal in place? SQLite docs say yes for any
  DB not opened with another connection. We're single-process,
  so this should be safe — confirm with a one-off open + close
  before running variant A1.

- **Q3 — `bge-base` regression risk.** E6.6 shows `bge-base`
  flat (+1.9 %, in noise band) and `nomic` slightly regresses
  (+5.6 %). If those models produce more chunks per file or
  use larger embeddings (1024-dim mxbai-large), the per-file
  fsync ratio is different. The cross-model spot-check (§6)
  catches this before the change ships.

- **Q4 — Existing API surface.** L2 wants a new
  `VectorDatabase` method that bundles the three calls. The
  existing `unmarkFileIndexed` / `replaceEntries` /
  `markFileIndexed` are public and used by tests. Adding a
  fourth method is fine; deprecating the three would be a
  breaking change and is out of scope for this experiment.

- **Q5 — `synchronous=NORMAL` durability bar.** Adam ran the
  E6.5 defaults flip without raising durability concerns,
  consistent with vec being a derive-from-source-on-demand
  tool. Confirm before merging that "lose last commit on
  power-cut" is acceptable; if not, ship L2 (transaction
  fold) without L1 (PRAGMA tweak).

- **Q6 — Pre-check instrumentation lifetime.** The
  per-call timing (unmark/replace/mark seconds separately) is
  diagnostic, not a feature. Revert before final commit so
  `IndexingStats` doesn't grow ephemeral fields. Note in
  the experiment report which variant the instrumentation
  proved out so future me knows what was measured.
