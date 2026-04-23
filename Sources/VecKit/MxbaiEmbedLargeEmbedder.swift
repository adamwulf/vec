import Foundation
import Embeddings

/// `Embedder` wrapping `swift-embeddings`' Bert loader against
/// `mixedbread-ai/mxbai-embed-large-v1`. 1024-dim BERT-large peer of
/// `BGELargeEmbedder`: same Bert-family loader, same CLS-token output,
/// same explicit L2 normalization for cosine search. The shape
/// difference vs the BGE family is the **query-only prefix**:
///
///   "Represent this sentence for searching relevant passages: "
///
/// must be prepended to queries (per the model card —
/// <https://huggingface.co/mixedbread-ai/mxbai-embed-large-v1>); documents
/// take no prefix. Asymmetric prefix is unique among the registry's
/// Bert-family embedders: bge-base/bge-large/bge-small/gte-base apply
/// no prefix on either side, e5-base prefixes BOTH sides
/// (`"passage: "` / `"query: "`). The prefix is injected inside this
/// actor so callers remain prefix-unaware (same `Embedder` protocol
/// surface as every other embedder).
public actor MxbaiEmbedLargeEmbedder: Embedder {

    public nonisolated let name = "mxbai-embed-large-v1"
    public nonisolated let dimension = 1024

    /// Character cap before truncation. mxbai is BERT-large with a
    /// 512-token max sequence; ~2000 English characters is a safe
    /// cap before the tokenizer truncates internally. Same rationale
    /// as the BGE / E5 caps. The query prefix's tokens eat into the
    /// 2000-char budget on the query path — the cap is applied AFTER
    /// the prefix is prepended so the prefix is never truncated off.
    public static let maxInputCharacters = 2_000

    /// The retrieval query prompt mandated by the model card. Quoted
    /// verbatim, including the trailing space. Identical wording to
    /// the BGE-family convention for query prefixing (BGE v1.5 chose
    /// to drop the prefix; mxbai reinstated it).
    private static let queryPrefix = "Represent this sentence for searching relevant passages: "

    private var bundle: Bert.ModelBundle?

    public init() {}

    public func embedDocument(_ text: String) async throws -> [Float] {
        try await embedSingle(prefix: "", text: text)
    }

    public func embedQuery(_ text: String) async throws -> [Float] {
        try await embedSingle(prefix: Self.queryPrefix, text: text)
    }

    public func embedDocuments(_ texts: [String]) async throws -> [[Float]] {
        // Documents take no prefix on the mxbai retrieval path. Same
        // pathway as BGELargeEmbedder; only the loader repo differs.
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
            embedderName: "Mxbai-large",
            normalizer: l2Normalize)
    }

    private func embedSingle(prefix: String, text: String) async throws -> [Float] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var prefixed = prefix.isEmpty ? trimmed : prefix + trimmed
        if prefixed.count > Self.maxInputCharacters {
            prefixed = String(prefixed.prefix(Self.maxInputCharacters))
        }

        let bundle = try await loadBundleIfNeeded()
        let tensor = try bundle.encode(prefixed, maxLength: 512)
        let scalars = await tensor.cast(to: Float.self).shapedArray(of: Float.self).scalars
        return l2Normalize(scalars)
    }

    private func loadBundleIfNeeded() async throws -> Bert.ModelBundle {
        if let bundle { return bundle }
        let loaded = try await Bert.loadModelBundle(
            from: "mixedbread-ai/mxbai-embed-large-v1"
        )
        self.bundle = loaded
        return loaded
    }
}
