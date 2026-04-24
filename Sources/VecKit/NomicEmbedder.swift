import Foundation
import CoreML
import Embeddings

/// `Embedder` wrapping `swift-embeddings`' NomicBert (`nomic-embed-text-v1.5`). See `archived/pluggable-embedders.md`.
public actor NomicEmbedder: Embedder {

    public nonisolated let name = "nomic-v1.5-768"
    public nonisolated let dimension = 768

    /// Character cap before truncation; nomic's 8192-token tokenizer allows ~32 KB in English.
    public static let maxInputCharacters = 30_000

    private var bundle: NomicBert.ModelBundle?
    /// Optional override of the batched-path compute policy. When nil,
    /// defaults to `.cpuOnly` — see `embedDocuments` for the ANE-
    /// incompatibility workaround this preserves.
    private let computePolicyOverride: MLComputePolicy?

    public init(computePolicy: MLComputePolicy? = nil) {
        self.computePolicyOverride = computePolicy
    }

    public func embedDocument(_ text: String) async throws -> [Float] {
        try await embed(prefix: "search_document: ", text: text)
    }

    public func embedQuery(_ text: String) async throws -> [Float] {
        try await embed(prefix: "search_query: ", text: text)
    }

    public func embedDocuments(_ texts: [String]) async throws -> [[Float]] {
        // Nomic requires the "search_document: " prefix on indexed text.
        // `postProcess: .meanPoolAndNormalize` below handles L2-normalization
        // inside the model graph, so the per-row normalizer is a no-op.
        let inputs = normalizeBertInputs(texts, prefix: "search_document: ", maxChars: Self.maxInputCharacters)
        guard !inputs.liveInputs.isEmpty else {
            return Array(repeating: [], count: texts.count)
        }

        let bundle = try await loadBundleIfNeeded()
        // computePolicy must default to .cpuOnly. The batched path feeds
        // an attention mask into the graph and, on macOS 26.3.1+, CoreML
        // tries to compile that graph for ANE and fails with
        // "Incompatible element type for ANE: expected fp16, si8, or ui8".
        // Neither the default nor an explicit .cpuAndGPU prevents this
        // (both were observed to fail — zero chunks indexed, and
        // segfaulting at the tokenizer's default maxLength of 2048).
        // The single-text encode() path is unaffected because it runs
        // with uniform sequence length and no attention mask, so we
        // only override the policy on the batched call.
        // If the caller supplied an explicit compute policy via the E6
        // `--compute-policy` flag, honor it — this is the intended
        // escape hatch for probing whether newer macOS versions have
        // fixed the ANE-fp16 issue. If no override was passed, keep
        // the .cpuOnly pin.
        let tensor = try bundle.batchEncode(
            inputs.liveInputs,
            padTokenId: 0,
            postProcess: .meanPoolAndNormalize,
            computePolicy: computePolicyOverride ?? .cpuOnly)
        let scalars = await tensor.cast(to: Float.self).shapedArray(of: Float.self).scalars

        return unpackAndReinterleave(
            scalars: scalars,
            slots: inputs.slots,
            dim: dimension,
            embedderName: "Nomic",
            normalizer: { $0 })
    }

    private func embed(prefix: String, text: String) async throws -> [Float] {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.count > Self.maxInputCharacters {
            trimmed = String(trimmed.prefix(Self.maxInputCharacters))
        }

        let bundle = try await loadBundleIfNeeded()
        let input = prefix + trimmed
        // Single-text path has no attention mask, so the default
        // (.cpuAndGPU) works; honor the CLI override when present.
        let tensor: MLTensor
        if let policy = computePolicyOverride {
            tensor = try bundle.encode(input, postProcess: .meanPoolAndNormalize, computePolicy: policy)
        } else {
            tensor = try bundle.encode(input, postProcess: .meanPoolAndNormalize)
        }
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
