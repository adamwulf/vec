import Foundation
import CoreML
import NaturalLanguage

/// `Embedder` wrapping `NLEmbedding.sentenceEmbedding(for: .english)`. See `archived/pluggable-embedders.md`.
public actor NLEmbedder: Embedder {

    public nonisolated let name = "nl-en-512"
    public nonisolated let dimension = 512

    /// Hard cap guarding `NLEmbedding.vector(for:)` against `std::bad_alloc` on very long strings.
    public static let maxInputCharacters = 10_000

    private let embedding: NLEmbedding?

    /// Accepts and ignores `computePolicy` — `NLEmbedding` uses Apple's
    /// NaturalLanguage framework (not CoreML/MLTensor), so the E6
    /// `--compute-policy` flag has no effect on this embedder. Kept on
    /// the init signature so `IndexingProfileFactory.make` can pass
    /// the flag uniformly across all registered embedders.
    public init(computePolicy: MLComputePolicy? = nil) {
        _ = computePolicy
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
