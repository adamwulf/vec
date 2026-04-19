import Foundation

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
    /// rendering to differentiate alias-default from user-supplied
    /// override.
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
