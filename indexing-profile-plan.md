# IndexingProfile — Plan

Agent: `agent-77b5f3be` (2026-04-18)

## Goal

Collapse every parameter that affects how text becomes vectors — embedder,
splitter, chunk size, chunk overlap — into a single `IndexingProfile`
value. Persist the resolved profile identity on `DatabaseConfig` so
`update-index`, `insert`, and `search` can all detect a mismatch and
hard-fail before building vectors at the wrong shape.

Today those parameters are scattered across three call-sites: the
embedder alias comes from `--embedder` on `UpdateIndexCommand`,
chunk sizing comes from `--chunk-chars`/`--chunk-overlap` (with defaults
hardcoded on `RecursiveCharacterSplitter`), and the splitter choice is
implicit (only `RecursiveCharacterSplitter` is wired in). The result:
the DB records the embedder but has no idea what chunk settings or
splitter the existing vectors were produced with. A user who reindexed
with nomic at 500/100 and then ran `vec search` the next day could get
stale numbers without any warning.

`IndexingProfile` makes that impossible. One struct, one identity, one
comparison, one error if they drift.

Non-goals: changing retrieval quality, adding new embedders or
splitters, llama.cpp, hybrid retrieval, BM25, migration of pre-refactor
or pre-profile DBs.

## Ship criteria

1. `IndexingProfile` struct bundles: embedder (instance), splitter
   (`any TextSplitter`), chunk size (chars), chunk overlap (chars),
   display name, and a canonical `identity` string used for
   exact-match comparison.
2. Two built-in profiles ship with canonical identities:
   - `nomic@1200/240` → `NomicEmbedder` + `RecursiveCharacterSplitter(1200, 240)`
   - `nl@2000/200` → `NLEmbedder` + `RecursiveCharacterSplitter(2000, 200)`
3. `EmbedderFactory` is renamed `IndexingProfileFactory`. The alias
   table maps `nomic` / `nl` to a built-in profile descriptor (canonical
   embedder name, canonical dim, default chunk size, default overlap).
   A `make(alias:)` call returns a fully constructed profile.
4. `--embedder nomic` / `--embedder nl` selects a built-in profile with
   its defaults. `--chunk-chars N` **and** `--chunk-overlap M` must be
   supplied together to override; passing exactly one without the other
   is a hard-fail with `VecError.partialChunkOverride` (see §"The fatal
   mismatch error text"). Both present → derived profile with identity
   `alias@N/M` (e.g. `nomic@500/100`). Neither present → alias-default
   identity (`nomic@1200/240`). No inheritance of a single chunk value
   from alias-defaults or from the recorded profile. Strict no-
   inheritance also means "neither chunk flag present" always resolves
   to the alias-default chunk params, never to the recorded custom
   chunk params — so bare `vec update-index` on a recorded custom-chunk
   DB (e.g. `nomic@500/100`) will hard-fail with `profileMismatch`
   because the requested identity is `nomic@1200/240` (alias-default)
   and does not equal the recorded `nomic@500/100`.
5. `DatabaseConfig.profile` replaces `DatabaseConfig.embedder`. It
   carries the full resolved identity, not just the embedder name +
   dim. Present on every DB past the cutover.
6. Mismatch between the resolved profile and the recorded profile is a
   hard fatal error from every command (`update-index`, `insert`,
   `search`). The error prints what was recorded, what was resolved,
   and tells the user their two options: pass the matching flags or
   `vec reset`. No silent fallback, no partial match, no auto
   migration.
7. Existing DBs (pre-profile, including ones with the
   `embedder: EmbedderRecord?` shape) hard-fail on next access. The
   error tells the user to `vec reset` + reindex. This is acceptable —
   single-user tool, no install base to protect.
8. `RecursiveCharacterSplitter` loses its `defaultChunkSize`/
   `defaultChunkOverlap` constants. Chunk defaults live on each
   `IndexingProfile` only.
9. `UpdateIndexCommand` no longer references `RecursiveCharacterSplitter.defaultChunkSize`
   or `defaultChunkOverlap` in its help text — the help comes from the
   resolved default profile.
10. Test coverage:
    - `IndexingProfileTests` — identity construction, override
      composition (full override only; partial is a CLI-layer concern),
      strict identity parsing (good + bad), round-trip through the DB
      config.
    - `IndexingProfileConfigTests` (renamed from `EmbedderConfigTests`)
      — new profile shape round-trip; pre-profile DB JSON decodes to
      `profile == nil` so `readConfig` itself doesn't crash (the
      subsequent "operation requires recorded profile" hard-fail
      belongs to each command).
    - `ProfileMismatchTests` — command-layer integration tests covering
      the five-case matrix: (a) recorded `nomic@1200/240`, request
      `--embedder nl` → `profileMismatch`; (b) recorded `nomic@1200/240`,
      request `--embedder nomic --chunk-chars 500 --chunk-overlap 100`
      → `profileMismatch`; (c) recorded `nomic@1200/240`, request
      `--embedder nomic` with no chunk overrides → succeeds; (d) DB
      with chunks but `profile == nil` → `preProfileDatabase`; (e)
      fresh DB (no chunks, `profile == nil`) with a `search`/`insert`
      invocation → `profileNotRecorded`. Also covers
      `partialChunkOverride` on `--chunk-chars 500` alone.
    - `TrademarkTranscriptFixtureTests` extended: a single parameterized
      test loops over `IndexingProfileFactory.builtIns` and verifies
      extraction + embed for every profile. New profile → new coverage
      for free.
11. Two retrieval-rubric sanity sweeps (Phase 5), matching historical scores:
    - `vec reset markdown-memory` → `update-index --embedder nl` →
      score ≈ 6/60 (±1).
    - `vec reset markdown-memory` → `update-index --embedder nomic` →
      score ≈ 35/60 (±2).
12. Design doc `indexing-profile.md` (200–300 lines) in the same tone
    as `archived/pluggable-embedders.md`.

## Design

### The profile struct

```swift
/// A self-contained bundle of every parameter that affects how text
/// becomes vectors. Two profiles with the same `identity` must produce
/// comparable vectors — differences in embedder, splitter, chunk size,
/// or overlap all change the identity string.
///
/// See `indexing-profile.md` for the naming convention and rationale.
public struct IndexingProfile: Sendable {

    /// Canonical identity string. Persisted on `DatabaseConfig.profile.identity`
    /// and used for exact-match comparison on every DB-opening command.
    /// Shape:
    ///   - Built-in (alias-default):   `"<alias>@<chunkSize>/<overlap>"`
    ///                                 e.g. `"nomic@1200/240"`
    ///   - Derived (CLI override):     `"<alias>@<chunkSize>/<overlap>"`
    ///                                 e.g. `"nomic@500/100"`
    /// The alias portion matches `IndexingProfileFactory.knownAliases`
    /// and the numbers are the actual effective chunk params.
    public let identity: String

    /// Embedder instance. Its `name` + `dimension` are the dim source of
    /// truth for the DB (`VectorDatabase(dimension:)`).
    public let embedder: any Embedder

    /// Splitter used by `TextExtractor`. Currently always a
    /// `RecursiveCharacterSplitter`; the field is `any TextSplitter` so
    /// a future `LineBasedSplitter` or semantic splitter can slot in
    /// without a struct shape change.
    public let splitter: any TextSplitter

    /// Effective chunk size (chars) used to build `splitter`. Kept on
    /// the profile as metadata so it round-trips through persistence
    /// cleanly — the splitter itself already holds the same number,
    /// but we don't ask it to expose it.
    public let chunkSize: Int

    /// Effective chunk overlap (chars).
    public let chunkOverlap: Int

    /// Whether this profile came straight from a factory alias with no
    /// CLI overrides. Purely informational — consumed only by `vec info`
    /// rendering to differentiate `Profile: nomic@1200/240 (768d)` (alias
    /// default) from `Profile: nomic@500/100 (custom, based on nomic)
    /// (768d)` (user-supplied override). See §"Open questions (answered)"
    /// Q6 for the keep/delete decision.
    public let isBuiltIn: Bool

    public init(
        identity: String,
        embedder: any Embedder,
        splitter: any TextSplitter,
        chunkSize: Int,
        chunkOverlap: Int,
        isBuiltIn: Bool
    ) {
        precondition(chunkSize > 0)
        precondition(chunkOverlap >= 0 && chunkOverlap < chunkSize)
        self.identity = identity
        self.embedder = embedder
        self.splitter = splitter
        self.chunkSize = chunkSize
        self.chunkOverlap = chunkOverlap
        self.isBuiltIn = isBuiltIn
    }
}
```

Why `identity` is a plain `String`, not a nested struct keyed by
(embedder, chunkSize, overlap): every call-site that persists or
compares the profile does it as a whole, and the CLI error text
wants to print a single human-readable token. The structural fields
(`embedder`, `chunkSize`, `chunkOverlap`) are available alongside
for the rare case where a command needs to inspect a component
without parsing the identity.

**Why a single merged `IndexingProfile` struct (not a descriptor +
materialized split).** Reviewer A asked whether
`ProfileDescriptor` (alias + chunk params, no live embedder) should
be split from the materialized `IndexingProfile` so tests can
compare identities without instantiating an embedder. We keep them
merged for two concrete reasons:

1. **Embedders are cheap to construct.** `NomicEmbedder()` and
   `NLEmbedder()` both return immediately — the underlying model
   lookup is an actor-hosted shared instance that loads lazily on
   first `embedDocument` call, not on `init`. Constructing an
   `IndexingProfile` at the top of a command does not pay the model-
   load cost; only the first embed call does. So "avoid touching
   the embedder just to compare identities" is not an actual win.
2. **No test needs to inspect identity without an embedder.** Every
   place that cares about the identity either (a) reads it off an
   existing live profile, (b) reads it off a persisted
   `ProfileRecord`, or (c) constructs one via
   `IndexingProfileFactory.make`, which produces a full profile
   anyway. The `ProfileMismatchTests` suite compares identity
   strings from two constructed profiles — no bare-descriptor path.
   `BuiltIn` (the static table row) already plays the "descriptor
   without live embedder" role for table iteration.

The split would add a layer without erasing any work. Kept merged.

Why the profile is *not* `Codable`: only the **identity string** is
persisted. On reopen, the command re-runs `IndexingProfileFactory.resolve(identity:)`
to rebuild the live profile from the identity. This means the DB
never stores a stale class name and the profile always picks up the
current embedder implementation.

### The factory / registry

```swift
/// Resolves CLI aliases and identity strings to live `IndexingProfile`
/// instances. Replaces `EmbedderFactory`. See `indexing-profile.md`.
public enum IndexingProfileFactory {

