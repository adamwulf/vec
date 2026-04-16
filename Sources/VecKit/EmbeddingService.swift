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

    /// Detect the dominant language of the given text.
    /// Returns nil if the language cannot be determined.
    public func detectLanguage(_ text: String) -> NLLanguage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return NLLanguageRecognizer.dominantLanguage(for: trimmed)
    }

    /// Check if the text is non-English and, if so, emit a one-time warning to stderr.
    /// Pass `warned` as an inout flag scoped per-file to ensure only one warning per file.
    /// Returns true if a warning was emitted.
    @discardableResult
    public func warnIfNonEnglish(text: String, filePath: String, warned: inout Bool) -> Bool {
        guard !warned else { return false }
        guard let lang = detectLanguage(text), lang != .english, lang != .undetermined else { return false }
        FileHandle.standardError.write(Data("Warning: non-English content detected in \(filePath) (detected: \(lang.rawValue)), embedding quality may be reduced\n".utf8))
        warned = true
        return true
    }
}
