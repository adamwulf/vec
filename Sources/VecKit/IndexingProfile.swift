import Foundation
import CoreML

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

    /// Canonical exemplar embedder instance. Its `name` + `dimension`
    /// are the dim source of truth for the DB
    /// (`VectorDatabase(dimension:)`) and for callers that need a
    /// single embedder (e.g. query-side search). For the indexing
    /// pipeline, prefer `embedderFactory` — it mints fresh siblings
    /// so the pool can hold N of them concurrently.
    public let embedder: any Embedder

    /// Mints fresh sibling embedders of the same type/config as
    /// `embedder`. The indexing pipeline calls this N times to fill
    /// `EmbedderPool` — N instances = N actor mailboxes = real
    /// parallelism. Query-side code keeps using `embedder` directly;
    /// a single instance is fine for a single query.
    public let embedderFactory: @Sendable () -> any Embedder

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
    /// rendering to differentiate alias-default from user-supplied
    /// override.
    public let isBuiltIn: Bool

    public init(
        identity: String,
        embedder: any Embedder,
        embedderFactory: @escaping @Sendable () -> any Embedder,
        splitter: any TextSplitter,
        chunkSize: Int,
        chunkOverlap: Int,
        isBuiltIn: Bool
    ) {
        precondition(chunkSize > 0)
        precondition(chunkOverlap >= 0 && chunkOverlap < chunkSize)
        self.identity = identity
        self.embedder = embedder
        self.embedderFactory = embedderFactory
        self.splitter = splitter
        self.chunkSize = chunkSize
        self.chunkOverlap = chunkOverlap
        self.isBuiltIn = isBuiltIn
    }

    /// Parses a persisted identity string into its alias + chunk
    /// components. Strict grammar:
    ///
    ///   `^[a-z0-9-]+@[1-9][0-9]*/[0-9]+$`
    ///
    /// Rejects leading zeros on the size, any whitespace, uppercase
    /// letters, or extra separators. After a successful regex match,
    /// the parsed components are re-rendered and compared string-for-
    /// string against the input — any mismatch throws
    /// `VecError.malformedProfileIdentity(identity)`. This round-trip
    /// check is the single invariant that keeps identity comparison
    /// as simple string equality elsewhere in the codebase.
    public static func parseIdentity(_ identity: String) throws -> (alias: String, chunkSize: Int, chunkOverlap: Int) {
        let pattern = #"^([a-z0-9-]+)@([1-9][0-9]*)/([0-9]+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: identity,
                  range: NSRange(identity.startIndex..., in: identity)),
              match.numberOfRanges == 4,
              let aliasRange = Range(match.range(at: 1), in: identity),
              let sizeRange = Range(match.range(at: 2), in: identity),
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
        return (alias: alias, chunkSize: size, chunkOverlap: overlap)
    }
}

/// Resolves CLI aliases and identity strings to live `IndexingProfile`
/// instances.
public enum IndexingProfileFactory {

    /// Descriptor for a built-in profile. Static data only — no live
    /// `Embedder` instance until `make(...)` is called.
    public struct BuiltIn: Sendable {
        public let alias: String
        public let canonicalEmbedderName: String
        public let canonicalDimension: Int
        public let defaultChunkSize: Int
        public let defaultChunkOverlap: Int
    }

