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

| Phase | Owner | Deliverable | Budget |
|------:|-------|-------------|-------:|
| 1 | this agent (77b5f3be) | `indexing-profile-plan.md` — you're reading it | 45 min |
| 2 | 2 reviewer agents in parallel, up to 3 rounds | Plan review (architecture + correctness) via `review-cycle` skill | 1–2 h |
| 3 | one impl agent | Code + `indexing-profile.md` design doc | 5–6 h |
| 4 | 2 reviewer agents in parallel, up to 3 rounds | Code review (architecture + correctness) via `review-cycle` skill | 1–2 h |
| 5 | manager or human | Retrieval-rubric sanity sweeps (both profiles) | 2 h |
| 6 | manager | Final commit check + merge to `agent/agent-c54ba5da` | 30 min |

Phase 3 is the single longest chunk. The pluggable-embedders impl
ran ~3–4 h for a narrower scope (one factory, one error rename, no
identity parser, no CLI-flag cross-validation). This refactor is
wider: three new error variants (`preProfileDatabase`,
`malformedProfileIdentity`, `partialChunkOverride`) on top of
`invalidChunkParams`, a strict regex + round-trip parser with a
negative-test matrix, CLI-layer rejection of partial chunk
overrides at the top of `update-index`, and the new
`ProfileMismatchTests` five-case suite on top of the rewritten
`IndexingProfileConfigTests`. Budget is 5–6 h: roughly 2 h on the
factory + struct + parser, 2 h on CLI command wiring and check-
order, 1–2 h on the test suites and the design doc.

## Rollout sequence (Phase 3 order)

Small commits, `swift test` green between each:

1. **`IndexingProfile` struct + `IndexingProfileFactory`** —
   `Sources/VecKit/IndexingProfile.swift`. No callers yet. Add
   `IndexingProfileTests` with the full strict-parsing matrix
   (~15 tests). ~179 existing + ~15 new = ~194 pass.
2. **`VecError` rename + expand wave** — rename `unknownEmbedder` →
   `unknownProfile`, `embedderMismatch` → `profileMismatch`,
   `embedderNotRecorded` → `profileNotRecorded`; add
   `preProfileDatabase`, `malformedProfileIdentity(String)`,
   `partialChunkOverride`, `invalidChunkParams(String)`.
   Mechanical; every call-site flips in one commit.
3. **`DatabaseConfig` shape flip** — `embedder: EmbedderRecord?`
   → `profile: ProfileRecord?`. Delete
   `migratePreRefactorEmbedderRecord`. Rewrite `EmbedderConfigTests`
   → `IndexingProfileConfigTests`.
4. **`RecursiveCharacterSplitter` default removal** — drop the
   constants, require explicit params. Fix up any test-only
   callers that relied on defaults.
5. **`IndexingPipeline.init(profile:)`** — swap the init signature.
   `EmbedderPool` unchanged internally.
6. **CLI commands** — `UpdateIndexCommand`, `SearchCommand`,
   `InsertCommand`, `ResetCommand`, `InfoCommand` in that order.
   Each commit is self-contained and keeps `swift test` green.
7. **`ProfileMismatchTests`** — add
   `Tests/vecTests/ProfileMismatchTests.swift` covering the five-
   case matrix + `partialChunkOverride`. Lands after the CLI
   commands so it has a working surface to invoke.
8. **`TrademarkTranscriptFixtureTests` loopification** — benefits
   from the new factory surface.
9. **Delete `Sources/VecKit/EmbedderFactory.swift`** — verify no
   remaining references.
10. **Write `indexing-profile.md`** — the design doc.

No single commit leaves the tree broken.

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
