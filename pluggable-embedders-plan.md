# Pluggable Embedders — Plan

Agent: `agent-d1a1c1e3`  (2026-04-18)

## Goal

Introduce an `Embedder` protocol abstraction with two concrete
implementations — `NomicEmbedder` (wrapping today's nomic-embed-text-v1.5
code) and `NLEmbedder` (restoring `NLEmbedding.sentenceEmbedding`) —
and wire the rest of the code (pool, indexing pipeline, CLI, search)
through the protocol. This creates a clean slot for llama.cpp to land as
a third implementation in a later round. It also persists the embedder
choice per database so `vec search` can auto-resolve without a flag.

Non-goals: llama.cpp itself, hybrid retrieval, BM25, query expansion,
migration of existing pre-refactor DBs.

## Ship criteria (copied from task brief, restated in-plan)

1. `Embedder` protocol with `embedDocument`, `embedQuery`, nonisolated
   `dimension`, nonisolated `name`.
2. Two concrete types: `NomicEmbedder` (768) and `NLEmbedder` (512).
3. `vec update-index --embedder nomic|nl` selects the embedder. Default
   is `nomic`. Omitting on an existing DB uses the recorded one.
4. `DatabaseConfig` persists `{ embedderName, dimension }` on first
   index. Mismatch on subsequent runs refuses with "run `vec reset`".
   `vec search` auto-resolves — no flag at query time.
5. `EmbedderPool` is generic over the protocol. Pool stays size-1 for
   both current implementations (documented).
6. `vec reset` clears the embedder fields so a fresh choice can be
   made on the next `update-index`.
7. All 179 existing tests pass. Add `NLEmbedderTests` (20-task canary,
   dim=512) and `EmbedderConfigTests` (write/read, mismatch, reset).
8. Bean-test sanity: NL default-chunks ≈ 6/60 (±1), nomic 1200/240 ≈
   35/60 (±2).
9. Document in `pluggable-embedders.md` (200–400 lines).

## Design

### Protocol shape

```swift
public protocol Embedder: Sendable {
    /// Short stable identifier. Persisted in DatabaseConfig. Also used
    /// in logs. Examples: "nomic-v1.5-768", "nl-en-512".
    var name: String { get }

    /// Dimensionality of every vector returned. Must match the vectors
    /// stored in the DB for this embedder's DatabaseConfig.
    var dimension: Int { get }

    /// Embed a document chunk for indexing.
    func embedDocument(_ text: String) async throws -> [Float]

    /// Embed a query at search time.
    func embedQuery(_ text: String) async throws -> [Float]
}
```

Why the protocol keeps `var name` / `var dimension` plain (no
`nonisolated` keyword at the protocol level):

- The protocol-level `nonisolated` spelling is newer and its interaction
  with actor conformance varies across Swift 6 minor versions. Keeping
  the requirement plain sidesteps that complexity.
- Conforming actors satisfy the requirement with `nonisolated let name = ...`
  — a stored `let` declared `nonisolated` on an actor is the canonical
  Swift-6 pattern for constant-valued protocol properties and lets
  non-actor callers read them synchronously.
- `Sendable` conformance is required so an `Embedder` can cross actor
  boundaries into the pool.

### Concrete types

**`NomicEmbedder`** — an `actor`. Essentially the current
`EmbeddingService` renamed and moved behind the protocol:

```swift
public actor NomicEmbedder: Embedder {
    public nonisolated let name = "nomic-v1.5-768"
    public nonisolated let dimension = 768

    private var bundle: NomicBert.ModelBundle?

    public init() {}

    public func embedDocument(_ text: String) async throws -> [Float] {
        try await embed(prefix: "search_document: ", text: text)
    }
    public func embedQuery(_ text: String) async throws -> [Float] {
        try await embed(prefix: "search_query: ", text: text)
    }
    // ...existing private embed/load helpers, copied verbatim...
}
```

**`NLEmbedder`** — also an `actor`, wrapping `NLEmbedding.sentenceEmbedding`.
Actor-wrapping is required because the underlying C++ runtime segfaults
under concurrent calls on one shared instance (this is the original
reason `EmbedderPool` existed pre-nomic). Actor serialization eliminates
that risk for the single-instance path the pool now uses.

