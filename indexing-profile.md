# Indexing Profile

## What this is

`vec` indexes a directory at a specific *indexing profile* — a
self-contained bundle of every parameter that affects how text becomes
vectors: the embedder, the chunk splitter, the chunk size, and the
chunk overlap. The profile is picked at first-index time, stamped
into the database's `config.json`, and every subsequent operation on
the database (`search`, `insert`, `update-index`, `info`, `list`)
runs against the *same* profile.

If two profiles differ in any of those four parameters, their vectors
are not comparable. Re-indexing one file with a different chunk size
and searching with the original profile's embedder would silently
return nonsense. The profile identity is what prevents that: it
commits the full parameter bundle to a single string the database
can match against on every open.

Eight built-in profiles ship today:

| Alias            | Canonical identity         | Embedder                | Dim  | Chunk size | Chunk overlap | Total /60  | Both-top10 /10 | Index wall¹ | ch/s¹  |
| ---------------- | -------------------------- | ----------------------- | ---- | ---------- | ------------- | ---------- | -------------- | ----------- | ------ |
| `e5-base`        | `e5-base@1200/0`³          | `e5-base-v2`            |  768 | 1200 chars | 0 chars       | **40**     | **6**          | 1025 s      | 7.3    |
| `bge-base`       | `bge-base@1200/240`        | `bge-base-en-v1.5`      |  768 | 1200 chars | 240 chars     | 36         | 3              | 1003 s      | 8.1    |
| `nomic`          | `nomic@1200/240`           | `nomic-v1.5-768`        |  768 | 1200 chars | 240 chars     | 35         | 3              | 1417 s²     | 5.8²   |
| `bge-large`      | `bge-large@1200/0`³        | `bge-large-en-v1.5`     | 1024 | 1200 chars | 0 chars       | 34         | 3              | 3220 s      | 2.3    |
| `bge-small`      | `bge-small@1200/0`³        | `bge-small-en-v1.5`     |  384 | 1200 chars | 0 chars       | 30         | 2              | 610 s       | 12.3   |
| `gte-base`       | `gte-base@1600/0`³         | `gte-base-en-v1.5`      |  768 | 1600 chars | 0 chars       | 8⁴         | 0              | 974 s       | 5.9    |
| `nl`             | `nl@2000/200`              | `nl-en-512`             |  512 | 2000 chars | 200 chars     | 6          | 0              | 138 s       | 35.0   |
| `nl-contextual`  | `nl-contextual@1200/240`   | `nl-contextual-en-512`  |  512 | 1200 chars | 240 chars     | 3          | 0              | 52 s        | 157.1  |

¹ Wall-clock and chunks-per-second for a full reindex of the
`markdown-memory` corpus (674 files; chunk counts vary with the
profile's chunk geometry — 8170 chunks at 1200/240, 7528 chunks at
1200/0, 4828 chunks for `nl` at 2000/200, 5760 chunks at 1600/0),
10-core Apple Silicon, pool=10, batch=16, release build. `bge-base`
row is from the E4 batched commit; `bge-small` / `bge-large` rows are
from the E5.4 sweep peaks; `gte-base` is from the E5.6 sweep peak;
`e5-base` is from the E5.7 sweep peak. Per-model sweep data:
[`data/retrieval-bge-small-sweep.md`](./data/retrieval-bge-small-sweep.md),
[`data/retrieval-bge-base-sweep.md`](./data/retrieval-bge-base-sweep.md),
[`data/retrieval-bge-large-sweep.md`](./data/retrieval-bge-large-sweep.md),
[`data/retrieval-gte-base-sweep.md`](./data/retrieval-gte-base-sweep.md),
[`data/retrieval-e5-base-sweep.md`](./data/retrieval-e5-base-sweep.md).
`ch/s` is `chunks ÷ wall`. Full per-stage breakdown for the E4
baseline in `data/wallclock-e4-per-model.md`.

