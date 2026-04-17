import Foundation
import Embeddings

/// Wraps `swift-embeddings`' NomicBert model for
/// `nomic-embed-text-v1.5`.
///
/// The model is loaded lazily on first use (network download on first
/// run, cached at `~/Documents/huggingface/models/nomic-ai/...`
/// thereafter). All embeddings are 768-dim Float32, mean-pooled and
/// L2-normalized.
///
/// Nomic is trained with mandatory prefixes:
///   - `"search_document: "` for indexed text
///   - `"search_query: "`    for queries
/// Both methods add the prefix internally so callers must pick the
/// right method, not the right string.
public actor EmbeddingService {

    /// Dimensionality of every vector returned by this service.
    public static let dimension = 768

    /// Maximum input length in characters before truncation.
    /// Nomic's tokenizer max is 8192 tokens (~32 KB chars in English).
    /// A generous char cap keeps the encoder from blowing up on
    /// unbounded text.
    public static let maxInputCharacters = 30_000

    private var bundle: NomicBert.ModelBundle?

    public init() {}

    /// Embed a document chunk for indexing.
    public func embedDocument(_ text: String) async throws -> [Float] {
        try await embed(prefix: "search_document: ", text: text)
    }

    /// Embed a query at search time.
    public func embedQuery(_ text: String) async throws -> [Float] {
        try await embed(prefix: "search_query: ", text: text)
    }

    private func embed(prefix: String, text: String) async throws -> [Float] {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.count > Self.maxInputCharacters {
            trimmed = String(trimmed.prefix(Self.maxInputCharacters))
        }

        let bundle = try await loadBundleIfNeeded()
        let input = prefix + trimmed
        let tensor = try bundle.encode(input, postProcess: .meanPoolAndNormalize)
        let scalars = await tensor.cast(to: Float.self).shapedArray(of: Float.self).scalars
        return scalars
    }

    private func loadBundleIfNeeded() async throws -> NomicBert.ModelBundle {
        if let bundle { return bundle }
        let loaded = try await NomicBert.loadModelBundle(
            from: "nomic-ai/nomic-embed-text-v1.5"
        )
        self.bundle = loaded
        return loaded
    }
}