```swift
public actor NLEmbedder: Embedder {
    public nonisolated let name = "nl-en-512"
    public nonisolated let dimension = 512

    // NLEmbedding wasn't trained with search_document/search_query
    // prefixes — they are a nomic-specific convention. For NLEmbedder
    // these are no-ops. Both methods route to the same embed() path.
    public func embedDocument(_ text: String) async throws -> [Float] {
        try await embed(text)
    }
    public func embedQuery(_ text: String) async throws -> [Float] {
        try await embed(text)
    }

    // truncation cap: 10_000 chars — matches the pre-nomic ceiling
    // that protected against std::bad_alloc (see commit ecd3ebf).

    private let embedding: NLEmbedding?

    public init() {
        self.embedding = NLEmbedding.sentenceEmbedding(for: .english)
    }

    private func embed(_ text: String) async throws -> [Float] {
        guard let embedding else { throw EmbedderError.modelUnavailable }
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.count > Self.maxInputCharacters {
            trimmed = String(trimmed.prefix(Self.maxInputCharacters))
        }
        guard let vector = embedding.vector(for: trimmed) else {
            throw EmbedderError.embedFailed(text: trimmed)
        }
        return vector.map { Float($0) }
    }

    public static let maxInputCharacters = 10_000
}
```

`EmbedderError` is a new small `LocalizedError` enum with `modelUnavailable`
and `embedFailed` cases. Keeps NL errors expressive without polluting
`VecError`.

### Pool — generic over protocol

```swift
public actor EmbedderPool {
    private let embedder: any Embedder

    public init(embedder: any Embedder) {
        self.embedder = embedder
    }

    public func acquire() async -> any Embedder { embedder }
    public func release(_ embedder: any Embedder) { /* no-op */ }

    public func warmAll() async {
        do { _ = try await embedder.embedDocument("warmup") } catch {}
    }

    public nonisolated var name: String { embedder.name }
    public nonisolated var dimension: Int { embedder.dimension }
}
```

- Both current embedders are single-instance actor-serialized. The
  pool reflects that: one embedder, no replication. Documented in the
  source comment alongside `warmAll`.
- `acquire()` returns `any Embedder` — existential dispatch on the hot
  path is acceptable because the call happens once per chunk and
  `embedDocument` dominates the cost by 5+ orders of magnitude.

### DatabaseConfig shape

```swift
public struct DatabaseConfig: Codable {
    public let sourceDirectory: String
    public let createdAt: Date
    public let embedder: EmbedderConfig?  // nil on pre-refactor DBs

    public struct EmbedderConfig: Codable, Equatable {
        public let name: String       // e.g. "nomic-v1.5-768"
        public let dimension: Int     // e.g. 768
    }
}
```

Why `Optional`:

- Pre-refactor configs lack the field. Decoding must continue to
  succeed so `vec list`/`vec info` don't break on an existing DB.
- On first successful `update-index` run after the refactor, the CLI
  fills in `embedder` from the selected embedder. If the DB already
  has rows (pre-refactor case), we document the one-shot `vec reset`
  that the user must run.

Mismatch semantics:

- On `vec update-index`, if `DatabaseConfig.embedder == nil` → set it
  to the selected embedder's `{ name, dimension }` and rewrite the
  config before the pipeline runs (so a crash mid-index still leaves
  the DB consistent — existing chunks will match the recorded dim).
- If `DatabaseConfig.embedder != nil` and `--embedder` is passed with
  a different name → refuse: "Database was indexed with
  '<recorded>'. Pass --embedder <recorded> or run 'vec reset'."
- If `DatabaseConfig.embedder != nil` and `--embedder` is omitted →
  resolve to the recorded embedder silently.
- On `vec search`, no `--embedder` flag exists. Always resolve from
  `DatabaseConfig.embedder`. If nil (pre-refactor DB with existing
  chunks in an unknown dim), refuse with: "Database has no recorded
  embedder. Run 'vec reset' then 'vec update-index --embedder <name>'
  to rebuild." — silent fallback risks dim mismatch between query
  and stored vectors.
