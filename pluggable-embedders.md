# Pluggable Embedders

## What this is

`vec` can index a directory with different text-embedding backends. Which backend to use is picked with `--embedder` at index time and persisted in the database's `config.json` so subsequent `search`, `insert`, and `update-index` calls use the same one automatically.

Two backends ship today:

| Alias   | Canonical name    | Dimension | Model / provider                                   |
| ------- | ----------------- | --------- | -------------------------------------------------- |
| `nomic` | `nomic-v1.5-768`  | 768       | `nomic-embed-text-v1.5` via `swift-embeddings`     |
| `nl`    | `nl-en-512`       | 512       | Apple `NLEmbedding.sentenceEmbedding(for: .english)` |

`nomic` is the default.

## CLI surface

```sh
# First index: embedder is chosen here and recorded on the DB.
vec init mydb
vec update-index --embedder nomic        # or --embedder nl

# Subsequent runs: omit --embedder and vec re-uses whatever the DB
# has recorded. Passing it with a mismatched value refuses hard:
vec update-index                         # uses recorded embedder
vec update-index --embedder nl           # refuses if DB is recorded as nomic
# → Database was indexed with 'nomic-v1.5-768' (--embedder nomic) but
#   --embedder nl was requested. Either pass the matching embedder or
#   run 'vec reset' to re-index with a different one.

# search / insert auto-resolve:
vec search "query text"                  # uses recorded embedder
vec insert path/to/file.md               # uses recorded embedder

# reset clears the recorded embedder; the next update-index picks fresh:
vec reset
vec update-index --embedder nl
```

`vec info` prints a line like `Embedder: nomic-v1.5-768 (768d)` when an embedder is recorded. Before the first successful index, that line reads `Embedder: (not yet recorded)`.

## Why two names per backend

There are two layers of naming and they are separate on purpose:

- **Alias** — the short string the user types on the CLI (`nomic`, `nl`). Stable, memorable, scoped to `EmbedderFactory.knownAliases`.
- **Canonical name** — what the `Embedder` instance reports via `.name` and what is persisted in `DatabaseConfig.embedder.name` (e.g. `nomic-v1.5-768`). Uniquely identifies the model + dimension so a future change to which model the `nomic` alias resolves to can be detected as a mismatch on existing DBs.

`EmbedderFactory.alias(forCanonicalName:)` maps back the other way so error messages can show the user the alias to type (`--embedder nomic`) instead of the raw canonical name.

## The protocol

```swift
public protocol Embedder: Sendable {
    nonisolated var name: String { get }
    nonisolated var dimension: Int { get }
    func embedDocument(_ text: String) async throws -> [Float]
    func embedQuery(_ text: String) async throws -> [Float]
}
```

Two deliberate choices:

1. **`name` and `dimension` are `nonisolated`.** They are invariant metadata — fixed for the lifetime of the instance — so callers (the DB writer, the CLI, `EmbedderPool`) can read them synchronously without hopping onto an actor. Conformers back them with `nonisolated let` on the actor.

2. **Separate `embedDocument` / `embedQuery`.** Some models (nomic being the current example) were trained with an asymmetric index/query convention — nomic prepends `search_document: ` at index time and `search_query: ` at search time. Models without that training (NL) just implement both identically. Baking the distinction into the protocol means callers always do the right thing regardless of which backend is wired in.

## Database config shape

`DatabaseConfig` in `DatabaseLocator.swift`:

```swift
public struct DatabaseConfig: Codable {
    public let sourceDirectory: String
    public let createdAt: Date
    public let embedder: EmbedderRecord?       // nil on fresh/pre-refactor DBs

    public struct EmbedderRecord: Codable, Equatable {
        public let name: String                // canonical, e.g. "nomic-v1.5-768"
        public let dimension: Int
    }
}
```

`embedder` is optional so three states decode cleanly:

