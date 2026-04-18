import Foundation
import NaturalLanguage

/// Wraps Apple's `NLEmbedding.sentenceEmbedding(for: .english)` behind
/// the `Embedder` protocol.
///
/// Restored after the nomic migration so the codebase has a second
/// concrete embedder to exercise the protocol surface, and because
/// NL is handy as a fast, no-download fallback on machines that
/// can't pull nomic weights.
///
/// **Thread-safety.** `NLEmbedding` itself is NOT safe to call
/// concurrently on a single instance — pre-nomic, that was the reason
/// `EmbedderPool` kept N copies. Wrapping the instance in an actor
/// serializes `vector(for:)` calls, which is the same correctness
/// guarantee. Throughput is lower than a multi-instance fanout would
/// be, but single-instance serialized throughput is fine for the
/// single-user CLI workloads this tool targets.
///
/// **Prefixes.** Unlike nomic, `NLEmbedding.sentenceEmbedding` was
/// NOT trained with `search_document: ` / `search_query: ` asymmetric
/// prefixes — those are a nomic-specific convention. For `NLEmbedder`,
/// `embedDocument` and `embedQuery` are identical; both feed the text
/// straight to the underlying embedding after trimming and
/// truncation.
public actor NLEmbedder: Embedder {

    public nonisolated let name = "nl-en-512"
    public nonisolated let dimension = 512

    /// Hard cap in characters applied before the text reaches
    /// `NLEmbedding.vector(for:)`. The underlying C++ runtime was
    /// observed to throw `std::bad_alloc` on very long strings
    /// (commit ecd3ebf introduced the cap). 10 000 chars is a
    /// documented safe ceiling.
    public static let maxInputCharacters = 10_000

    private let embedding: NLEmbedding?

    public init() {
        self.embedding = NLEmbedding.sentenceEmbedding(for: .english)
    }

    public func embedDocument(_ text: String) async throws -> [Float] {
        try embed(text)
    }

    public func embedQuery(_ text: String) async throws -> [Float] {
        try embed(text)
    }

    private func embed(_ text: String) throws -> [Float] {
        guard let embedding else {
            throw EmbedderError.modelUnavailable(
                embedder: name,
                detail: "NLEmbedding.sentenceEmbedding(for: .english) returned nil"
            )
        }

        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if trimmed.count > Self.maxInputCharacters {
            trimmed = String(trimmed.prefix(Self.maxInputCharacters))
        }

        guard let vector = embedding.vector(for: trimmed) else {
            // NLEmbedding returns nil for inputs it can't process
            // (e.g. all non-English tokens). The pipeline treats this
            // as a per-chunk skip.
            throw EmbedderError.embedFailed(
                embedder: name,
                detail: "NLEmbedding returned nil for input (first 40 chars: \(trimmed.prefix(40)))"
            )
        }

        return vector.map { Float($0) }
    }
}