² `nomic` is pinned to `computePolicy: .cpuOnly` to work around a
CoreML/ANE compile failure ("Incompatible element type for ANE") on
macOS 26.3.1+. The 1417 s wallclock is therefore CPU-only and not
directly comparable to the other rows, which leave placement to the
compiler. Historical wallclock at the same config on the pre-E4 code
path (with ANE) was ~2940 s. See
`NomicEmbedder.batchEncode` and
`data/wallclock-e4-per-model.md` for detail.

³ All `@<size>/<overlap>` defaults carrying this footnote were tuned
by full chunk×overlap sweeps, not seeded. Peaks at size 1200 split
along a single-axis: `bge-small`, `bge-large`, `gte-base`, and
`e5-base` all **reject** overlap at 1200 (peak at 0); `bge-base`
uniquely **benefits** from overlap at 1200 (peak at 240). The
pattern is not monotone in embedding dimension (bge-base is the
only outlier, sitting in the middle at 768-dim) and does not line
up with distillation status either (bge-base and gte-base are both
distilled; only bge-base likes overlap). `bge-base@1200/240` and
`bge-base@800/80` were a two-way tie at 36/60 (E5.4d); kept at
1200/240 to match the historical default. `gte-base`'s peak is
1600/0 rather than 1200/0 but the overlap-rejection pattern is the
same across sizes. `e5-base@1200/0` at **40/60, 6/10 both-top10** is
the first model to beat the current global default (bge-base's
36/60, 3/10 both-top10) — see the e5-base sweep data file for the
three-way 768-dim cross-model comparison and the global-default
candidacy notes. The original single-point E5.2/E5.3 measurements
for bge-small/bge-large at the seeded 1200/240 geometry are
preserved in
[`data/retrieval-bge-small.md`](./data/retrieval-bge-small.md) and
[`data/retrieval-bge-large.md`](./data/retrieval-bge-large.md) as
historical data points.

⁴ `gte-base` is registered as a built-in but is NOT a default
candidate on markdown-memory. Its 8/60 peak is 28 points below
bge-base on the same corpus despite being a same-dim peer (768-dim,
distilled). The sweep diagnosed a content-discrimination failure:
cosine similarities pack into a narrow 0.75–0.78 band (anisotropy)
and the rubric's target files are buried under unrelated meetings
at most grid points. gte-base is retained for users who want a
non-BGE 768-dim option, but on this corpus it is below threshold.
See [`data/retrieval-gte-base-sweep.md`](./data/retrieval-gte-base-sweep.md)
§2 for the full failure-mode analysis.