- `vec insert <path>` (single-file indexing) follows the same rule as
  update-index: if config has no recorded embedder, refuse with
  "Run 'vec update-index' first to establish an embedder." Insert
  doesn't have a `--embedder` flag; it always uses the recorded one.
  A newly-reset (empty, embedder=nil) DB must be indexed with
  update-index first.

This keeps the CLI forgiving for pre-refactor DBs (they still list
and info fine, but search/insert/update-index won't run without an
explicit user action) while making the happy path fully automatic.

### Config atomicity

Writing `embedder` to config on the first-run path runs *before* the
pipeline starts the DB writer, so:

- Every chunk inserted during this run has the dim that matches
  the recorded config.
- If the run fails mid-index, subsequent `vec update-index` runs
  inherit the recorded embedder (no mismatch) and resume with
  consistent dims.
- If the user wants to switch embedders after a partial run, `vec
  reset` clears the config and any partial chunks in one shot.

### Embedder factory

A small `EmbedderFactory` (enum with static `make` method) keeps the
string ↔ type mapping in one place:

```swift
public enum EmbedderFactory {
    public static let defaultName = "nomic"  // CLI alias
    public static let knownNames: [String] = ["nomic", "nl"]

    public static func make(name: String) throws -> any Embedder {
        switch name {
        case "nomic": return NomicEmbedder()
        case "nl":    return NLEmbedder()
        default:      throw VecError.unknownEmbedder(name)
        }
    }

    /// Maps a CLI alias → the embedder's canonical `name` for persistence.
    public static func canonicalName(for alias: String) throws -> String {
        let e = try make(name: alias)
        return e.name
    }
}
```

Two kinds of names in play (documented explicitly in the framework doc):

- **CLI alias**: `nomic`, `nl`. Short, user-typed. What the `--embedder`
  flag accepts.
- **Canonical name**: `nomic-v1.5-768`, `nl-en-512`. What is stored in
  `DatabaseConfig`. Stable across minor CLI renames.

Persistence uses canonical names. Mismatch error messages show both:
"Database was indexed with 'nomic-v1.5-768' (--embedder nomic). Pass
--embedder nomic or run 'vec reset' first."

### CLI surface

- `vec update-index --embedder <nomic|nl>` — optional. Drives
  embedder selection per the rules above.
- `vec search` — no flag. Embedder auto-resolved from DB.
- `vec reset` — clears `DatabaseConfig.embedder` (sets to nil) so a
  fresh index can pick a new one.
- `vec info` — new line `Embedder: <canonical name>` (or `-` if nil).
- `vec init` — does NOT take an embedder flag. Empty DB has no
  embedder. The first `update-index` sets it. This keeps `init`
  symmetric with today's semantics.

### VectorDatabase — dim-awareness

Today `VectorDatabase.init` takes `dimension: Int = 768`. The DB
stores BLOBs with no dim enforcement (verified at
VectorDatabase.swift:86–93 and .swift:232–239 — the search path reads
`blobSize / sizeof(Float)` with no assertion).

Plan:

- Keep `dimension` on `VectorDatabase.init` but thread it through
  from the caller: `UpdateIndexCommand` and `SearchCommand` pass
  `config.embedder?.dimension ?? defaultDim` when constructing the
  DB. This preserves the existing API shape.
- Add a soft assertion on `insert`: if `embedding.count != 0` and
  `embedding.count != self.dimension`, throw. Prevents silently
  mixing dims across runs. Empty vectors (skipped chunks) still pass.
- Search path gets a similar check on the query vector.

These checks are belt-and-braces — the mismatch refusal in the CLI
should catch everything upstream — but they catch the programmer-error
case where someone manually constructs `VectorDatabase(dimension: 768)`
and passes it 512-dim vectors.

### IndexingPipeline — embedder injection

Today `IndexingPipeline.init(concurrency:)` constructs its own
`EmbedderPool` with a hardcoded `EmbeddingService`. After the
refactor:

```swift
public init(
    concurrency: Int = max(ProcessInfo.processInfo.activeProcessorCount, 2),
    embedder: any Embedder
) {
    self.workerCount = concurrency
    self.pool = EmbedderPool(embedder: embedder)
}
```

Callers (UpdateIndexCommand, InsertCommand) resolve the embedder
once from `DatabaseConfig` + the CLI flag before constructing the
pipeline.

## File-level changes