    /// Descriptor for a built-in profile. Static data only — no live
    /// `Embedder` instance until `make(...)` is called.
    public struct BuiltIn: Sendable {
        public let alias: String              // "nomic"
        public let canonicalEmbedderName: String  // "nomic-v1.5-768"
        public let canonicalDimension: Int    // 768
        public let defaultChunkSize: Int      // 1200
        public let defaultChunkOverlap: Int   // 240
    }

    public static let defaultAlias = "nomic"

    /// Static table. Adding a new embedder means adding one row here
    /// plus wiring the `make` switch below. Never instantiates an
    /// embedder — cheap to iterate.
    public static let builtIns: [BuiltIn] = [
        BuiltIn(
            alias: "nomic",
            canonicalEmbedderName: "nomic-v1.5-768",
            canonicalDimension: 768,
            defaultChunkSize: 1200,
            defaultChunkOverlap: 240
        ),
        BuiltIn(
            alias: "nl",
            canonicalEmbedderName: "nl-en-512",
            canonicalDimension: 512,
            defaultChunkSize: 2000,
            defaultChunkOverlap: 200
        ),
    ]

    public static var knownAliases: [String] { builtIns.map(\.alias) }

    /// Looks up a built-in descriptor by alias. Throws
    /// `VecError.unknownProfile(alias)` if the alias isn't registered.
    public static func builtIn(forAlias alias: String) throws -> BuiltIn {
        guard let entry = builtIns.first(where: { $0.alias == alias }) else {
            throw VecError.unknownProfile(alias)
        }
        return entry
    }

    // NOTE: `alias(forCanonicalEmbedderName:)` is intentionally NOT
    // provided. The pre-refactor `EmbedderFactory` carried a reverse
    // lookup from canonical embedder name to alias for `vec info`
    // rendering, but `vec info` now renders from the identity string
    // directly (the alias is the prefix before `@`). No other caller
    // needs this reverse lookup. See §"Open questions (answered)" Q5.

    /// Constructs a live profile from an alias + either both or
    /// neither chunk override. Callers MUST pass both `chunkSize` and
    /// `chunkOverlap` together, or neither. Passing exactly one is a
    /// programmer error caught by a precondition — the CLI layer is
    /// responsible for translating a partial-override CLI invocation
    /// into `VecError.partialChunkOverride` *before* calling `make`.
    /// `isBuiltIn` is true IFF the effective chunk params equal the
    /// alias's defaults (regardless of whether the caller passed them
    /// explicitly or left them nil). This matters because
    /// `resolve(identity:)` always calls `make` with explicit
    /// chunk params parsed out of the identity string — a persisted
    /// alias-default profile like `nomic@1200/240` round-trips through
    /// `resolve` and must still report `isBuiltIn == true`. Identity
    /// is always `"<alias>@<chunkSize>/<overlap>"`.
    public static func make(
        alias: String,
        chunkSize: Int? = nil,
        chunkOverlap: Int? = nil
    ) throws -> IndexingProfile {
        precondition(
            (chunkSize == nil) == (chunkOverlap == nil),
            "IndexingProfileFactory.make requires both chunk overrides or neither"
        )
        let entry = try builtIn(forAlias: alias)
        let effectiveSize = chunkSize ?? entry.defaultChunkSize
        let effectiveOverlap = chunkOverlap ?? entry.defaultChunkOverlap
        try validate(chunkSize: effectiveSize, chunkOverlap: effectiveOverlap)

        // `isBuiltIn` is a property of the resolved (effective) chunk
        // params, not of how the caller spelled them. This is what
        // keeps `resolve(identity: "nomic@1200/240")` equivalent to
        // `make(alias: "nomic")` on the `isBuiltIn` field.
        let isBuiltIn = (effectiveSize == entry.defaultChunkSize
                      && effectiveOverlap == entry.defaultChunkOverlap)
        let identity = "\(alias)@\(effectiveSize)/\(effectiveOverlap)"

        let embedder: any Embedder
        switch alias {
        case "nomic": embedder = NomicEmbedder()
        case "nl":    embedder = NLEmbedder()
        default:      throw VecError.unknownProfile(alias)
        }

        let splitter = RecursiveCharacterSplitter(
            chunkSize: effectiveSize,
            chunkOverlap: effectiveOverlap
        )

        return IndexingProfile(
            identity: identity,
            embedder: embedder,
            splitter: splitter,
            chunkSize: effectiveSize,
            chunkOverlap: effectiveOverlap,
            isBuiltIn: isBuiltIn
        )
    }

    /// Parses a persisted identity string and returns the matching
    /// live profile. Uses a strict grammar:
    ///
    ///   `^[a-z0-9-]+@[1-9][0-9]*/[0-9]+$`
    ///
    /// Rejects leading zeros on the size, any whitespace, uppercase
    /// letters, or extra separators. After a successful regex match,
    /// the parsed components are re-rendered and compared string-for-
    /// string against the input — any mismatch throws
    /// `VecError.malformedProfileIdentity(identity)`. This round-trip
    /// check is the single invariant that keeps identity comparison
    /// as simple string equality elsewhere in the codebase. An unknown
    /// alias portion throws `VecError.unknownProfile(identity)`.
    public static func resolve(identity: String) throws -> IndexingProfile {
        // Strict grammar. Keep `#""#` raw for readability.
        let pattern = #"^([a-z0-9-]+)@([1-9][0-9]*)/([0-9]+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: identity,
                  range: NSRange(identity.startIndex..., in: identity)),
              match.numberOfRanges == 4,
              let aliasRange = Range(match.range(at: 1), in: identity),
              let sizeRange  = Range(match.range(at: 2), in: identity),
              let overlapRange = Range(match.range(at: 3), in: identity)
        else {
            throw VecError.malformedProfileIdentity(identity)
        }
        let alias = String(identity[aliasRange])
        guard let size = Int(identity[sizeRange]),
              let overlap = Int(identity[overlapRange])
        else {
            throw VecError.malformedProfileIdentity(identity)
        }
        // Round-trip check: rendering the parsed components must
        // reproduce the original input byte-for-byte.
        let rendered = "\(alias)@\(size)/\(overlap)"
        guard rendered == identity else {
            throw VecError.malformedProfileIdentity(identity)
        }
        return try make(alias: alias, chunkSize: size, chunkOverlap: overlap)
    }

    private static func validate(chunkSize: Int, chunkOverlap: Int) throws {
        guard chunkSize > 0 else {
            throw VecError.invalidChunkParams(
                "chunk-chars must be positive (got \(chunkSize))")
        }
        guard chunkOverlap >= 0 else {
            throw VecError.invalidChunkParams(
                "chunk-overlap cannot be negative (got \(chunkOverlap))")
        }
        guard chunkOverlap < chunkSize else {
            throw VecError.invalidChunkParams(
                "chunk-overlap (\(chunkOverlap)) must be less than chunk-chars (\(chunkSize))")
        }
    }
}
```

Two classes of name in play, same as the embedder refactor but
broader:

- **Alias** — `nomic`, `nl`. What the user types after `--embedder`.
- **Identity** — `nomic@1200/240`. What is persisted in
  `DatabaseConfig.profile.identity` and what every mismatch error
  prints. Fully reconstructible: identity → alias + chunk params →
  live profile.

The identity explicitly includes the chunk params even for built-in
profiles. Rationale: persisting just `"nomic"` would mean a user who
originally indexed at the built-in default and later runs
`--embedder nomic --chunk-chars 500 --chunk-overlap 100` would get
a `"nomic@500/100"` request against a recorded `"nomic"`, and
the mismatch check would need extra logic to decide whether
defaults-at-that-time match defaults-now. Making the identity always
concrete (`"nomic@1200/240"`) eliminates the ambiguity.

### `DatabaseConfig` shape

```swift
public struct DatabaseConfig: Codable {
    public let sourceDirectory: String
    public let createdAt: Date
    /// Resolved indexing profile; nil on freshly `vec init`ed / `vec reset`
    /// DBs and on pre-profile DBs (which this refactor treats as unusable).
    public let profile: ProfileRecord?

    public struct ProfileRecord: Codable, Equatable {
        /// Full canonical identity, e.g. "nomic@1200/240".
        public let identity: String
        /// Canonical embedder name, cached here for fast `info` rendering
        /// without re-resolving the profile (e.g. "nomic-v1.5-768").
        public let embedderName: String
        /// Embedder dimension — mandatory for opening `VectorDatabase`
        /// before the profile has been resolved. Equal to whatever
        /// `resolve(identity:).embedder.dimension` returns.
        public let dimension: Int

        public init(identity: String, embedderName: String, dimension: Int) {
            self.identity = identity
            self.embedderName = embedderName
            self.dimension = dimension
        }
    }

    public init(sourceDirectory: String, createdAt: Date, profile: ProfileRecord? = nil) {
        self.sourceDirectory = sourceDirectory
        self.createdAt = createdAt
        self.profile = profile
    }

    static let filename = "config.json"
}
```

Why `dimension` is denormalized into `ProfileRecord`: every command
opens `VectorDatabase` *before* it resolves the profile (the open is
what lets us count chunks, the count is what lets us decide whether
the DB is "empty vs indexed"). Without `dimension` on the record
the command would have to run `IndexingProfileFactory.resolve` just
to know what dim to pass to the DB — and if `resolve` throws
(unknown alias on a future-version DB) the user would see a model
error instead of the clearer "unknown profile" error. Keeping
`dimension` in the record is one int of redundancy for a much better
failure ordering.

The old `embedder: EmbedderRecord?` field is **removed**. No alias,
no renames. A pre-profile DB decoded through the new shape will see
`profile == nil` (the key simply isn't present). Each command then
branches on chunk count: `chunkCount > 0` → hard fatal
`VecError.preProfileDatabase` (tells the user to `vec reset` first);
`chunkCount == 0` → treated as a fresh DB that hasn't been indexed
yet, which `update-index` walks through its first-index branch and
`search`/`insert` reject with `VecError.profileNotRecorded`. The
split matters so the error text can point the user at the correct
next command.

Existing `migratePreRefactorEmbedderRecord` in `DatabaseLocator`:
**deleted**. No migration path. The user can read the error and
reset.

### The fatal mismatch error text

Exact format — implementation agent must match this character-for-
character. `VecError.profileMismatch(recorded:requested:)`:

```
Database was indexed with profile 'nomic@1200/240' but 'nomic@500/100'
was requested. Vec will not index or search across profiles because
vectors from different profiles are not directly comparable.