`bge-base` is the default. (Originally `nomic`; flipped 2026-04-19
after the Phase D sweep — see `experiments/PhaseD-embedder-expansion/plan.md` §"Default
alias decision".) `e5-base` is a live candidate to replace it —
it beats bge-base at every primary metric on markdown-memory
(40/60 vs 36/60 total, 6/10 vs 3/10 both-top10, wallclock parity,
same 768-dim storage geometry) and would be a clean swap. The
candidacy is intentionally unresolved pending cross-corpus
validation (blocked on the deferred E5.4e vec-source rubric) and
a direct call from the project owner. Source of truth for the
effective default is `IndexingProfileFactory.defaultAlias` in
`Sources/VecKit/IndexingProfile.swift`.

Rubric scores are each embedder running at its own built-in chunk/
overlap (the identity above), scored against the markdown-memory
corpus using `retrieval-rubric.md`. Two columns because they
measure different things:

- **Total /60** — weighted sum across the 10 queries, counting every
  query's T (transcript) and S (summary) targets and their rank
  brackets. Rewards partial hits: a query where only S surfaces in
  top 10 still scores. This is the primary metric.
- **Both-top10 /10** — stricter secondary metric: the count of
  queries where *both* T and S landed in top 10 simultaneously.
  Doesn't reward a query with only one target surfaced. Used as a
  tiebreaker when Total /60 is close and as a quality signal when
  it moves sharply without a corresponding Total shift (e.g.
  e5-base vs bge-base at +4 Total, +3 Both-top10 — the stricter
  metric doubled, indicating a larger real retrieval improvement
  than the Total delta alone suggests).

Full per-iteration sweeps (other chunk/overlap combos) live in
`data/retrieval-<alias>.md`.

## CLI surface

```sh
# First index: profile is chosen here and recorded on the DB.
vec init mydb
vec update-index --embedder nomic                    # records nomic@1200/240
vec update-index --embedder nl                       # records nl@2000/200
vec update-index --embedder nomic \
                 --chunk-chars 500 --chunk-overlap 100   # records nomic@500/100

# Subsequent runs: omit --embedder / chunk flags and vec re-uses
# whatever the DB has recorded. Passing a mismatched value refuses:
vec update-index                                     # uses recorded profile
vec update-index --embedder nl                       # refuses if recorded as nomic
# → Database was indexed with profile 'nomic@1200/240' but the command
#   requested 'nl@2000/200'. Either match the recorded profile or run
#   'vec reset' to re-index at a different one.

# search / insert auto-resolve:
vec search "query text"                              # uses recorded profile
vec insert path/to/file.md                           # uses recorded profile

# reset clears the recorded profile; the next update-index picks fresh:
vec reset
vec update-index --embedder nl                       # records nl@2000/200
```

`vec info` renders the recorded profile on its own line. `vec list`
includes a `Profile` column per database. Both surface the same four
states the config supports — see *Config shape* below.

## Identity grammar

A profile identity is one string, always of the form:

```
<alias>@<chunkSize>/<chunkOverlap>
```

- `alias` is the short string the user typed on `--embedder` — one
  of `IndexingProfileFactory.knownAliases`. The currently-registered
  aliases are listed in the table at the top of this file.
- `chunkSize` and `chunkOverlap` are the literal character counts
  the splitter runs with.

Examples:

- `bge-base@1200/240` — bge-base's built-in default (current default
  alias).
- `nomic@1200/240` — nomic's built-in default.
- `nl@2000/200` — nl's built-in default.
- `bge-base@500/100` — bge-base with user-supplied chunk overrides.

The identity is parsed with `IndexingProfileFactory.parseIdentity(_:)`.
Any deviation from the grammar (wrong separator, non-numeric chunk
params, missing alias, etc.) throws `VecError.malformedProfileIdentity`.
A corrupt identity on disk is a hard failure — we never guess what
the user meant.

## Three layers of naming

There are three layers of naming, and they are separate on purpose:

- **Alias** — the short string the user types on the CLI (`nomic`,
  `nl`). Stable, memorable, scoped to
  `IndexingProfileFactory.knownAliases`.
- **Built-in descriptor** (`IndexingProfileFactory.BuiltIn`) — the
  static registry row for an alias: its canonical embedder name,
  canonical dimension, and default chunk size / overlap. Pure
  data; no live embedder is instantiated until `make(...)` is
  called.
- **Identity** — the full `<alias>@<size>/<overlap>` string that
  gets persisted. Uniquely names *this specific* parameter bundle.
  Two identities with the same alias but different chunk params
  are distinct profiles and will mismatch against each other.

The split matters because the alias alone does not uniquely
identify a profile. `nomic@1200/240` and `nomic@500/100` both use
the `nomic` embedder, but their vectors came from text chunked at
different sizes — mixing them in one DB would produce incoherent
results. The identity encodes that difference.

## The profile struct

```swift
public struct IndexingProfile: Sendable {
    public let identity: String
    public let embedder: any Embedder
    public let splitter: TextSplitter
    public let chunkSize: Int
    public let chunkOverlap: Int
    public let isBuiltIn: Bool
}
```

Two profiles with the same `identity` must produce comparable
vectors — that is the contract the mismatch check relies on. The
`isBuiltIn` flag is true if and only if the effective chunk params
equal the alias's registered defaults; a custom chunk override
flips it to false even if the numbers happen to round-trip through
the identity string.

## Config shape

`DatabaseConfig` in `DatabaseLocator.swift`:

