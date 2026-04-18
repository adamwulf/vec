import Foundation

/// A text-embedding backend. Conforming types are expected to load a
/// model lazily on first use and cache it for the lifetime of the
/// instance. Concurrent calls are serialized by the conformer — every
/// current implementation is an `actor`, which gives that for free.
///
/// Two "name" concepts in play:
/// - `name` below is the **canonical** identifier, e.g.
///   "nomic-v1.5-768". It is stored in `DatabaseConfig.embedder.name`
///   and used for mismatch checks.
/// - The CLI `--embedder` flag takes a short **alias** like "nomic"
///   or "nl". `EmbedderFactory` maps aliases to concrete types; the
///   concrete type's `name` is the canonical form that lands in the
///   config.
public protocol Embedder: Sendable {
    /// Short, stable identifier for this embedder. Persisted in
    /// `DatabaseConfig.embedder.name`. Must uniquely identify the
    /// model + dim so a DB indexed with a different model is
    /// detectable at open time. Nonisolated so non-actor callers
    /// (DB writer, CLI) can read it synchronously — conforming
    /// actors back it with a `nonisolated let`.
    nonisolated var name: String { get }

    /// Dimensionality of every vector returned. Every vector stored
    /// in a DB must match this for the embedder recorded in its
    /// `DatabaseConfig`. Nonisolated for the same reason as `name`.
    nonisolated var dimension: Int { get }

    /// Embed a document chunk for indexing.
    ///
    /// Implementations that were trained with an asymmetric
    /// index/query convention (e.g. nomic's `search_document:` /
    /// `search_query:` prefixes) apply the prefix internally. For
    /// models without such training (e.g. `NLEmbedding.sentenceEmbedding`)
    /// this is identical to `embedQuery`.
    func embedDocument(_ text: String) async throws -> [Float]

    /// Embed a query at search time. See `embedDocument` for the
    /// index/query asymmetry discussion.
    func embedQuery(_ text: String) async throws -> [Float]
}

/// Errors raised by an `Embedder` implementation. Kept out of
/// `VecError` so the shared error surface doesn't bloat with
/// embedder-specific cases.
public enum EmbedderError: Error, LocalizedError {
    /// Model could not be loaded or initialized (e.g.
    /// `NLEmbedding.sentenceEmbedding(for: .english)` returned nil
    /// on a system where the resources are missing).
    case modelUnavailable(embedder: String, detail: String)
    /// The embedder ran but returned no vector for a non-empty input.
    /// Extremely rare; treated as a per-chunk skip by the pipeline.
    case embedFailed(embedder: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .modelUnavailable(let embedder, let detail):
            return "Embedder '\(embedder)' model unavailable: \(detail)"
        case .embedFailed(let embedder, let detail):
            return "Embedder '\(embedder)' failed to embed input: \(detail)"
        }
    }
}
