import Foundation
import Embeddings

/// `Embedder` wrapping `swift-embeddings`' NomicBert (`nomic-embed-text-v1.5`). See `pluggable-embedders.md`.
public actor NomicEmbedder: Embedder {

    public nonisolated let name = "nomic-v1.5-768"
    public nonisolated let dimension = 768

    /// Character cap before truncation; nomic's 8192-token tokenizer allows ~32 KB in English.
    public static let maxInputCharacters = 30_000

    private var bundle: NomicBert.ModelBundle?

    public init() {}

    public func embedDocument(_ text: String) async throws -> [Float] {
        try await embed(prefix: "search_document: ", text: text)
    }

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
