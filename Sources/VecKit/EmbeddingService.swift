import Foundation
import NaturalLanguage

/// Generates text embeddings using Apple's on-device NLEmbedding.
public class EmbeddingService {

    private let embedding: NLEmbedding?

    /// The dimension of the embedding vectors produced by this service.
    public let dimension: Int

    public init() {
        self.embedding = NLEmbedding.sentenceEmbedding(for: .english)
        // NLEmbedding for English sentences produces 512-dimensional vectors
        self.dimension = self.embedding?.dimension ?? 512
    }

    /// Generate an embedding vector for the given text.
    /// Returns nil if the text cannot be embedded.
    public func embed(_ text: String) -> [Float]? {
        guard let embedding = embedding else { return nil }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let vector = embedding.vector(for: trimmed) else { return nil }

        return vector.map { Float($0) }
    }

    /// Detect the dominant language of the given text.
    /// Returns nil if the language cannot be determined.
    public func detectLanguage(_ text: String) -> NLLanguage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return NLLanguageRecognizer.dominantLanguage(for: trimmed)
    }
}