```swift
public struct DatabaseConfig: Codable {
    public let sourceDirectory: String
    public let createdAt: Date
    public let profile: ProfileRecord?

    public struct ProfileRecord: Codable, Equatable {
        public let identity: String           // e.g. "nomic@1200/240"
        public let embedderName: String       // canonical, e.g. "nomic-v1.5-768"
        public let dimension: Int             // 768
    }
}
```

`profile` is optional so four states decode and render cleanly:

- **Built-in indexed DBs** — `profile` carries a record whose
  identity matches a built-in (e.g. `bge-base@1200/240`,
  `nomic@1200/240`, `nl@2000/200`). `vec info` prints
  `bge-base@1200/240 (768d)`.
- **Custom indexed DBs** — `profile` carries a record whose chunk
  params differ from the alias's defaults (e.g. `bge-base@500/100`).
  `vec info` prints `bge-base@500/100 (custom, based on bge-base) (768d)`
  to make the deviation visible.
- **Freshly initialized or reset DBs** — `profile == nil` *and*
  `chunks.count == 0`. `vec init` and `vec reset` both write this
  shape. `vec info` prints `(not yet recorded)`. The next
  `update-index` is free to pick any profile.
- **Pre-profile DBs** — `profile == nil` *but* `chunks.count > 0`.
  These are DBs written before the profile field existed. They hold
  vectors of unknown provenance, so every profile-aware command
  hard-fails with `VecError.preProfileDatabase` and asks the user
  to `vec reset` before continuing.

Why the denormalized `embedderName` and `dimension` on
`ProfileRecord`? Because the command layer needs to open the
underlying `VectorDatabase` with a dimension *before* it resolves
the profile. Reading the dimension off the record is cheap and
doesn't require the factory (which can throw on unknown aliases —
a separate failure mode we want to surface with its own error
message, not a failed DB open).

`DatabaseConfig` is written to disk *before* the indexing pipeline
runs. If a run crashes mid-embed, the DB is in a consistent state:
partial vectors exist and they all came from the profile the config
names.

## Check-order on every DB-opening command

Every command that opens a database runs the same six-step dance in
`run()`:

1. **Partial-override guard.** If exactly one of `--chunk-chars` /
   `--chunk-overlap` was supplied, throw
   `VecError.partialChunkOverride` immediately, before touching the
   DB. Chunk params are a pair or nothing at all.
2. **Resolve DB.** Look up `~/.vec/<name>/` from the `--db` flag or
   by matching the cwd against recorded `sourceDirectory` entries.
3. **Open and count chunks.** Open the `VectorDatabase` at the
   recorded dimension (or a placeholder dim if `profile == nil`)
   purely to read `totalChunkCount()`. The chunk count is what
   separates a fresh DB from a pre-profile DB before any profile
   resolution happens.