- **Pre-refactor DBs** written before this field existed — the JSON has no `embedder` key, which Swift's `JSONDecoder` happily maps to `nil`. Before the refactor, vec shipped exactly one embedder (nomic-embed-text-v1.5, 768d), so these DBs contain nomic-produced vectors by construction. `DatabaseLocator.migratePreRefactorEmbedderRecord` auto-stamps `nomic-v1.5-768` on any pre-refactor config whose DB has at least one chunk. `search`, `insert`, `update-index`, and `info` all invoke this right after reading the config, so an upgraded user's existing DB keeps working without a reindex.
- **Freshly initialized or reset DBs** — `vec init` / `vec reset` both write a config with `embedder: nil` **and an empty chunks table**. The migration helper is a no-op on an empty DB (there are no vectors to attribute to anyone), so the next `update-index` is free to pick any embedder.
- **Indexed DBs** — `embedder` is set to the `EmbedderRecord` of whatever was used.

The embedder record is written to `config.json` **before** the indexing pipeline runs. If a run crashes mid-embed, the DB is in a consistent state: partial vectors exist and they all came from the embedder the config names.

## Pipeline wiring

`IndexingPipeline` takes an embedder explicitly:

```swift
let embedder = try EmbedderFactory.make(alias: "nomic")
let pipeline = IndexingPipeline(embedder: embedder)
try await pipeline.run(workItems: …, extractor: …, database: db)
```

Inside, `EmbedderPool` is genericized over `any Embedder`:

```swift
actor EmbedderPool {
    private nonisolated let embedder: any Embedder
    init(embedder: any Embedder) { self.embedder = embedder }
    func acquire() async -> any Embedder { embedder }
    nonisolated var name: String { embedder.name }
    nonisolated var dimension: Int { embedder.dimension }
}
```

The pool is still single-instance — every embed task awaits the same underlying actor. This is intentional:

- `NLEmbedding.sentenceEmbedding` is documented as not thread-safe and older versions of this codebase caused crashes when called concurrently; actor serialization was already the fix.
- `NomicBert` (MLTensor-backed) is thread-safe at the model-call level, but in practice a single shared instance is cheaper on memory (the model weights aren't duplicated) and throughput is embed-bound on one instance anyway since the CPU/GPU is saturated.

If a future embedder wants multiple instances, `EmbedderPool` is the place to grow that.

## Dimension guard

As a belt-and-braces check, `VectorDatabase.insert` and `.search` throw `VecError.dimensionMismatch(expected:actual:)` if the vector handed in doesn't match the DB's declared `dimension`. The CLI already refuses the embedder mismatch at the config layer, so this only fires on direct library misuse (e.g. future code that builds an `IndexingPipeline` without going through `UpdateIndexCommand`). It's cheap to keep and it catches one more class of bug.

## Mismatch semantics

`update-index` refuses rather than falls back. The rule:

| DB recorded embedder | `--embedder` passed | Behavior                                                   |
| -------------------- | ------------------- | ---------------------------------------------------------- |
| none                 | omitted             | Use `EmbedderFactory.defaultAlias` (`nomic`), record it.   |
| none                 | `X`                 | Use `X`, record it.                                        |
| `Y`                  | omitted             | Use recorded `Y`.                                          |
| `Y`                  | `Y`                 | Use `Y`.                                                   |
| `Y`                  | `X` (≠ `Y`)         | Refuse with `embedderMismatch`. User must `vec reset`.     |

`search` and `insert` refuse if no embedder is recorded (DB has never been indexed — they have no basis to pick one). Silent fallback was considered and rejected: if a DB ends up with mixed-embedder vectors, nearest-neighbor results become meaningless and the failure mode is silent. A hard refusal with a clear remediation (`vec reset`) is better.

## Tests

- **`NomicEmbedderConcurrencyTests` / `NLEmbedderConcurrencyTests`** — 20-task concurrency canaries that fan out `embedDocument` calls against one shared actor and assert every return is a 768/512-dim vector. Guards against regressions in the underlying model's thread-safety story.
- **`EmbedderConfigTests`** — `DatabaseConfig` JSON round-trip with and without `EmbedderRecord`, pre-refactor-JSON decode (no `embedder` key → nil), and `EmbedderFactory` alias ↔ canonical round-trip including the `unknownEmbedder` error.
- **`SmokeTest`** — end-to-end index of a 3-file directory asserting 768-byte blobs land in SQLite.
- **Existing integration/scan tests** — all continue to use `NomicEmbedder` by default; the pipeline's `embedder:` argument is passed explicitly.

188 tests pass with 1 skipped.

## How to add a third embedder (e.g. llama)

1. Create `Sources/VecKit/LlamaEmbedder.swift` with an `actor LlamaEmbedder: Embedder` conformance. Set `nonisolated let name = "llama-<model>-<dim>"` and `nonisolated let dimension = <N>`. Implement `embedDocument`/`embedQuery` (identical if the model isn't trained with asymmetric prefixes).

2. Extend `EmbedderFactory`:
   ```swift
   public static let knownAliases: [String] = ["nomic", "nl", "llama"]

   public static func make(alias: String) throws -> any Embedder {
       switch alias {
       case "nomic": return NomicEmbedder()
       case "nl":    return NLEmbedder()
       case "llama": return LlamaEmbedder()
       default:      throw VecError.unknownEmbedder(alias)
       }
   }
   ```

3. Mirror `NomicEmbedderConcurrencyTests` for the new type (20-task canary asserting the correct dim).

4. Update the `--embedder` help text in `UpdateIndexCommand.swift` to include `llama`.

Nothing else has to change. `DatabaseConfig`, the pipeline, the mismatch machinery, and the CLI commands all already route through `EmbedderFactory` and `Embedder`.

## Things that deliberately don't change per embedder

- **Chunking.** `RecursiveCharacterSplitter` defaults (1200 char chunk size / 240 overlap) were tuned empirically for nomic but apply to every backend. If a future embedder needs different chunking, the splitter is already a separate type and can take a per-embedder config later.
- **Max input truncation.** Each `Embedder` implementation enforces its own `maxInputCharacters` internally (`NomicEmbedder.maxInputCharacters = 30_000` for the 2k-token window; `NLEmbedder.maxInputCharacters = 10_000` for a `std::bad_alloc` guardrail observed in practice). `TextExtractor` also caps at `NomicEmbedder.maxInputCharacters` as an early bound — both layers re-truncate, which is harmless.
- **SQLite schema.** The `chunks.embedding` column stores raw Float32 blobs — `N × 4` bytes. `VectorDatabase(dimension:)` controls the `N`, so the schema itself is dimension-agnostic.

## Files

| File                                          | Role                                                            |
| --------------------------------------------- | --------------------------------------------------------------- |
| `Sources/VecKit/Embedder.swift`               | Protocol + `EmbedderError`.                                     |
| `Sources/VecKit/NomicEmbedder.swift`          | 768-dim nomic-embed-text-v1.5 backend.                          |
| `Sources/VecKit/NLEmbedder.swift`             | 512-dim Apple NLEmbedding backend.                              |
| `Sources/VecKit/EmbedderFactory.swift`        | Alias → instance; canonical ↔ alias mapping.                    |
| `Sources/VecKit/DatabaseLocator.swift`        | `DatabaseConfig.embedder: EmbedderRecord?`.                     |
| `Sources/VecKit/FileScanner.swift`            | `VecError.unknownEmbedder` / `embedderMismatch` / `embedderNotRecorded` / `dimensionMismatch`. |
| `Sources/VecKit/IndexingPipeline.swift`       | `IndexingPipeline(embedder:)`, generic `EmbedderPool`.          |
| `Sources/VecKit/VectorDatabase.swift`         | Dim guard on insert/search.                                     |
| `Sources/vec/Commands/UpdateIndexCommand.swift` | `--embedder` flag, mismatch refusal, record on first index.   |
| `Sources/vec/Commands/SearchCommand.swift`    | Auto-resolve from recorded embedder; refuse if none.            |
| `Sources/vec/Commands/InsertCommand.swift`    | Auto-resolve from recorded embedder; refuse if none.            |
| `Sources/vec/Commands/InfoCommand.swift`      | `Embedder: <name> (<dim>d)` line.                               |