New:

- `Sources/VecKit/Embedder.swift` — protocol + `EmbedderError`.
- `Sources/VecKit/NomicEmbedder.swift` — moved out of `EmbeddingService.swift`.
- `Sources/VecKit/NLEmbedder.swift` — restored, wrapped in actor.
- `Sources/VecKit/EmbedderFactory.swift` — alias ↔ type mapping.
- `Tests/VecKitTests/NLEmbedderConcurrencyTests.swift` — 20-task canary, dim=512.
- `Tests/VecKitTests/EmbedderConfigTests.swift` — round-trip + mismatch + reset.
- `pluggable-embedders.md` — the design doc.
- `pluggable-embedders-plan.md` — this file.

Modified:

- `Sources/VecKit/EmbeddingService.swift` — delete. Replaced by
  `NomicEmbedder.swift`. A deprecation typealias is NOT provided —
  per CLAUDE.md we don't add back-compat shims, and all call sites
  are updated in the same change set.
- `Sources/VecKit/DatabaseLocator.swift` — add `EmbedderConfig`
  nested type + `embedder: EmbedderConfig?` field on `DatabaseConfig`.
- `Sources/VecKit/IndexingPipeline.swift` — `EmbedderPool` takes
  an injected embedder; pipeline `init` accepts an `Embedder`.
- `Sources/VecKit/VectorDatabase.swift` — add soft dim check on
  `_insert` and `search`.
- `Sources/VecKit/FileScanner.swift` (VecError home) — add
  `.unknownEmbedder(String)` and `.embedderMismatch(recorded:requested:)`.
- `Sources/vec/Commands/UpdateIndexCommand.swift` — add `--embedder`
  flag, resolve against `DatabaseConfig`, write config on first
  index, refuse on mismatch, pass embedder into pipeline.
- `Sources/vec/Commands/SearchCommand.swift` — resolve embedder from
  `DatabaseConfig` (fallback to default with stderr warning if nil).
- `Sources/vec/Commands/InsertCommand.swift` — same resolution as
  update-index (no flag; use recorded).
- `Sources/vec/Commands/ResetCommand.swift` — write a config with
  `embedder: nil` on reset.
- `Sources/vec/Commands/InfoCommand.swift` — print embedder line.
- `Tests/VecKitTests/VecKitTests.swift` — rename
  `EmbeddingServiceTests` → `NomicEmbedderTests`; update references
  to `EmbeddingService.*` → `NomicEmbedder.*`.
- `Tests/VecKitTests/NomicEmbedderConcurrencyTests.swift` — update
  to use `NomicEmbedder` name.
- `Tests/VecKitTests/VectorDatabaseTests.swift`,
  `Tests/VecKitTests/IntegrationTests.swift` — use `NomicEmbedder`.

Unmodified (verified):

- `TextExtractor.swift` — no embedder reference.
- `SearchResult.swift`, `SearchResultCoalescer.swift` — indifferent
  to dimension.
- `Models/*`, `TextSplitter*`, `FileScanner*` logic — unaffected.

## Test plan

Existing tests (179):

- All must continue to pass. The rename from `EmbeddingService` to
  `NomicEmbedder` is mechanical and touches ~4 files; behavior is
  unchanged.

New tests:

1. `NLEmbedderConcurrencyTests` — mirror of
   `NomicEmbedderConcurrencyTests`. 20 concurrent `embedDocument` calls
   against one shared `NLEmbedder`. Asserts every vector has length 512.
   This specifically exercises the actor-serialization claim, since
   pre-nomic NLEmbedding was known to crash under concurrent access on
   shared instances.
2. `EmbedderConfigTests` — four scenarios:
   - `DatabaseConfig.embedder` round-trips through JSON encode/decode.
   - Pre-refactor config (no `embedder` key) decodes with `embedder == nil`.
   - `UpdateIndexCommand` with `--embedder nomic` against a DB already
     configured for `nl` → refuses with `embedderMismatch`.
   - `ResetCommand` clears `embedder` → next `update-index --embedder nl`
     succeeds and records `nl-en-512`.

Don't add:

- A dim-mismatch DB insertion test — covered by the CLI-level
  mismatch refusal. Only add the insert guard + a tiny unit test if a
  reviewer insists.

