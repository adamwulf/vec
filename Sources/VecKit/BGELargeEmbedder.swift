import Foundation
import Embeddings

/// `Embedder` wrapping `swift-embeddings`' Bert loader against
/// `BAAI/bge-large-en-v1.5`. Same v1.5 family as `BGEBaseEmbedder` —
/// no query/document prefix, CLS-token output, L2-normalized here so
/// cosine-similarity search against the stored vectors is correct.
/// Distinguished from `bge-base` by a larger 1024-dim embedding space
/// and a deeper transformer stack (24 layers vs 12), trading wallclock
/// for rubric quality.
public actor BGELargeEmbedder: Embedder {

    public nonisolated let name = "bge-large-en-v1.5"
    public nonisolated let dimension = 1024

    /// Character cap before truncation. BGE's max sequence is 512
    /// tokens; ~2000 English characters is a safe cap before the
    /// tokenizer truncates internally.
    public static let maxInputCharacters = 2_000

    private var bundle: Bert.ModelBundle?

    public init() {}

    public func embedDocument(_ text: String) async throws -> [Float] {
        try await embed(text)
    }

    public func embedQuery(_ text: String) async throws -> [Float] {
        try await embed(text)
    }

    public func embedDocuments(_ texts: [String]) async throws -> [[Float]] {
        // BGE v1.5 is trained to work without a query/document prefix, so
        // no prefix here. `batchEncode` returns CLS-token output without
        // normalization; `l2Normalize` per row is required for cosine search.
        let inputs = normalizeBertInputs(texts, maxChars: Self.maxInputCharacters)
        guard !inputs.liveInputs.isEmpty else {
            return Array(repeating: [], count: texts.count)
        }

        let bundle = try await loadBundleIfNeeded()
        let tensor = try bundle.batchEncode(inputs.liveInputs, padTokenId: 0, maxLength: 512)
        let scalars = await tensor.cast(to: Float.self).shapedArray(of: Float.self).scalars

        return unpackAndReinterleave(
            scalars: scalars,
            slots: inputs.slots,
            dim: dimension,
            embedderName: "BGE-large",
            normalizer: l2Normalize)
    }

    private func embed(_ text: String) async throws -> [Float] {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.count > Self.maxInputCharacters {
            trimmed = String(trimmed.prefix(Self.maxInputCharacters))
        }

        let bundle = try await loadBundleIfNeeded()
        let tensor = try bundle.encode(trimmed, maxLength: 512)
        let scalars = await tensor.cast(to: Float.self).shapedArray(of: Float.self).scalars
        return l2Normalize(scalars)
    }

    private func loadBundleIfNeeded() async throws -> Bert.ModelBundle {
        if let bundle { return bundle }
        let loaded = try await Bert.loadModelBundle(
            from: "BAAI/bge-large-en-v1.5"
        )
        self.bundle = loaded
        return loaded
    }
}
