import Foundation
import NaturalLanguage

/// Generates text embeddings using Apple's on-device NLEmbedding.
/// NOT safe for concurrent use on the same instance — concurrent calls
/// to `vector(for:)` on the same `NLEmbedding` cause segfaults in the
/// underlying C++ runtime. Create separate instances for concurrent
/// tasks (each loads an independent ~50 MB model).
public final class EmbeddingService: @unchecked Sendable {

    private let embedding: NLEmbedding?

    /// The dimension of the embedding vectors produced by this service.
    public let dimension: Int

    /// Maximum number of characters passed to NLEmbedding.
    /// Very large strings cause the underlying C++ runtime to throw
    /// `std::bad_alloc`, crashing the process. 10 000 characters is
    /// well within what the framework handles and captures enough
    /// content for a meaningful sentence-level embedding.
    static let maxEmbeddingTextLength = 10_000

    public init() {
        self.embedding = NLEmbedding.sentenceEmbedding(for: .english)
        // NLEmbedding for English sentences produces 512-dimensional vectors
        self.dimension = self.embedding?.dimension ?? 512
    }

    /// Generate an embedding vector for the given text.
    /// Returns nil if the text cannot be embedded.
    /// Text longer than ``maxEmbeddingTextLength`` is truncated to
    /// avoid a crash in the NaturalLanguage framework.
    public func embed(_ text: String) -> [Float]? {
        guard let embedding = embedding else { return nil }

        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.count > Self.maxEmbeddingTextLength {
            trimmed = String(trimmed.prefix(Self.maxEmbeddingTextLength))
        }

        guard let vector = embedding.vector(for: trimmed) else { return nil }

        return vector.map { Float($0) }
    }
}