Your options:
  1. Re-run the command with flags that resolve to 'nomic@1200/240'
     (e.g. `--embedder nomic` with the default chunk settings).
  2. Run `vec reset <db>` and re-index with the new profile.
```

`VecError.profileNotRecorded` (fresh or freshly-`reset` DB —
`profile == nil` AND `chunkCount == 0` — hit by `search` or
`insert`, which cannot bootstrap a profile):

```
Database has no recorded indexing profile. Run `vec update-index`
first to establish a profile.
```

`VecError.preProfileDatabase` (DB has chunks but no profile key —
`profile == nil` AND `chunkCount > 0` — i.e. a pre-profile DB left
over from before this refactor):

```
Database was indexed by an older version of vec with no recorded
profile. Run `vec reset <db>` first, then `vec update-index` to
rebuild it under a recorded profile.
```

`VecError.unknownProfile(identity)` (identity whose alias portion
is not in this build's registry — e.g. a future-version DB):

```
Unknown indexing profile '<identity>'. This build knows these
aliases: nomic, nl. The database may have been indexed by a newer
version of vec. Run `vec reset <db>` to rebuild under a known
profile.
```

`VecError.malformedProfileIdentity(identity)` (identity that fails
the strict regex or the round-trip check — corrupt `config.json`):

```
Indexing profile '<identity>' in config.json is malformed (expected
shape `<alias>@<size>/<overlap>`). Run `vec reset <db>` to rebuild.
```

`VecError.partialChunkOverride` (CLI passed exactly one of
`--chunk-chars` / `--chunk-overlap`):

```
--chunk-chars and --chunk-overlap must be supplied together (or
neither). Partial overrides are rejected so the resolved identity
is never ambiguous.
```

`VecError.invalidChunkParams(detail)` (size or overlap fails the
factory's numeric validation — non-positive size, negative overlap,
overlap ≥ size):

```
Invalid chunk parameters: <detail>.
```

All of these are printed to stderr and exit non-zero. No
`print(error); throw ExitCode.failure` dance — let the `VecError`
propagate through `AsyncParsableCommand` so the framework handles
it uniformly.

### CLI surface

```
vec update-index --embedder nomic
# first index: records profile "nomic@1200/240"

vec update-index --embedder nomic --chunk-chars 500 --chunk-overlap 100
# first index: records "nomic@500/100"

vec update-index
# subsequent index on a DB recorded at the alias-default (e.g.
# "nomic@1200/240"): alias defaults to recorded alias, no chunk
# overrides → requested identity is "nomic@1200/240" → matches
# recorded → proceeds to index any new/changed files.

vec update-index
# subsequent index on a DB recorded at a custom-chunk identity (e.g.
# "nomic@500/100"): alias defaults to recorded alias ("nomic"), no
# chunk overrides → requested identity resolves to the alias-default
# "nomic@1200/240" (NOT the recorded "nomic@500/100") → HARD FAIL
# with profileMismatch. To re-index under the recorded profile,
# retype the same flags (`--chunk-chars 500 --chunk-overlap 100`).
# Or `vec reset` first if you want to switch.

vec update-index --embedder nl
# recorded is "nomic@1200/240" → HARD FAIL with profileMismatch

vec update-index --chunk-chars 500
# HARD FAIL with partialChunkOverride — the other half
# (--chunk-overlap) wasn't supplied. Error tells the user to pass
# both or neither.

vec update-index --chunk-chars 500 --chunk-overlap 100
# recorded is "nomic@1200/240", requested resolves to "nomic@500/100"
# (alias defaults to the recorded alias when --embedder is omitted)
# → HARD FAIL with profileMismatch.

vec search "query text"
# resolves profile from recorded identity. No flags accepted.

vec insert path/to/file.md
# same — no flags, uses recorded identity.

vec reset <db>
# wipes DB + config.profile back to nil.

vec info
# prints one of:
#   Profile: nomic@1200/240 (768d)                   — built-in alias-default
#   Profile: nomic@500/100 (custom, based on nomic)  — custom override
#   Profile: (not yet recorded)                      — fresh/reset DB
```

**Rule on partial overrides: HARD-FAIL.** If the user passes exactly
one of `--chunk-chars` / `--chunk-overlap` without the other, the
command fails immediately with `VecError.partialChunkOverride`. The
missing value does NOT inherit from the alias's built-in default and
does NOT inherit from the recorded profile. Either both flags are
present (creating a fully explicit derived identity) or neither
(using the alias-default identity). Rationale: any inheritance rule
makes identity resolution context-sensitive and introduces a class
of surprises where a user who changes `--chunk-chars` gets a
"mysterious" overlap from somewhere else. Forcing both keeps the
resolved identity visible in the exact command the user typed.

**Alias resolution when `--embedder` is omitted on a recorded DB.**
`update-index` without `--embedder` on a DB with a recorded profile
takes the recorded profile's alias as the requested alias — **only
the alias** falls back to the recorded value. The chunk-override
half of the requested identity still follows the strict no-
inheritance rule: either both flags are supplied (fully explicit
derived identity) or neither is supplied, in which case the chunk
params default to the **alias-default** chunk params (NOT the
recorded chunk params). So if the recorded profile is the alias-
default (`nomic@1200/240`), bare `update-index` succeeds — recorded
and requested identities match. If the recorded profile is a custom
identity (`nomic@500/100`), bare `update-index` hard-fails with
`profileMismatch` — the user must retype `--chunk-chars 500
--chunk-overlap 100` (or `vec reset` first). Re-running bare
`vec update-index` to pick up new files without retyping flags is
supported only when the recorded profile happens to be the alias-
default; otherwise retyping the recorded chunk flags is required.

**`--splitter` flag: deferred.** Today only
`RecursiveCharacterSplitter` is wired through `TextExtractor`. A
`LineBasedSplitter` exists in the codebase but has no CLI path
since the nomic sweep. Adding `--splitter` now would require:

1. A splitter-kind discriminator in the identity string
   (`"nomic@recursive@1200/240"` vs `"nomic@line@30/8"`), because
   chunk params have different units.
2. Extending `IndexingProfileFactory.BuiltIn` with a splitter kind.
3. Re-plumbing `TextExtractor(splitter:)` through every caller.

All three are straightforward, and none require redesigning the
profile struct. The plan deliberately leaves `--splitter` out so the
initial cutover lands on a minimal surface. When it's added later:

- Extend the identity grammar to `"<alias>@<splitter>@<param1>/<param2>"`.
- Migrate the built-in identity shapes (`nomic@recursive@1200/240`).
- Add `--splitter line|recursive` to `UpdateIndexCommand`.

The profile struct already has `splitter: any TextSplitter` so no
shape change is needed.

### Whole-doc emission policy

`TextExtractor` emits exactly one `.whole` chunk per readable
non-PDF file (plus one per PDF) today — no per-embedder branch. The
max-input gate that used to live alongside it (`EmbeddingService.maxEmbeddingTextLength`)
has already been removed (commit 003b999), so truncation happens
inside each embedder.

**Decision: keep `.whole` emission uniform across profiles.**
Rationale:

- The benefit of `.whole` is indexing the full document as one
  vector. Its cost is proportional to doc length relative to the
  embedder's input window.
- Both shipping embedders already handle the truncation internally
  (`NomicEmbedder.maxInputCharacters = 30_000`, `NLEmbedder.maxInputCharacters = 10_000`).
  A very long doc becomes a truncated-prefix `.whole` vector for
  either backend. That's the existing behavior, documented, and
  the retrieval-rubric scores were measured against it.
- Adding a per-profile "skip whole above N chars" knob changes
  retrieval quality in a way we'd have to re-score both backends
  against — a separate experiment.

If a future profile genuinely needs to suppress `.whole` (say, a
profile that only ever embeds short snippets), the natural place is
a `bool emitsWholeChunk` on `IndexingProfile` that `TextExtractor`
reads before calling `chunks.append(.whole)`. Not landing now —
call out in the design doc.

### Pipeline wiring

`IndexingPipeline` today takes `embedder: any Embedder`. After the
refactor:

```swift
public init(
    concurrency: Int = max(ProcessInfo.processInfo.activeProcessorCount, 2),
    profile: IndexingProfile
) {
    self.workerCount = concurrency
    self.pool = EmbedderPool(embedder: profile.embedder)
}
```

The pool still only needs the embedder — it has no business knowing
chunk params — so `EmbedderPool` is unchanged.

`UpdateIndexCommand` and `InsertCommand` both construct `TextExtractor(splitter: profile.splitter)`
directly. `InsertCommand` previously used the default `TextExtractor()`
(which hardcoded `RecursiveCharacterSplitter()` with its old
defaults); after the refactor, it uses `profile.splitter` so the
derived profile's custom chunk settings apply to single-file inserts
too. This fixes a latent bug: an insert into a DB indexed at 500/100
would have chunked at the splitter's default.

### `RecursiveCharacterSplitter` cleanup

Before:

```swift
public static let defaultChunkSize = 1200
public static let defaultChunkOverlap = 240

public init(chunkSize: Int = RecursiveCharacterSplitter.defaultChunkSize,
            chunkOverlap: Int = RecursiveCharacterSplitter.defaultChunkOverlap,
            ...) { ... }
```

After:

```swift
public init(chunkSize: Int,
            chunkOverlap: Int,
            separators: [String] = RecursiveCharacterSplitter.defaultSeparators,
            keepSeparator: Bool = true) { ... }
