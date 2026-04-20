import Foundation
import NaturalLanguage

/// `Embedder` wrapping Apple's `NLContextualEmbedding` for English.
///
/// The model is provided by the OS (macOS 14+ / iOS 17+) — nothing ships
/// in the app bundle, but the OS may download assets on first use via
/// `requestAssets()`. Output is 512-dim per-token vectors; this embedder
/// mean-pools across tokens and L2-normalizes the result so cosine-
/// similarity search against the stored vectors is correct.
///
/// The model's `maximumSequenceLength` is typically 256 tokens; we cap
/// input characters before handing the string to the framework.
public actor NLContextualEmbedder: Embedder {

    public nonisolated let name = "nl-contextual-en-512"
    public nonisolated let dimension = 512

    /// Character cap before truncation. `NLContextualEmbedding`'s max
    /// sequence is ~256 tokens; ~2000 English characters is a rough cap
    /// before the tokenizer truncates internally.
    public static let maxInputCharacters = 2_000

    private var loaded: NLContextualEmbedding?

    public init() {}

    public func embedDocument(_ text: String) async throws -> [Float] {
        try await embed(text)
    }

    public func embedQuery(_ text: String) async throws -> [Float] {
        try await embed(text)
    }

    private func embed(_ text: String) async throws -> [Float] {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.count > Self.maxInputCharacters {
            trimmed = String(trimmed.prefix(Self.maxInputCharacters))
        }

        let embedding = try await loadIfNeeded()

        let result: NLContextualEmbeddingResult
        do {
            result = try embedding.embeddingResult(for: trimmed, language: .english)
        } catch {
            throw EmbedderError.embedFailed(
                embedder: name,
                detail: "embeddingResult(for:language:) threw: \(error.localizedDescription)"
            )
        }

        let dim = embedding.dimension
        var sums = [Double](repeating: 0, count: dim)
        var tokenCount = 0
        result.enumerateTokenVectors(in: trimmed.startIndex..<trimmed.endIndex) { vector, _ in
            if vector.count == dim {
                for i in 0..<dim {
                    sums[i] += vector[i]
                }
                tokenCount += 1
            }
            return true
        }

        guard tokenCount > 0 else {
            throw EmbedderError.embedFailed(
                embedder: name,
                detail: "NLContextualEmbedding produced zero token vectors for input (first 40 chars: \(trimmed.prefix(40)))"
            )
        }

        let invCount = 1.0 / Double(tokenCount)
        let pooled: [Float] = sums.map { Float($0 * invCount) }
        return l2Normalize(pooled)
    }

    private func loadIfNeeded() async throws -> NLContextualEmbedding {
        if let loaded { return loaded }

        guard let embedding = NLContextualEmbedding(language: .english) else {
            throw EmbedderError.modelUnavailable(
                embedder: name,
                detail: "NLContextualEmbedding(language: .english) returned nil"
            )
        }

        if !embedding.hasAvailableAssets {
            do {
                let result = try await embedding.requestAssets()
                guard result == .available else {
                    throw EmbedderError.modelUnavailable(
                        embedder: name,
                        detail: "requestAssets() returned \(result); assets are not available locally and could not be downloaded"
                    )
                }
            } catch let error as EmbedderError {
                throw error
            } catch {
                throw EmbedderError.modelUnavailable(
                    embedder: name,
                    detail: "requestAssets() threw: \(error.localizedDescription)"
                )
            }
        }

        do {
            try embedding.load()
        } catch {
            throw EmbedderError.modelUnavailable(
                embedder: name,
                detail: "load() threw: \(error.localizedDescription)"
            )
        }

        self.loaded = embedding
        return embedding
    }
}
