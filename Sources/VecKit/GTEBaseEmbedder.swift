import Foundation
import CoreML
import Embeddings

/// `Embedder` wrapping `swift-embeddings`' Bert loader against
/// `thenlper/gte-base`. GTE-base-en-v1.5 is trained to work without a
/// query/document prefix (same convention as BGE). `Bert.ModelBundle.encode`
/// returns the CLS-token output but does NOT L2-normalize — we normalize
/// here so cosine-similarity search against the stored vectors is correct.
public actor GTEBaseEmbedder: Embedder {

    public nonisolated let name = "gte-base-en-v1.5"
    public nonisolated let dimension = 768

    /// Character cap before truncation. GTE's max sequence is 512
    /// tokens (BERT tokenizer); ~2000 English characters is a safe
    /// cap before the tokenizer truncates internally.
    public static let maxInputCharacters = 2_000

    private var bundle: Bert.ModelBundle?
    private let computePolicy: MLComputePolicy?

    public init(computePolicy: MLComputePolicy? = nil) {
        self.computePolicy = computePolicy
    }

    public func embedDocument(_ text: String) async throws -> [Float] {
        try await embed(text)
    }

    public func embedQuery(_ text: String) async throws -> [Float] {
        try await embed(text)
    }

    public func embedDocuments(_ texts: [String]) async throws -> [[Float]] {
        // GTE-base is trained to work without a query/document prefix, so
        // no prefix here. `batchEncode` returns CLS-token output without
        // normalization; `l2Normalize` per row is required for cosine search.
        let inputs = normalizeBertInputs(texts, maxChars: Self.maxInputCharacters)
        guard !inputs.liveInputs.isEmpty else {
            return Array(repeating: [], count: texts.count)
        }

        let bundle = try await loadBundleIfNeeded()
        let tensor = try withOptionalComputePolicy(computePolicy) {
            try bundle.batchEncode(inputs.liveInputs, padTokenId: 0, maxLength: 512)
        }
        let scalars = await tensor.cast(to: Float.self).shapedArray(of: Float.self).scalars

        return unpackAndReinterleave(
            scalars: scalars,
            slots: inputs.slots,
            dim: dimension,
            embedderName: "GTE",
            normalizer: l2Normalize)
    }

    private func embed(_ text: String) async throws -> [Float] {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.count > Self.maxInputCharacters {
            trimmed = String(trimmed.prefix(Self.maxInputCharacters))
        }

        let bundle = try await loadBundleIfNeeded()
        let tensor = try withOptionalComputePolicy(computePolicy) {
            try bundle.encode(trimmed, maxLength: 512)
        }
        let scalars = await tensor.cast(to: Float.self).shapedArray(of: Float.self).scalars
        return l2Normalize(scalars)
    }

    private func loadBundleIfNeeded() async throws -> Bert.ModelBundle {
        if let bundle { return bundle }
        let loaded = try await Bert.loadModelBundle(
            from: "thenlper/gte-base"
        )
        self.bundle = loaded
        return loaded
    }
}