```

`defaultChunkSize` / `defaultChunkOverlap` constants — deleted.
`defaultSeparators` — kept (separator list is a splitter concern,
not a profile concern).

Callers that supply no chunk params — only tests instantiating the
splitter for unit testing — update to pass explicit values. The
fixture and integration tests that go through `IndexingProfile`
already pass the params via the profile.

### `TextExtractor` cleanup

`TextExtractor` stays as-is. It already takes `splitter: TextSplitter`
in its init and has no embedder coupling. The `convenience init(chunkSize:,
overlapSize:)` that constructs a `LineBasedSplitter` can stay — it's
only called from `LineBasedSplitter`-specific tests and doesn't
interfere with the profile path. If it clutters the class, drop it
as a pass-through cleanup; non-blocking.

### Ordering of checks inside each command

The check order matters because the mismatch error must come from
the profile identity layer, not from a dim-mismatch lower down.

For `update-index`:

1. Parse CLI flags. If exactly one of `--chunk-chars` /
   `--chunk-overlap` was supplied, throw
   `VecError.partialChunkOverride` *before* any DB work.
2. `DatabaseLocator.resolve(name)` → raw config.
3. Open the DB **only to count chunks**. Split on the two missing-
   profile shapes:
   - `profile == nil` AND `chunkCount > 0` → raise
     `VecError.preProfileDatabase` with the "reset first, then
     update-index" message.
   - `profile == nil` AND `chunkCount == 0` → fresh/reset DB, fall
     through to the first-index branch at step 5.
   - `profile != nil` → proceed to step 4.
4. **Recorded profile path.** Construct the requested identity from
   CLI flags: alias falls back to `recorded.profile.identity`'s
   alias portion when `--embedder` is omitted. Chunk params either
   come from both flags together, or default to the
   *alias-default* chunk params (NOT the recorded chunk params) —
   the hard-fail rule from §"Rule on partial overrides" has already
   been enforced at step 1, so by this point chunks are either
   both-supplied or both-absent. **This means bare `vec update-index`
   on a recorded custom-chunk DB will hard-fail** — the requested
   identity uses the alias-default chunk params, which will not
   equal the recorded custom chunk params. Design choice: we always
   reach for the current best default, not the recorded one, so that
   bare `update-index` surfaces a loud `profileMismatch` rather than
   silently re-indexing under whatever chunk params happened to be
   recorded. Compare requested identity against
   `recorded.profile.identity`. Mismatch → `profileMismatch`. Match
   → resolve the profile via `IndexingProfileFactory.resolve(identity:
   recorded.profile.identity)` and jump to step 7.
5. **First-index path (fresh/reset DB).** Build the requested
   profile via `IndexingProfileFactory.make(alias: …, chunkSize:
   …, chunkOverlap: …)` from the CLI flags, defaulting alias to
   `IndexingProfileFactory.defaultAlias` if `--embedder` was
   omitted.
6. **Persist the `ProfileRecord`** to `config.json` before the
   pipeline touches the DB. The record is written in the same
   transaction regardless of whether the identity is alias-default
   (`nomic@1200/240`) or a custom override (`nomic@500/100`): both
   go through the same write with the same shape. Rationale: if
   the pipeline crashes mid-index, the config already reflects the
   profile the partial vectors were built under, and the next
   command sees a correct `profileMismatch` / match comparison
   instead of a `preProfileDatabase` error.
7. Build `VectorDatabase(dimension: profile.embedder.dimension)` and
   `IndexingPipeline(profile:)`. Run.

For `search` and `insert`:

1. Resolve DB. Open the DB to read the chunk count (needed to
   distinguish fresh from pre-profile).
2. Missing-profile split, same as `update-index`:
   - `profile == nil` AND `chunkCount == 0` →
     `VecError.profileNotRecorded` (tells user to run
     `vec update-index`).
   - `profile == nil` AND `chunkCount > 0` →
     `VecError.preProfileDatabase` (tells user to `vec reset`
     first).
3. `IndexingProfileFactory.resolve(identity: recorded.identity)` →
   live profile. An unknown alias portion throws
   `unknownProfile`; a malformed identity string throws
   `malformedProfileIdentity`.
4. Open `VectorDatabase(dimension: recorded.dimension)` and run.

Neither `search` nor `insert` takes any profile-shaping flag.

### Files touched

New:

- `Sources/VecKit/IndexingProfile.swift` — struct + factory (the
  factory could live separately, but the two types are tightly
  coupled and always imported together; keeping them in one file
  matches `Embedder.swift`'s pattern).
- `Tests/VecKitTests/IndexingProfileTests.swift` — identity round
  trip, override composition, `resolve` parse errors, factory
  alias lookup.
- `indexing-profile.md` — design doc (written by the Phase 3
  implementer).

Modified:

- `Sources/VecKit/DatabaseLocator.swift` — replace
  `EmbedderRecord` → `ProfileRecord`, change field name
  `embedder` → `profile`, delete
  `migratePreRefactorEmbedderRecord`.
- `Sources/VecKit/EmbedderFactory.swift` — **deleted**. All call
  sites switch to `IndexingProfileFactory`.
- `Sources/VecKit/FileScanner.swift` (VecError home) — rename
  `unknownEmbedder` → `unknownProfile`, `embedderMismatch` →
  `profileMismatch`, `embedderNotRecorded` → `profileNotRecorded`,
  add `preProfileDatabase` (no payload), add
  `malformedProfileIdentity(String)`, add `partialChunkOverride`
  (no payload), add `invalidChunkParams(String)`. `dimensionMismatch`
  stays (belt-and-braces).
- `Sources/VecKit/RecursiveCharacterSplitter.swift` — drop
  `defaultChunkSize` / `defaultChunkOverlap`; require explicit
  params in `init`.
- `Sources/VecKit/IndexingPipeline.swift` — `init(profile:)`
  instead of `init(embedder:)`. `EmbedderPool` unchanged.
- `Sources/vec/Commands/UpdateIndexCommand.swift` — parse profile
  flags, apply check order above, construct pipeline + extractor
  from the profile. Help text sources chunk defaults from the
  factory's `builtIn(forAlias: defaultAlias)`, not from the
  splitter.
- `Sources/vec/Commands/SearchCommand.swift` — resolve profile
  from `config.profile.identity`.
- `Sources/vec/Commands/InsertCommand.swift` — same resolution as
  search; also uses `profile.splitter` in `TextExtractor`.
- `Sources/vec/Commands/ResetCommand.swift` — write config with
  `profile: nil`.
- `Sources/vec/Commands/ListCommand.swift` — append the profile
  identity (or `(not recorded)` / `(pre-profile)`) to each DB's
  row. See §"Open questions (answered)" Q4.
- `Sources/vec/Commands/InfoCommand.swift` — render the four
  `Profile:` states from §"Open questions (answered)" Q1: built-in
  identity, custom identity (appends `(custom, based on <alias>)`),
  fresh/reset (`(not yet recorded)`), pre-profile
  (`(pre-profile database — run 'vec reset <db>' to rebuild)`).
  Remove `migratePreRefactorEmbedderRecord` call.
- `Tests/VecKitTests/EmbedderConfigTests.swift` — rewrite as
  `IndexingProfileConfigTests` (or rename in place): round-trip the
  new shape, pre-profile JSON → `profile == nil`, factory alias
  round-trip, unknown-alias error, identity parsing errors.
- `Tests/VecKitTests/TrademarkTranscriptFixtureTests.swift` —
  replace the two hardcoded `testNomic…` / `testNL…` methods with
  a loop over `IndexingProfileFactory.builtIns`. One method per
  assertion (extract produces non-empty chunks / every chunk
  embeds to `profile.embedder.dimension`), both running inside a
  `for entry in ... { ... }` loop. New profile → auto-covered.

Unmodified (verified):

- `Sources/VecKit/Embedder.swift` — protocol unchanged.
- `Sources/VecKit/NomicEmbedder.swift`, `NLEmbedder.swift` — unchanged.
- `Sources/VecKit/TextExtractor.swift` — already takes a splitter.
- `Sources/VecKit/VectorDatabase.swift` — dim guard stays as-is.
- `Sources/VecKit/SearchResultCoalescer.swift`, model files.

### Test plan

Existing tests: all pass. The embedder-layer tests
(`NomicEmbedderConcurrencyTests`, `NLEmbedderConcurrencyTests`,
`VectorDatabaseTests`, `IntegrationTests`) are indifferent to
profiles and need only their call-site signatures updated where
they used to construct `IndexingPipeline(embedder:)`.

New / rewritten:

1. `IndexingProfileTests` — unit tests, no model load:
   - Built-in alias `nomic` resolves to identity `"nomic@1200/240"`,
     embedder name `"nomic-v1.5-768"`, dim 768, `isBuiltIn == true`.
   - Built-in alias `nl` → `"nl@2000/200"`, `"nl-en-512"`, 512.
   - Full override: `make(alias: "nomic", chunkSize: 500, chunkOverlap: 100)`
     → identity `"nomic@500/100"`, `isBuiltIn == false`,
     `splitter.chunkSize == 500`.
   - `resolve(identity: "nomic@1200/240")` → matches `make(alias: "nomic")`
     on every field, including `isBuiltIn == true`. (This is the
     round-trip that forces `isBuiltIn` to be computed from the
     effective chunk params rather than from whether the caller
     passed nil — `resolve` always calls `make` with explicit
     sizes.)
   - `resolve(identity: "nomic@500/100")` → `isBuiltIn == false` (the
     effective chunk params don't match nomic's alias-defaults).
   - **Strict parsing — reject all of these with
     `VecError.malformedProfileIdentity`:**
     `"garbled"`, `"nomic"`, `"nomic@1200"`, `"nomic@1200/"`,
     `"@1200/240"`, `"nomic@abc/def"`, `"nomic@ 1200/240"` (leading
     space), `"nomic@1200/240 "` (trailing space), `"nomic@01200/240"`
     (leading zero), `"Nomic@1200/240"` (uppercase alias),
     `"nomic@1200/240/5"` (extra segment), `"nomic@-100/240"`
     (negative size).
   - `resolve(identity: "bogus@1200/240")` → `VecError.unknownProfile`
     (grammar-valid, alias unknown — distinct from
     `malformedProfileIdentity`).
   - `make(alias: "bogus")` → `VecError.unknownProfile`.
   - `make(chunkSize: 100, chunkOverlap: 100)` → `VecError.invalidChunkParams`
     (overlap not strictly less than size).
   - `make(chunkSize: 10, chunkOverlap: 0)` succeeds (overlap of 0
     is explicitly valid — grammar allows `[0-9]+` for the overlap
     while requiring `[1-9][0-9]*` for size).
   - `make(alias: "nomic", chunkSize: 500, chunkOverlap: nil)` — a
     partial-override call — trips the precondition (programmer
     error; the CLI layer must reject before calling `make`).

2. Rename `EmbedderConfigTests` → `IndexingProfileConfigTests`:
   - Round-trip a `DatabaseConfig` with `ProfileRecord` set.
   - Round-trip with `profile: nil`.
   - Decode legacy JSON (pre-profile shape — may still carry the old
     `embedder` key from the pluggable-embedders refactor) and
     confirm `profile == nil`. Extra keys in decoded JSON are
     ignored by Codable; this is the implicit back-compat for
     decode-only.
   - Unknown alias error via `IndexingProfileFactory.make(alias:
     "bogus")`.
   - Default alias (`IndexingProfileFactory.defaultAlias`) is
     present in `knownAliases`.

3. `ProfileMismatchTests` — command-layer integration tests. Lives
   in `Tests/vecTests/ProfileMismatchTests.swift` (new file; alongside
   other command tests). No model load needed — every case tests the
   check-order logic before any embedding happens. Uses the existing
   in-memory / tmpdir `DatabaseLocator` test harness.
   - Seed a DB with `ProfileRecord(identity: "nomic@1200/240", …)`
     and at least one row in `chunks`. Invoke `update-index --embedder
     nl`. Expect `VecError.profileMismatch`.
   - Same seed. Invoke `update-index --embedder nomic --chunk-chars
     500 --chunk-overlap 100`. Expect `VecError.profileMismatch`
     (requested `nomic@500/100` vs recorded `nomic@1200/240`).
   - Same seed. Invoke `update-index --embedder nomic` with no chunk
     overrides. Expect success (no throw; pipeline proceeds).
   - Same seed. Invoke `update-index --chunk-chars 500` (only one of
     the two chunk flags). Expect `VecError.partialChunkOverride`
     thrown *before* any DB comparison (hard-fail at step 1 of the
     check order).
   - Seed a DB with `profile: nil` and at least one row in `chunks`
     (simulates a pre-profile DB). Invoke `update-index`. Expect
     `VecError.preProfileDatabase`. Repeat with `search "q"` and
     `insert path`. Expect `VecError.preProfileDatabase` for each.
   - Seed a DB with `profile: nil` and zero rows in `chunks` (fresh
     DB). Invoke `search "q"`. Expect `VecError.profileNotRecorded`.
     Repeat with `insert path`. Expect
     `VecError.profileNotRecorded`. Invoke `update-index --embedder
     nomic`. Expect success (first-index path).

4. `TrademarkTranscriptFixtureTests` — restructure:
   ```swift
   func testEveryBuiltInProfileExtractsAndEmbedsFixture() async throws {
       for entry in IndexingProfileFactory.builtIns {
           let profile = try IndexingProfileFactory.make(alias: entry.alias)
           let extractor = TextExtractor(splitter: profile.splitter)
           let file = try fixtureFileInfo()
           let chunks = try extractor.extract(from: file).chunks
           XCTAssertGreaterThan(chunks.count, 0,
               "profile \(profile.identity): extractor must emit chunks")
           for (i, chunk) in chunks.enumerated() {
               let vec = try await profile.embedder.embedDocument(chunk.text)
               XCTAssertEqual(vec.count, profile.embedder.dimension,
                   "profile \(profile.identity): chunk \(i) should embed to \(profile.embedder.dimension) dims")
           }
       }
   }
   ```
   Keeps the existing fixture file. Adding a new built-in profile
   automatically extends coverage; no manual test-plumbing required.

Total test count delta: +~15 (new `IndexingProfileTests` with the
strict-parsing matrix), +~7 (new `ProfileMismatchTests` covering
the five-case matrix plus partial-override), -2 (the two hardcoded
fixture tests collapse into one loop), net ~+20. Full `swift test`
must stay green at every commit.

### Phase 5: real-world retrieval-rubric verification

Run outside the worker sandbox (manager agent or human). For each
profile:

```
vec reset markdown-memory --force
vec update-index --db markdown-memory --embedder <alias>
# score against retrieval-rubric.md using its standard rubric
```

Probe the transcript is present:

```
sqlite3 ~/.vec/markdown-memory/index.db \
  "SELECT COUNT(*) FROM chunks c JOIN files f ON c.file_id=f.id
   WHERE f.relative_path LIKE '%transcript.txt';"