### Full test budget

- `swift test` currently runs ~179 tests. Adding 2 new tests (the
  config suite can be a single XCTestCase with 4 methods, the NL
  canary is one method) brings it to ~184.
- NL canary runtime: roughly the same as the nomic one (both load a
  model once, then run 20 embeddings). Expected ≤ 10s.

## Bean-test sanity sweeps (Phase 5)

Two reindexes:

1. `vec reset`, `vec update-index --embedder nl` on markdown-memory
   at default chunks (1200/240). Score against `bean-test.md`.
   **Expected: ≈6/60** (within ±1 of the pre-nomic baseline in
   `bean-test-results.md`).
2. `vec reset`, `vec update-index --embedder nomic` (or default) at
   1200/240. Score. **Expected: ≈35/60** (±2).

Each reindex is 30–50 min. Total Phase 5 budget: ~2h. The NL score
lines up with the historical NLEmbedding score; the nomic score
lines up with the experiment baseline.

Scoring follows `bean-test.md` exactly — no rubric changes.

After the two sanity sweeps, leave the DB in its `nomic` 1200/240
state. Per the task instructions, reindex at the default config
before exiting if the user's real DB was affected.

## Rollout sequence (Phase 3 order)

Small commits, `swift test` green between each:

1. **Protocol + error type** — `Embedder.swift`, `EmbedderError`.
   No behavior change yet, nothing imports it.
2. **NomicEmbedder** — rename `EmbeddingService` → `NomicEmbedder`,
   conform to protocol. Update test and CLI references mechanically.
   179 tests still pass.
3. **NLEmbedder** — new file, actor-wrapped. Add
   `NLEmbedderConcurrencyTests`.
4. **EmbedderFactory** — static `make(name:)` + canonical-name helper.
5. **DatabaseConfig update** — nested `EmbedderConfig` + optional
   field. Decode path covers pre-refactor configs.
   `EmbedderConfigTests` covers round-trip + nil.
6. **EmbedderPool genericization** — pool takes an `Embedder` in
   init. `IndexingPipeline.init` takes an embedder.
7. **CLI flag + resolution** — `--embedder` on `update-index`,
   mismatch refusal, first-run persist, search auto-resolve, info
   line, reset-clears. Rest of `EmbedderConfigTests` lands here.
8. **VectorDatabase dim check** — optional belt-and-braces.

Each step is one commit. Tests green at every commit — no commit
that leaves the tree broken.

## Risks / knowns

- **NLEmbedding may return `nil`** on unusual input. Pre-nomic code
  handled this by skipping the chunk (returning `nil` from
  `embed()`). The protocol signature throws — so `NLEmbedder`
  converts nil → `EmbedderError.embedFailed`. The pipeline's embed
  task catches thrown errors and treats the chunk as failed, same
  behavior as today. Verified at IndexingPipeline.swift:355-365.
- **Model weight cache churn**: both models live in
  `~/Documents/huggingface/…` for nomic and the system cache for
  NLEmbedding. No duplication; switching between them costs only a
  one-time NL model load (~50 MiB) in addition to the already-cached
  nomic weights (~525 MiB resident).
- **Actor-hop cost for `name`/`dimension`**: avoided by making them
  `nonisolated let`.
- **Existential `any Embedder` on the hot path**: the call-site cost
  is a single v-table dispatch per chunk. Embed cost per chunk is
  order-milliseconds for NL and order-tens-of-ms for nomic. The
  dispatch is noise.
- **Pre-refactor DB, user flips embedder**: documented workflow is
  `vec reset` then `vec update-index --embedder <new>`. The CLI
  enforces this because mismatch errors out. There is no silent
  migration.

## Out-of-scope reminders

- No llama.cpp. Only the protocol slot. The design doc
  (`pluggable-embedders.md`) includes a "how to add llama" section
  so the next agent has a concrete starting point.
- No multi-embedder-per-DB. One DB, one embedder. Mixing embeddings
  from different models in one cosine-distance space produces
  garbage rankings.
- No weighted fusion of NL + nomic. That's hybrid retrieval, a
  different lever.
- No schema migration. Pre-refactor DBs get a one-shot `vec reset`
  instruction. Single-user tool.