4. **Missing-profile split.** If `config.profile == nil`:
   - `chunkCount > 0` → throw `VecError.preProfileDatabase`.
   - `chunkCount == 0` → throw `VecError.profileNotRecorded`
     (read-side commands like `search`, `insert`) or proceed to
     step 5 (`update-index`'s first-index path).
5. **Resolve live profile.** Call
   `IndexingProfileFactory.resolve(identity:)` on the recorded
   identity. Throws `VecError.unknownProfile` or
   `VecError.malformedProfileIdentity` if the recorded alias or
   identity string is no longer supported.
6. **Match and run.** For `update-index`, compare the recorded
   identity against the identity the CLI requested (alias +
   optional overrides). Any difference → `VecError.profileMismatch`.
   For `search` / `insert`, there's nothing to compare; just run.

Steps 1–4 are cheap (no model load) and surface all the
pre-conditions before anything expensive happens. Step 5 is the
only step that instantiates a live embedder.

## Rule on partial overrides

The CLI rejects `--chunk-chars` without `--chunk-overlap` (or vice
versa) with `VecError.partialChunkOverride`. Chunk size and overlap
are not independent knobs — overlap is expressed in characters and
must be strictly less than `chunkSize`. Defaulting the missing one
to its alias's built-in would silently pair a user-chosen size with
a default overlap, which is almost never what they meant.

Make both explicit, or make neither. No inheritance.

## Strict no-inheritance

A corollary of the partial-override rule: a custom profile does not
"inherit" the alias's defaults except for what is strictly implied
by the alias itself (the embedder and its canonical dimension). If
you run `update-index --embedder nomic --chunk-chars 500
--chunk-overlap 100`, you get a profile with identity
`nomic@500/100`, `isBuiltIn == false`, and the nomic embedder. It
is *not* treated as "nomic-with-a-tweak" — the DB records it as its
own profile and the mismatch check will reject anything that
doesn't match `nomic@500/100` exactly.

This is deliberate. Inheritance would let two subtly different
profiles share a name, which defeats the whole point of identity-
based matching.

## The pipeline wiring

`IndexingPipeline` takes a profile, not a raw embedder:

```swift
let profile = try IndexingProfileFactory.make(alias: IndexingProfileFactory.defaultAlias)
let pipeline = IndexingPipeline(profile: profile)
let extractor = TextExtractor(splitter: profile.splitter)
try await pipeline.run(workItems: ..., extractor: extractor, database: db)
```

Two things to note:

1. **The splitter comes off the profile.** Before this refactor,
   `TextExtractor()` defaulted to a hardcoded
   `RecursiveCharacterSplitter` with constants baked into the
   splitter type. Profiles decoupled those defaults: every built-in
   carries its own `defaultChunkSize` / `defaultChunkOverlap`, and
   the live splitter is constructed from the effective params
   (defaults *or* CLI overrides). A `TextExtractor()` with no
   argument still works for tests, but it sources its splitter
   from the default built-in's registered defaults — no hardcoded
   constants on the splitter type.
2. **The pipeline takes the whole profile, not just the embedder.**
   Future profile-aware work (different embedder warm-up strategies,
   per-profile batch sizes, etc.) lives behind a single parameter.

## Extending the registry

Adding a new embedder is:

1. Implement `Embedder` on a new type (see `NomicEmbedder` /
   `NLEmbedder` for working examples).
2. Add one row to `IndexingProfileFactory.builtIns` with the alias,
   canonical name, dimension, and default chunk params.
3. Add one case to the `make(alias:chunkSize:chunkOverlap:)` switch
   that instantiates the new type.

Nothing else changes. `DatabaseConfig`, the pipeline, the mismatch
machinery, and every CLI command already route through
`IndexingProfileFactory` and `Embedder`.

## Deferred: `--splitter`

Today the splitter is coupled to the embedder via the
`BuiltIn` registry — every built-in comes with exactly one
splitter and one pair of chunk defaults. A future `--splitter`
flag (letting users pick between `RecursiveCharacterSplitter`,
`LineBasedSplitter`, and friends independently of embedder) is
deliberately out of scope for this refactor.

When that flag ships, the identity grammar will need to grow a
fourth component (probably
`<alias>/<splitter>@<size>/<overlap>`) and the parser /
constructor will need a fourth knob. The current grammar is
compact enough that we didn't pre-allocate that slot — it'd be
dead weight on every persisted identity until the flag exists.

## Extension points

Open directions the current shape already supports:

- **Per-profile preprocessing.** Some embedders benefit from
  normalization or stop-word stripping before embedding. A
  `preprocess(_:)` hook on `Embedder` (with a no-op default) would
  plug in without touching the profile grammar.
- **Per-profile query shaping.** The `Embedder` protocol's
  `embedQuery` / `embedDocument` split lets each embedder apply its
  own asymmetric preprocessing without touching callers. Registered
  examples span three patterns: Nomic prepends `search_query: ` /
  `search_document: ` (symmetric but prefix-different); e5-base
  prepends `query: ` / `passage: ` (same shape, different strings);
  later work may want query-only prefixes or full re-ranking paths.
  All fit behind the same split.
- **Non-character chunking.** Token-count-based chunking would need
  a different identity encoding (`nomic@T256/T64` to distinguish),
  but the profile struct already carries `chunkSize` and
  `chunkOverlap` as plain `Int`s — the meaning is up to the
  splitter.