    public static let defaultAlias = "e5-base"

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
        // 1200/240 selected by Phase D sweep against bean-counter rubric
        // (36/60, 9/10 top-10_either on markdown-memory corpus,
        // rescored 2026-04-20 from archived JSON; the 2026-04-19 manual
        // count of 39/60 was off by 3 — see e4-next-steps-report §4a).
        BuiltIn(
            alias: "bge-base",
            canonicalEmbedderName: "bge-base-en-v1.5",
            canonicalDimension: 768,
            defaultChunkSize: 1200,
            defaultChunkOverlap: 240
        ),
        // bge-small-en-v1.5 — 384-dim, "fast tier" option. The E5.4
        // chunk-geometry sweep (15 points: {400,600,800,1200,1600} ×
        // {0%,10%,20%}) identified 1200/0 as the rubric peak (30/60,
        // 9/10 top10_either), beating the seeded 1200/240 single-point
        // result (25/60) by 5 points. See
        // `data/retrieval-bge-small-sweep.md` for the full grid.
        BuiltIn(
            alias: "bge-small",
            canonicalEmbedderName: "bge-small-en-v1.5",
            canonicalDimension: 384,
            defaultChunkSize: 1200,
            defaultChunkOverlap: 0
        ),
        // bge-large-en-v1.5 — 1024-dim, "max quality" option. The E5.4
        // chunk-geometry sweep (12 points: {800,1200,1600,2000} ×
        // {0%,10%,20%}) identified 1200/0 as the rubric peak (34/60,
        // 9/10 top10_either, 3/10 top10_both). Beats the seeded
        // 1200/240 single-point result (31/60) by 3 points. Like
        // bge-small, bge-large prefers 1200 chunks with no overlap;
        // unlike bge-small, bge-large's peak closes most of the gap
        // to bge-base (34 vs 36). See `data/retrieval-bge-large-sweep.md`.
        BuiltIn(
            alias: "bge-large",
            canonicalEmbedderName: "bge-large-en-v1.5",
            canonicalDimension: 1024,
            defaultChunkSize: 1200,
            defaultChunkOverlap: 0
        ),
        // Provisional chunk defaults seeded from `nomic`. Phase D of
        // `embedder-expansion-plan.md` replaces these with tuned values.
        BuiltIn(
            alias: "nl-contextual",
            canonicalEmbedderName: "nl-contextual-en-512",
            canonicalDimension: 512,
            defaultChunkSize: 1200,
            defaultChunkOverlap: 240
        ),
        // gte-base-en-v1.5 — 768-dim, thenlper/gte-base. Direct peer of
        // bge-base (same dim, same tokenizer, same CLS+L2 pooling, no
        // query/passage prefix). The E5.6 chunk-geometry sweep (12
        // points: {400,800,1200,1600} × {0%,10%,20%}) identified
        // 1600/0 as the rubric peak at 8/60, 3/10 top10_either — far
        // below bge-base@1200/240's 36/60 on the same corpus. gte-base
        // is retained as an opt-in built-in but is NOT a default
        // candidate on markdown-memory. See
        // `data/retrieval-gte-base-sweep.md` for the full grid and
        // the content-discrimination failure-mode analysis.
        BuiltIn(
            alias: "gte-base",
            canonicalEmbedderName: "gte-base-en-v1.5",
            canonicalDimension: 768,
            defaultChunkSize: 1600,
            defaultChunkOverlap: 0
        ),
        // e5-base-v2 — 768-dim, intfloat/e5-base-v2. Third 768-dim
        // non-BGE model after gte-base. Two shape differences vs the
        // other Bert-family embedders we carry:
        //   • MEAN POOLING (not CLS). Implemented manually in
        //     `E5BaseEmbedder` by driving `Bert.Model` directly with
        //     the attention mask and running masked mean over the
        //     sequence output, then L2-normalizing.
        //   • QUERY/PASSAGE PREFIXES. Documents get `"passage: "` and
        //     queries get `"query: "` prepended inside the embedder;
        //     callers remain prefix-unaware (same protocol surface as
        //     every other embedder).
        // The E5.7 chunk-geometry sweep (12 points:
        // {400,800,1200,1600} × {0%,10%,20%}) identified 1200/0 as
        // the rubric peak: 40/60, 9/10 top10_either, 6/10 top10_both.
        // That BEATS bge-base@1200/240 (36/60, 9/10, 3/10) on the
        // same corpus — by +4 on total_60 and 2× on the stricter
        // top10_both metric, with wallclock parity (~1025 s vs
        // ~1003 s). `e5-base@400/40` is a co-peak at 40/60 with
        // 10/10 top10_either but loses the top10_both tiebreaker
        // (5 vs 6). See `data/retrieval-e5-base-sweep.md` for the
        // full grid, three-way 768-dim comparison, and the
        // candidate-global-default analysis. This commit updates the
        // e5-base alias default only; a global default flip from
        // bge-base → e5-base is held back pending manager review.
        BuiltIn(
            alias: "e5-base",
            canonicalEmbedderName: "e5-base-v2",
            canonicalDimension: 768,
            defaultChunkSize: 1200,
            defaultChunkOverlap: 0
        ),
        // mxbai-embed-large-v1 — 1024-dim, mixedbread-ai/mxbai-embed-large-v1.
        // Direct peer of bge-large (same dim, same Bert-large architecture,
        // same CLS+L2 pooling) with one shape difference: an asymmetric
        // **query-only** prefix is required for retrieval —
        // `"Represent this sentence for searching relevant passages: "` —
        // injected inside `MxbaiEmbedLargeEmbedder` so callers stay
        // prefix-unaware. Documents take no prefix.
        //
        // The E5.8 chunk-geometry sweep (12 points: {800,1200,1600,2000}
        // × {0%,10%,20%}, mirroring bge-large's E5.4c grid) identified
        // 800/80 as the rubric peak: 31/60, 8/10 top10_either, 4/10
        // top10_both. `800/160` is the co-peak on total_60 (31/60) but
        // loses the tiebreaker on top10_both (3 vs 4). The peak shifts
        // to the size-800 band — different from bge-large (peak at 1200)
        // and bge-base (peak at 1200) — most plausibly because the query
        // prefix's ~10 BERT WordPiece tokens eat into the 512-token
        // budget. mxbai-large does NOT beat bge-large@1200/0 (34/60)
        // and is well below bge-base@1200/240 (36/60) and e5-base@1200/0
        // (40/60); the MTEB headroom over bge-large does not transfer
        // to markdown-memory rubric performance. Retained as an opt-in
        // 1024-dim alternative to bge-large, NOT a default candidate.
        // See `data/retrieval-mxbai-large-sweep.md` for the full grid
        // and the cross-model 1024-dim head-to-head with bge-large.
        BuiltIn(
            alias: "mxbai-large",
            canonicalEmbedderName: "mxbai-embed-large-v1",
            canonicalDimension: 1024,
            defaultChunkSize: 800,
            defaultChunkOverlap: 80
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
        chunkOverlap: Int? = nil,
        computePolicy: MLComputePolicy? = nil
    ) throws -> IndexingProfile {
        precondition(
            (chunkSize == nil) == (chunkOverlap == nil),
            "IndexingProfileFactory.make requires both chunk overrides or neither"
        )
        let entry = try builtIn(forAlias: alias)
        let effectiveSize = chunkSize ?? entry.defaultChunkSize
        let effectiveOverlap = chunkOverlap ?? entry.defaultChunkOverlap
        try validate(chunkSize: effectiveSize, chunkOverlap: effectiveOverlap)

        let isBuiltIn = (effectiveSize == entry.defaultChunkSize
                      && effectiveOverlap == entry.defaultChunkOverlap)
        let identity = "\(alias)@\(effectiveSize)/\(effectiveOverlap)"

        // Alias → factory closure. The closure is `@Sendable` and
        // captures only the alias string (literal) plus the optional
        // compute-policy override, so the pool can call it N times from
        // any isolation domain to mint fresh sibling instances.
        //
        // `computePolicy` is deliberately NOT rolled into `identity` —
        // it's a runtime placement preference (CPU/ANE/GPU), not a
        // semantic property of the stored vectors. Two runs at the same
        // chunk geometry with different compute policies must round-
        // trip through `config.json`'s stored identity unchanged.
        let policy = computePolicy
        let factory: @Sendable () -> any Embedder
        switch alias {
        case "nomic":         factory = { NomicEmbedder(computePolicy: policy) }
        case "nl":            factory = { NLEmbedder(computePolicy: policy) }
        case "bge-base":      factory = { BGEBaseEmbedder(computePolicy: policy) }
        case "bge-small":     factory = { BGESmallEmbedder(computePolicy: policy) }
        case "bge-large":     factory = { BGELargeEmbedder(computePolicy: policy) }
        case "nl-contextual": factory = { NLContextualEmbedder(computePolicy: policy) }
        case "gte-base":      factory = { GTEBaseEmbedder(computePolicy: policy) }
        case "e5-base":       factory = { E5BaseEmbedder(computePolicy: policy) }
        case "mxbai-large":   factory = { MxbaiEmbedLargeEmbedder(computePolicy: policy) }
        default:              throw VecError.unknownProfile(alias)
        }
        let embedder = factory()

        let splitter = RecursiveCharacterSplitter(
            chunkSize: effectiveSize,
            chunkOverlap: effectiveOverlap
        )

        return IndexingProfile(
            identity: identity,
            embedder: embedder,
            embedderFactory: factory,
            splitter: splitter,
            chunkSize: effectiveSize,
            chunkOverlap: effectiveOverlap,
            isBuiltIn: isBuiltIn
        )
    }

    /// Parses a persisted identity string and returns the matching
    /// live profile. Delegates the strict-grammar + round-trip parse
    /// to `IndexingProfile.parseIdentity` — the one parser in the
    /// tree — then calls `make` with explicit chunk params so that
    /// `isBuiltIn` is computed from effective values.
    ///
    /// `computePolicy` is a runtime placement preference (CPU/ANE/GPU);
    /// it is NOT part of the persisted identity and therefore must be
    /// re-supplied on each resolve if the caller wants a non-default
    /// policy.
    public static func resolve(
        identity: String,
        computePolicy: MLComputePolicy? = nil
    ) throws -> IndexingProfile {
        let parsed = try IndexingProfile.parseIdentity(identity)
        return try make(
            alias: parsed.alias,
            chunkSize: parsed.chunkSize,
            chunkOverlap: parsed.chunkOverlap,
            computePolicy: computePolicy
        )
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