```

Expect `> 0`.

Expected scores, matching `retrieval-results-nomic.md` history:

- `nl` profile (2000/200) → ~6/60.
- `nomic` profile (1200/240) → ~35/60.

If either is off by more than its tolerance band, STOP and
investigate before declaring Phase 5 done. Most likely causes: a
silent change to chunking (the whole-doc policy decision), or an
embedder-dim mismatch (dim guard would've fired earlier).

After the sweep, leave the DB in whichever state the user prefers
(default is `nomic@1200/240` — the one they were running before).

## Phase structure

Status legend: ✅ DONE · ⏳ NEXT UP · ◻ NOT STARTED.

| Status | Phase | Owner | Deliverable | Budget |
|:------:|------:|-------|-------------|-------:|
| ✅ DONE | 1 | this agent (77b5f3be) | `indexing-profile-plan.md` — you're reading it | 45 min |
| ✅ DONE | 2 | 2 reviewer agents in parallel, 3 rounds completed (revisions landed in commits `45aed0c` "indexing-profile-plan: round-3 revisions", `bbfc5ed` round-3 brief, `12d30ed` round-2 revisions; brief files since archived) | Plan review (architecture + correctness) via `review-cycle` skill | 1–2 h |
| ✅ DONE | 3a | one impl agent | `IndexingProfile` struct + identity parser + `malformedProfileIdentity` error + `IndexingProfileTests` | 1–1.5 h |
| ✅ DONE | 3a-r | 2 reviewer agents in parallel | `review-cycle` on Phase 3a → manager approval → next phase | 30–60 min |
| ✅ DONE | 3b | one impl agent | `IndexingProfileFactory` (make/resolve/alias table) + `partialChunkOverride` + `invalidChunkParams` + factory tests | 1–1.5 h |
| ✅ DONE | 3b-r | 2 reviewer agents in parallel | `review-cycle` on Phase 3b → manager approval → next phase | 30–60 min |
| ✅ DONE | 3c | one impl agent | `DatabaseConfig.profile` field + `profileNotRecorded` + `preProfileDatabase` errors + `IndexingProfileConfigTests` | 1–1.5 h |
| ⏳ NEXT UP | 3c-r | 2 reviewer agents in parallel | `review-cycle` on Phase 3c → manager approval → next phase | 30–60 min |
| ◻ NOT STARTED | 3d | one impl agent | Wire `UpdateIndexCommand` to factory + profile field + full check-order + `ProfileMismatchTests` | 1.5–2 h |
| ◻ NOT STARTED | 3d-r | 2 reviewer agents in parallel | `review-cycle` on Phase 3d → manager approval → next phase | 30–60 min |
| ◻ NOT STARTED | 3e | one impl agent | Wire `InsertCommand` + `SearchCommand` + `InfoCommand` + `ListCommand` + `ResetCommand`; delete `EmbedderFactory`; drop `RecursiveCharacterSplitter` defaults; design doc | 1.5–2 h |
| ◻ NOT STARTED | 4 | 2 reviewer agents in parallel, up to 3 rounds | Final code review across the whole 3a–3e diff via `review-cycle` skill | 1–2 h |
| ◻ NOT STARTED | 5 | manager or human | Retrieval-rubric sanity sweeps (both profiles) | 2 h |
| ◻ NOT STARTED | 6 | manager | Final commit check + merge to `agent/agent-c54ba5da` | 30 min |

When a phase ships, the implementer (or manager who merges it)
flips its row from ⏳/◻ to ✅ in the same commit and marks the
next phase ⏳ NEXT UP. The status column is the source of truth
for where the work stands; the per-phase headings below carry
fuller detail.

Phase 3 is split into five small, independently reviewable phases
(3a–3e). Each phase leaves the tree fully compiling with all tests
green; intermediate phases may carry dead code (a new struct or
factory with no callers yet) but never half-finished APIs that a
later phase must complete to compile. Each phase is also followed
by a mandatory `review-cycle` checkpoint (2 reviewer agents in
parallel) and an explicit manager approval before the next phase
starts. No single agent ships two phases without a review gate
in between.

The split largely follows the suggested decomposition. One small
deviation: `VecError` additions are spread across the phases that
need them (3a adds `malformedProfileIdentity`; 3b adds
`partialChunkOverride` + `invalidChunkParams`; 3c adds
`profileNotRecorded` + `preProfileDatabase`; 3d performs the
rename of `unknownEmbedder` → `unknownProfile`, `embedderMismatch`
→ `profileMismatch`, `embedderNotRecorded` → `profileNotRecorded`
since 3d is the first phase that actually exercises the
`profileMismatch` path). This keeps each phase's diff small and
the error variants land alongside the test code that proves them.

## Phase 3a — `IndexingProfile` struct + identity parser

**Status: ✅ DONE.**

**Goal.** Land the `IndexingProfile` struct and the strict identity
parser as standalone, fully-tested code. Nothing in the rest of
the codebase calls it yet — it's dead code on purpose so the
reviewer can read the diff in isolation.

**Files touched.**

- New: `Sources/VecKit/IndexingProfile.swift` — only the
  `IndexingProfile` struct (per §"The profile struct") and a
  static `IndexingProfile.parseIdentity(_:) throws -> (alias:
  String, chunkSize: Int, chunkOverlap: Int)` helper that runs
  the strict regex + round-trip check (per §"The factory /
  registry", `resolve(identity:)`). The `IndexingProfileFactory`
  enum is NOT in this file yet — Phase 3b adds it.
- Modified: `Sources/VecKit/FileScanner.swift` (VecError home) —
  add `malformedProfileIdentity(String)` only. No renames yet.
- New: `Tests/VecKitTests/IndexingProfileTests.swift` — covers
  struct construction (full override path: identity string,
  `chunkSize`/`chunkOverlap` fields, `isBuiltIn` flag set
  manually via initializer), the precondition guards
  (`chunkSize > 0`, `chunkOverlap >= 0 && < chunkSize`), and the
  full strict-parsing negative matrix from §"Test plan" item 1
  (garbled / whitespace / leading-zero / uppercase / extra-
  segment / negative inputs all reject with
  `malformedProfileIdentity`). Use a stub embedder + stub
  splitter for the construction tests so the suite has no model
  load and no factory dependency.

**Ship criteria.**

- `swift build` clean.
- `swift test` exits 0. `IndexingProfileTests` adds ~12–15 tests
  covering struct init + parser; existing 179 tests stay green.
- `IndexingProfile` exists with the exact field shape from
  §"The profile struct" (init signature, preconditions, all
  six fields including `isBuiltIn`).
- `IndexingProfile.parseIdentity` rejects every entry in the
  negative matrix with `VecError.malformedProfileIdentity`.

**Does NOT yet do.**

- No `IndexingProfileFactory`. No `make` or `resolve` factory
  methods (the parser is a free helper for now; Phase 3b lifts
  it onto the factory).
- No `DatabaseConfig.profile` field — config still carries the
  old `embedder: EmbedderRecord?` field unchanged.
- No CLI command changes. `UpdateIndexCommand`, `SearchCommand`,
  `InsertCommand` all run on the existing `EmbedderFactory` /
  `EmbedderRecord` path.
- No `IndexingPipeline.init(profile:)` — pipeline still takes
  `embedder:`.
- No `partialChunkOverride`, `invalidChunkParams`,
  `profileNotRecorded`, `preProfileDatabase` errors yet, and no
  rename of `unknownEmbedder` / `embedderMismatch` /
  `embedderNotRecorded`.
- No design doc (`indexing-profile.md`).
- `RecursiveCharacterSplitter.defaultChunkSize` / `defaultChunkOverlap`
  constants still present.

Reviewers should NOT file issues for any of the above — they
belong to a later phase.

**Budget.** 1–1.5 h.

**Checkpoint.** Commit (`feat: add IndexingProfile struct + strict
identity parser`) → run `review-cycle` skill (2 reviewers) → fix
any blocking issues → manager approval → only then start Phase 3b.

## Phase 3b — `IndexingProfileFactory`

**Status: ✅ DONE.**

**Goal.** Land the factory enum that produces live profiles from
aliases or persisted identity strings. Old `EmbedderFactory` still
exists alongside; no command wiring changes.

**Files touched.**

- Modified: `Sources/VecKit/IndexingProfile.swift` — add the
  `IndexingProfileFactory` enum from §"The factory / registry"
  (the `BuiltIn` descriptor, `defaultAlias`, `builtIns` table,
  `knownAliases`, `builtIn(forAlias:)`, `make(alias:chunkSize:
  chunkOverlap:)`, `resolve(identity:)`, `validate`). Move the
  parser logic from the standalone `IndexingProfile.parseIdentity`
  helper into `resolve(identity:)` (or have `resolve` call the
  helper — implementer's choice, but only one parser
  implementation in the tree). Apply the `partialChunkOverride`
  precondition guard at the factory's `make` (the precondition
  fires only on programmer error; the matching CLI-layer
  `VecError.partialChunkOverride` throw is wired in Phase 3d).
- Modified: `Sources/VecKit/FileScanner.swift` (VecError home) —
  add `partialChunkOverride` (no payload) and
  `invalidChunkParams(String)`. Also add `unknownProfile(String)`
  as a NEW variant alongside the existing `unknownEmbedder` —
  no rename yet, both coexist for one phase. `unknownProfile` is
  what `IndexingProfileFactory.make` / `resolve` throws.
- Modified: `Tests/VecKitTests/IndexingProfileTests.swift` (extend
  in-place) — add the factory-side tests from §"Test plan" item 1:
  built-in alias resolution for `nomic` and `nl`, full override
  composition (`make(alias: "nomic", chunkSize: 500, chunkOverlap:
  100)`), `resolve(identity:)` round-trip including the
  `isBuiltIn` flag check (alias-default identity round-trips to
  `isBuiltIn == true`; custom identity to `isBuiltIn == false`),
  unknown-alias error (`make(alias: "bogus")` → `unknownProfile`),
  invalid chunk-param errors (overlap == size, negative overlap),
  the partial-override precondition (programmer-error case).

**Ship criteria.**

- `swift build` clean.
- `swift test` exits 0. `IndexingProfileTests` grows by ~10
  factory tests (total ~22–25 in the file).
- `IndexingProfileFactory.make(alias:)` returns a fully-built
  `IndexingProfile` for both `nomic` and `nl` with the correct
  identities (`nomic@1200/240`, `nl@2000/200`).
- `IndexingProfileFactory.resolve(identity:)` round-trips
  identity strings back to live profiles, including correct
  `isBuiltIn` computation (effective-chunk-params check, not
  caller-arity check).

**Does NOT yet do.**

- No `DatabaseConfig.profile` field. Config persistence still
  uses the old `embedder: EmbedderRecord?` shape.
- No CLI command rewiring. `UpdateIndexCommand` still calls
  `EmbedderFactory.make(alias:)` and constructs the splitter
  directly.
- `EmbedderFactory.swift` is still present and still called from
  every command. `IndexingProfileFactory` exists alongside it
  with no production callers (only test callers).
- The `unknownEmbedder` / `embedderMismatch` / `embedderNotRecorded`
  variants are NOT renamed yet — they live alongside the new
  `unknownProfile` for now. Phase 3d does the rename in the
  same commit that wires `UpdateIndexCommand` to the new
  errors.
- No `migratePreRefactorEmbedderRecord` deletion.
- No `RecursiveCharacterSplitter` default-constant removal.
- No `IndexingPipeline.init(profile:)`.
- No design doc.

**Budget.** 1–1.5 h.

**Checkpoint.** Commit (`feat: add IndexingProfileFactory with
built-in alias table + resolve`) → `review-cycle` (2 reviewers) →
manager approval → only then start Phase 3c.

## Phase 3c — `DatabaseConfig.profile` field + new errors

**Status: ◻ NOT STARTED.**

**Goal.** Add the `profile: ProfileRecord?` field to
`DatabaseConfig`, write/read it atomically, and detect pre-
profile DBs. Commands still use the old `embedder` field — this
phase only changes the config shape and adds the detection
errors.

**Files touched.**

- Modified: `Sources/VecKit/DatabaseLocator.swift` — add the new
  `profile: ProfileRecord?` field to `DatabaseConfig`
  (alongside the existing `embedder: EmbedderRecord?` for one
  phase — both coexist in the struct so callers can flip one
  command at a time in 3d/3e). Add the nested `ProfileRecord`
  type (per §"`DatabaseConfig` shape"). `writeConfig` writes
  both fields (whichever is non-nil; new code paths set
  `profile`, old code paths still set `embedder`). `readConfig`
  decodes both and returns the struct unchanged. The
  `migratePreRefactorEmbedderRecord` helper stays for now —
  Phase 3e deletes it.
- Modified: `Sources/VecKit/FileScanner.swift` (VecError home) —
  add `profileNotRecorded` (no payload) and `preProfileDatabase`
  (no payload). Both unused for now; commands wire to them in
  3d/3e.
- Modified: `Tests/VecKitTests/EmbedderConfigTests.swift` →
  rename file to `Tests/VecKitTests/IndexingProfileConfigTests.swift`
  in the same commit. Keep all existing legacy-shape decode
  tests (the legacy round-trip path is still required since 3c
  doesn't break it). Add new tests per §"Test plan" item 2:
  round-trip a `DatabaseConfig` with `ProfileRecord` set;
  round-trip with `profile: nil`; decode legacy JSON (just
  `embedder` key, no `profile`) confirming `profile == nil`;
  decode JSON with both keys and confirm both round-trip;
  factory alias round trip (write a config from
  `IndexingProfileFactory.make(alias: "nomic")`, read it back,
  confirm identity equals the made profile's identity).

**Ship criteria.**

- `swift build` clean.
- `swift test` exits 0. `IndexingProfileConfigTests` covers
  both old and new decode paths.
- A new `DatabaseConfig` written with `profile: ProfileRecord?`
  set persists to `config.json` and reads back identical.
- A pre-existing `config.json` with only the `embedder` key
  decodes to `profile == nil` without throwing.
- `ProfileRecord` carries `identity`, `embedderName`, and
  `dimension` per §"`DatabaseConfig` shape".

**Does NOT yet do.**

- No CLI command consumes the new `profile` field. Commands
  still read `config.embedder` and route on it.
- No mismatch checks (`profileMismatch`,
  `preProfileDatabase`, `profileNotRecorded`) actually thrown
  from any command yet — the variants exist but are dead.
- No `unknownEmbedder` → `unknownProfile` rename. Both
  variants coexist (`unknownProfile` already added in 3b).
- `migratePreRefactorEmbedderRecord` is NOT deleted yet.
- No `IndexingPipeline.init(profile:)`.
- No `RecursiveCharacterSplitter` default removal.
- No `EmbedderFactory.swift` deletion.
- No design doc.

Reviewers should expect to see the `embedder` field still
present on `DatabaseConfig` — that is intentional and gets
removed in 3e.

**Budget.** 1–1.5 h.

**Checkpoint.** Commit (`feat: add DatabaseConfig.profile field +
profile-state errors`) → `review-cycle` (2 reviewers) → manager
approval → only then start Phase 3d.

## Phase 3d — Wire `UpdateIndexCommand` to the factory + check-order

**Status: ◻ NOT STARTED.**

**Goal.** Make `update-index` the first command on the new path:
parse profile flags, run the full check-order, write the
`ProfileRecord`, drive the pipeline through `IndexingProfile`.
`InsertCommand`, `SearchCommand`, `InfoCommand`, and `ListCommand`
remain on the old `EmbedderFactory` / `EmbedderRecord` path —
they're flipped in 3e.

**Files touched.**

- Modified: `Sources/VecKit/IndexingPipeline.swift` —
  `init(profile: IndexingProfile)` instead of (or alongside,
  for one phase) `init(embedder:)`. If kept alongside,
  `init(embedder:)` becomes a thin shim used only by the
  un-flipped commands; `init(profile:)` is the canonical path
  used by `UpdateIndexCommand`. `EmbedderPool` unchanged.
- Modified: `Sources/vec/Commands/UpdateIndexCommand.swift` —
  full rewire per §"Ordering of checks inside each command":
  CLI partial-override hard-fail at step 1 (throws
  `partialChunkOverride`); chunk-count read at step 3; the
  three missing-profile branches (pre-profile / fresh /
  recorded); recorded-path identity construction with alias
  fall-back to recorded alias and chunk-default fall-back to
  alias-defaults (NOT recorded chunks — strict no-inheritance);
  identity-string equality check throwing `profileMismatch` on
  drift; `ProfileRecord` write at step 6 before the pipeline
  touches the DB; pipeline construction with
  `IndexingPipeline(profile:)`; help text sourcing chunk
  defaults from `IndexingProfileFactory.builtIn(forAlias:
  defaultAlias)` instead of `RecursiveCharacterSplitter.defaultChunkSize`.
- Modified: `Sources/VecKit/FileScanner.swift` (VecError home) —
  rename `unknownEmbedder` → `unknownProfile` (collapse with
  the variant added in 3b — keep one canonical name),
  `embedderMismatch` → `profileMismatch`, `embedderNotRecorded`
  → `profileNotRecorded`. Update the error-text rendering for
  `profileMismatch` to the exact format from §"The fatal
  mismatch error text". All call-sites of the renamed variants
  flip in this commit. Other commands (`InsertCommand`,
  `SearchCommand`) catch / propagate via the renamed variants.
- New: `Tests/vecTests/ProfileMismatchTests.swift` — covers the
  `update-index`-side rows of the five-case matrix from §"Test
  plan" item 3:
  - recorded `nomic@1200/240`, request `update-index --embedder nl`
    → `profileMismatch`.
  - recorded `nomic@1200/240`, request `update-index --embedder
    nomic --chunk-chars 500 --chunk-overlap 100` →
    `profileMismatch`.
  - recorded `nomic@1200/240`, request `update-index --embedder
    nomic` (no chunk overrides) → succeeds.
  - `update-index --chunk-chars 500` (only one chunk flag,
    fresh DB) → `partialChunkOverride` thrown before any DB
    work.
  - pre-profile DB (`profile == nil`, `chunkCount > 0`),
    request `update-index` → `preProfileDatabase`.
  - fresh/reset DB (`profile == nil`, `chunkCount == 0`),
    request `update-index --embedder nomic` → succeeds, writes
    `ProfileRecord` to config.
  The `search` and `insert` rows of the matrix are NOT in this
  phase — they land in 3e once those commands are flipped.

**Ship criteria.**

- `swift build` clean.
- `swift test` exits 0. `ProfileMismatchTests` covers six
  `update-index` cases per above.
- `update-index` on a recorded DB hits the new check-order
  and surfaces the exact `profileMismatch` text from §"The
  fatal mismatch error text".
- `update-index` on a fresh DB writes a `ProfileRecord` to
  `config.json` before the pipeline runs.
- `update-index` help text no longer references
  `RecursiveCharacterSplitter.defaultChunkSize` /
  `defaultChunkOverlap`; defaults come from
  `IndexingProfileFactory.builtIn(forAlias: defaultAlias)`.

**Does NOT yet do.**

- `InsertCommand` still uses `EmbedderFactory` and the old
  `embedder` field. Inserts on a profile-recorded DB use the
  legacy decode path (which sees `config.embedder` if the old
  shim wrote it, or treats the DB as missing-embedder
  otherwise). This is acceptable because `InsertCommand`
  rarely runs alone — users typically `update-index` first.
- `SearchCommand` still uses the old path. Same reasoning.
- `InfoCommand` still renders the old "Embedder:" line. The
  new four-state `Profile:` rendering lands in 3e.
- `ListCommand` still prints rows without the profile column.
- `EmbedderFactory.swift` not deleted.
- `RecursiveCharacterSplitter.defaultChunkSize` /
  `defaultChunkOverlap` constants not deleted (still consumed
  by the un-flipped commands' implicit splitter construction).
- `migratePreRefactorEmbedderRecord` not deleted.
- No design doc.

Reviewers should NOT file issues for `Insert`/`Search`/`Info`/
`List` not using the profile path — that work belongs to 3e.

**Budget.** 1.5–2 h. Largest of the five sub-phases because of
the check-order plumbing and `ProfileMismatchTests`.

**Checkpoint.** Commit (`feat: wire UpdateIndexCommand to
IndexingProfileFactory with full check-order`) → `review-cycle`
(2 reviewers) → manager approval → only then start Phase 3e.

## Phase 3e — Flip remaining commands; delete legacy; design doc

**Status: ◻ NOT STARTED.**

**Goal.** Move `InsertCommand`, `SearchCommand`, `InfoCommand`,
`ListCommand`, and `ResetCommand` onto the profile path; delete
`EmbedderFactory` and the legacy `embedder` field on
`DatabaseConfig`; drop the `RecursiveCharacterSplitter` default
constants; loopify `TrademarkTranscriptFixtureTests`; write the
design doc.

**Files touched.**

- Modified: `Sources/vec/Commands/SearchCommand.swift` — adopt
  the search/insert check-order from §"Ordering of checks
  inside each command": resolve DB, read chunk count, branch
  on the missing-profile cases (`profileNotRecorded` /
  `preProfileDatabase`), `IndexingProfileFactory.resolve(identity:)`,
  open `VectorDatabase(dimension: recorded.dimension)`, run
  search.
- Modified: `Sources/vec/Commands/InsertCommand.swift` — same
  check-order. Construct `TextExtractor(splitter:
  profile.splitter)` so single-file inserts honor the
  recorded profile's chunk settings (fixes the latent bug
  noted in §"Pipeline wiring").
- Modified: `Sources/vec/Commands/InfoCommand.swift` — render
  the four `Profile:` states from §"Open questions (answered)"
  Q1: built-in identity (`Profile: nomic@1200/240 (768d)`),
  custom identity (`Profile: nomic@500/100 (custom, based on
  nomic) (768d)`), fresh/reset (`Profile: (not yet
  recorded)`), pre-profile (`Profile: (pre-profile database
  — run 'vec reset <db>' to rebuild)`). Remove the
  `migratePreRefactorEmbedderRecord` call.
- Modified: `Sources/vec/Commands/ListCommand.swift` — append
  the profile identity (or `(not recorded)` / `(pre-profile)`)
  to each DB row per §"Open questions (answered)" Q4.
- Modified: `Sources/vec/Commands/ResetCommand.swift` — write
  config with `profile: nil` (no `embedder` key either, since
  the legacy field is being deleted in this phase).
- Modified: `Sources/VecKit/IndexingPipeline.swift` — if
  `init(embedder:)` was kept as a shim in 3d, delete it now.
  Only `init(profile:)` remains.
- Modified: `Sources/VecKit/DatabaseLocator.swift` — remove the
  legacy `embedder: EmbedderRecord?` field from
  `DatabaseConfig`. Remove the `EmbedderRecord` struct.
  Remove `migratePreRefactorEmbedderRecord`.
- Deleted: `Sources/VecKit/EmbedderFactory.swift` — verify
  with `grep` that no file references `EmbedderFactory`,
  `EmbedderRecord`, `unknownEmbedder`, `embedderMismatch`, or
  `embedderNotRecorded` after this commit.
- Modified: `Sources/VecKit/RecursiveCharacterSplitter.swift` —
  drop `defaultChunkSize` and `defaultChunkOverlap` constants;
  require explicit `chunkSize` and `chunkOverlap` in `init`.
  `defaultSeparators` stays.
- Modified: `Tests/VecKitTests/TrademarkTranscriptFixtureTests.swift`
  — collapse the two hardcoded `testNomic…` / `testNL…`
  methods into the parameterized loop from §"Test plan"
  item 4 over `IndexingProfileFactory.builtIns`.
- Modified: `Tests/vecTests/ProfileMismatchTests.swift`
  (extend in-place) — add the `search`/`insert` rows of the
  five-case matrix that were deferred in 3d:
  - pre-profile DB (`profile == nil`, `chunkCount > 0`),
    `search "q"` → `preProfileDatabase`.
  - pre-profile DB, `insert path` → `preProfileDatabase`.
  - fresh DB (`profile == nil`, `chunkCount == 0`),
    `search "q"` → `profileNotRecorded`.
  - fresh DB, `insert path` → `profileNotRecorded`.
- Modified: any test that previously relied on the
  `RecursiveCharacterSplitter` default-constant constructor —
  flip them to pass explicit chunk params (or to obtain a
  splitter through `IndexingProfileFactory.make`).
- Modified: `Tests/VecKitTests/IndexingProfileConfigTests.swift`
  — update the legacy-decode test to confirm a config with
  ONLY the `embedder` key still decodes to `profile == nil`
  (the `embedder` field is now an unknown key the decoder
  ignores), and remove any tests of the old `embedder` field
  shape since the struct no longer carries it.
- New: `indexing-profile.md` — design doc, 200–300 lines, in
  the tone of `archived/pluggable-embedders.md`. Covers the
  identity grammar, the alias / identity / `BuiltIn`
  distinction, the check-order, the `partialChunkOverride`
  rule, the strict no-inheritance rationale, the deferred
  `--splitter` work, and the open extension points (per-
  profile whole-doc policy, identity-grammar extension for
  splitter discriminators).

**Ship criteria.**

- `swift build` clean.
- `swift test` exits 0. Full `ProfileMismatchTests` matrix
  (now ten cases) passes. `TrademarkTranscriptFixtureTests`
  per-profile loop passes for both built-ins.
- `grep` confirms no references to `EmbedderFactory`,
  `EmbedderRecord`, `unknownEmbedder`, `embedderMismatch`,
  `embedderNotRecorded`,
  `RecursiveCharacterSplitter.defaultChunkSize`,
  `RecursiveCharacterSplitter.defaultChunkOverlap`, or
  `migratePreRefactorEmbedderRecord` anywhere in the tree.
- `vec info` renders all four `Profile:` states correctly
  against hand-crafted fixtures.
- `vec list` includes the profile identity column on every
  row.
- `indexing-profile.md` exists at the expected path with the
  expected length and tone.

**Does NOT yet do.**

- No retrieval-rubric scoring — that's Phase 5.
- No new embedders or splitters land here (deferred per
  §"Out of scope").
- No `--splitter` flag (deferred; design doc explains the
  extension path).

**Budget.** 1.5–2 h.

**Checkpoint.** Commit (`feat: complete IndexingProfile rollout
— flip remaining commands, delete EmbedderFactory, design doc`)
→ proceeds straight to Phase 4 (final whole-diff review across
3a–3e). No mid-phase review-cycle gate after 3e because Phase 4
IS the cumulative review.

## Test coverage required before merge

Pre-merge gate (Phase 4):

- [ ] `swift build` clean.
- [ ] `swift test` exits 0.
- [ ] `IndexingProfileTests` covers: built-in resolution (both
      aliases), full-override composition, strict identity parsing
      (full negative matrix — garbled/whitespace/leading-zero/
      uppercase/extra-segments all reject with
      `malformedProfileIdentity`), grammar-valid but unknown alias
      rejects with `unknownProfile` (distinct error), invalid-
      chunk-param errors, partial-override precondition.
- [ ] `IndexingProfileConfigTests` covers: profile-present round
      trip, profile-nil round trip, pre-profile JSON decode to
      `profile == nil`, factory alias round trip.
- [ ] `ProfileMismatchTests` covers the five-case matrix:
      recorded-nomic vs. request-nl; recorded-nomic vs. request-
      nomic-with-custom-chunks; recorded-nomic vs. request-nomic-
      no-override (succeeds); pre-profile DB → `preProfileDatabase`;
      fresh DB → `profileNotRecorded`. Plus a partial-override
      case → `partialChunkOverride`.
- [ ] `TrademarkTranscriptFixtureTests` runs its per-profile loop
      and passes for both built-ins.
- [ ] `NomicEmbedderConcurrencyTests` + `NLEmbedderConcurrencyTests`
      still green.
- [ ] No file references `EmbedderFactory`, `EmbedderRecord`,
      `unknownEmbedder`, `embedderMismatch`, `embedderNotRecorded`,
      `RecursiveCharacterSplitter.defaultChunkSize`, or
      `migratePreRefactorEmbedderRecord` (grep check).
- [ ] `indexing-profile.md` exists, 200–300 lines, matches the tone
      of `archived/pluggable-embedders.md`.
- [ ] Each of the five sub-phases (3a–3e) has its own commit, and
      each of 3a–3d has a corresponding `review-cycle` artifact
      (2 reviewer reports + manager approval) recorded before the
      next sub-phase started.

Post-merge verification (Phase 5):

- [ ] `vec reset markdown-memory` + `update-index --embedder nl`
      → score ≈ 6/60 (±1), transcript.txt chunk count > 0.
- [ ] `vec reset markdown-memory` + `update-index --embedder nomic`
      → score ≈ 35/60 (±2), transcript.txt chunk count > 0.

## Risks and open questions

1. **Cross-profile override composition.** Can a user request
   "nomic embedder with NL's chunking" via
   `--embedder nomic --chunk-chars 2000 --chunk-overlap 200`?
   **Answer: yes.** The override path composes freely — alias picks
   the embedder and a set of default chunk params; any supplied
   chunk params replace those defaults. The resulting identity
   `"nomic@2000/200"` is distinct from both `"nomic@1200/240"` and
   `"nl@2000/200"`, so the DB records it as its own profile and
   the mismatch check treats it as such. Document in
   `indexing-profile.md`.

2. **Full override equal to built-in default.** If someone runs
   `--embedder nomic --chunk-chars 1200 --chunk-overlap 240`
   (explicitly supplying nomic's defaults, in full — partial
   overrides hard-fail per §"Rule on partial overrides"), the
   resulting identity is `"nomic@1200/240"` — the same as the
   alias-default. Fine: the `isBuiltIn` flag distinguishes "user
   typed the numbers" from "factory picked them" in live memory,
   but the persisted identity is the same and the mismatch check
   compares on identity alone. An override that coincides with the
   default is indistinguishable from "took the default" post-
   persist, which is the correct behavior.

3. **Alias rename in the future.** If a future release renames
   the `nomic` alias to `nomic-v15`, existing DBs with identity
   `"nomic@1200/240"` will fail `resolve` with `unknownProfile`.
   The user gets a clear error pointing them at `vec reset`.
   That's the intended behavior for a breaking rename; the plan
   doesn't try to support aliases-with-history.

4. **Identity grammar extensions.** The current grammar is
   `<alias>@<size>/<overlap>`. Adding a splitter discriminator
   later means extending to `<alias>@<splitter>@<params>`. Old
   identities (`nomic@1200/240`) will look malformed to the new
   parser unless it accepts both shapes. Easiest path forward
   is "the number of `@` determines the grammar variant." Not a
   blocker now; called out in the design doc.

5. **Per-splitter unit ambiguity.** `RecursiveCharacterSplitter`
   chunk params are in characters; `LineBasedSplitter` params
   are in lines. When `--splitter` lands, the CLI needs per-
   splitter flag names (`--chunk-chars` vs `--chunk-lines`) or
   a renamed neutral `--chunk-size` with context-sensitive
   validation. Not blocking; design-doc note.

6. **Whole-chunk suppression.** See "Whole-doc emission policy"
   above. The plan keeps behavior uniform; adding a per-profile
   `emitsWholeChunk` is a one-field addition on the profile struct
   + one branch in `TextExtractor`. Not landing now.

7. **`dimension` on `ProfileRecord` is redundant with the resolved
   profile.** Intentional — see "Why `dimension` is denormalized"
   above. The redundancy is bounded (one int) and the failure-
   ordering benefit is concrete.

## Open questions (answered)

These are the six open questions called out by the round-2 review
brief. Answers are load-bearing for Phase 3 implementation.

1. **How does `vec info` render a custom-profile identity vs. a
   built-in?** Use the `isBuiltIn` flag on the resolved profile:
   - `isBuiltIn == true` → `Profile: nomic@1200/240 (768d)`
   - `isBuiltIn == false` → `Profile: nomic@500/100 (custom, based
     on nomic) (768d)`
   - `profile == nil` and `chunkCount == 0` → `Profile: (not yet
     recorded)`
   - `profile == nil` and `chunkCount > 0` → `Profile: (pre-profile
     database — run 'vec reset <db>' to rebuild)`
   The "(custom, based on nomic)" rendering is what makes the
   `isBuiltIn` flag worth keeping (see Q6 below). `info` resolves
   the profile from `config.profile.identity` via
   `IndexingProfileFactory.resolve`; on unknown-alias or malformed
   identity the resolve error propagates and `info` surfaces the
   standard `unknownProfile` / `malformedProfileIdentity` message.

2. **`ProfileRecord` equality — identity-string or structural
   across (alias, size, overlap)?** Use **identity-string
   equality**. The strict-round-trip invariant from decision 3
   (the identity parser re-renders and string-compares with the
   input) means the identity string is a canonical encoding of the
   structural triple — the two comparison schemes are equivalent
   by construction. Picking the simpler string comparison saves a
   struct parse on every mismatch check and keeps the error text
   trivially renderable (just print the two identity strings).

3. **Config write ordering when the CLI produces a custom identity
   — write `ProfileRecord` before the pipeline touches the DB?**
   Yes, for both alias-default and custom-identity cases, the
   config write happens at step 6 of the `update-index` check
   order, *before* the pipeline opens the vector database for
   writes. A single code path, one write, no branch on "is this
   the default or a custom override." Rationale: if the pipeline
   crashes mid-index, the next command must see a populated
   `ProfileRecord` (otherwise it would misfire as
   `preProfileDatabase`). Writing the profile record first means
   partial-index state is always legible and the user gets a
   clean `profileMismatch` on retry with different flags.

4. **`vec list` — does it print the profile identity per DB?**
   Yes — one-line addition. Each row in the `vec list` output
   includes the profile identity (or `(not recorded)` / `(pre-
   profile)`) alongside the DB name and source path. This keeps
   `vec list` useful as the "what do I have and what is it
   indexed with" dashboard without requiring a follow-up
   `vec info <name>` per DB. Formatting: single column appended
   to the right of the existing output; no changes to column
   headers needed since `vec list`'s existing output is one line
   per DB with space-separated fields.

5. **`alias(forCanonicalEmbedderName:)` post-refactor — who calls
   it?** After the refactor, **no callers remain**. Its original
   purpose was rendering "embedder: nomic" in `vec info` from a
   persisted canonical name (e.g. `nomic-v1.5-768`), but
   `vec info` now renders directly from the identity string
   (`nomic@1200/240`), which already contains the alias as its
   prefix. **Delete the function** in the same commit that
   deletes `EmbedderFactory.swift`. Removes a function and a
   reverse-lookup table that no longer has a consumer.

6. **`isBuiltIn` — what checks this, and what does the answer
   affect?** Exactly one caller: `vec info` rendering (see Q1
   above). It's the difference between rendering a bare identity
   and appending `(custom, based on <alias>)`. The flag could be
   derived at `info` time by comparing the profile's chunk params
   to `IndexingProfileFactory.builtIn(forAlias:).defaultChunkSize /
   defaultChunkOverlap`, but storing it on the profile is cheaper
   (one bool, computed once in the factory) and keeps `info`
   rendering as a straight dereference. **Keep the field.** The
   precedent for "piece of metadata used only in one error/info
   text" is `ProfileRecord.embedderName` — both exist for
   rendering.

## Out of scope

- Schema migration for pre-profile DBs. User runs `vec reset`.
- `--splitter` flag. Deferred; grammar and plumbing path are
  spelled out in the design doc.
- New embedders (llama, BGE, E5, etc.). They slot into
  `IndexingProfileFactory.builtIns` without any struct change.
- Retrieval-quality work (hybrid retrieval, query expansion,
  multi-granularity). Separate lever; see `status.md`.
- Per-profile whole-doc policy. Uniform today.
- Changing the `retrieval-rubric.md` rubric. Frozen reference.
