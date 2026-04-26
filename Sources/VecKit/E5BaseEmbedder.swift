import Foundation
import CoreML
import Embeddings

/// `Embedder` wrapping `swift-embeddings`' Bert loader against
/// `intfloat/e5-base-v2`. Two shape differences vs BGE / GTE:
///
/// 1. **Prefixes are required.** Documents are prefixed with
///    `"passage: "` and queries with `"query: "`. The model was
///    pretrained with these literal strings and underperforms
///    substantially without them (the published MTEB numbers assume
///    them). Callers do NOT need to apply the prefix — this actor
///    injects it internally so `embedDocument` / `embedQuery` /
///    `embedDocuments` all look identical to callers as for the
///    prefix-free BGE and GTE embedders.
/// 2. **Mean pooling, not CLS.** `Bert.ModelBundle.encode` /
///    `batchEncode` slice out the CLS token. e5 is trained with
///    mean pooling over the final hidden states, masking padding
///    via the attention mask. We bypass `ModelBundle.encode` and
///    drive `bundle.model(...)` directly so we can feed the
///    attention mask to both the encoder (for padding-aware
///    attention) and the pool (to exclude pad positions from the
///    mean). L2-normalization is applied per row after pooling.
public actor E5BaseEmbedder: Embedder {

    public nonisolated let name = "e5-base-v2"
    public nonisolated let dimension = 768

    /// Character cap before truncation. e5's max sequence is 512
    /// tokens (BERT tokenizer); ~2000 English characters is a safe
    /// cap before the tokenizer truncates internally. The cap is
    /// applied AFTER the prefix is prepended, so the prefix is
    /// never truncated off — the prefix's tokens eat into the
    /// content budget, which is intentional.
    public static let maxInputCharacters = 2_000

    private static let documentPrefix = "passage: "
    private static let queryPrefix = "query: "

    private var bundle: Bert.ModelBundle?
    private let computePolicy: MLComputePolicy?

    public init(computePolicy: MLComputePolicy? = nil) {
        self.computePolicy = computePolicy
    }

    public func embedDocument(_ text: String) async throws -> [Float] {
        try await embedSingle(prefix: Self.documentPrefix, text: text)
    }

    public func embedQuery(_ text: String) async throws -> [Float] {
        try await embedSingle(prefix: Self.queryPrefix, text: text)
    }

    public func embedDocuments(_ texts: [String]) async throws -> [[Float]] {
        // Every input in embedDocuments is by definition a document; prepend
        // the passage prefix to each. `normalizeBertInputs` applies the char
        // cap AFTER the prefix is prepended.
        let inputs = normalizeBertInputs(texts, prefix: Self.documentPrefix, maxChars: Self.maxInputCharacters)
        guard !inputs.liveInputs.isEmpty else {
            return Array(repeating: [], count: texts.count)
        }

        let bundle = try await loadBundleIfNeeded()
        let pooled = try await meanPooledBatch(bundle: bundle, texts: inputs.liveInputs)

        return unpackAndReinterleave(
            scalars: pooled,
            slots: inputs.slots,
            dim: dimension,
            embedderName: "E5",
            normalizer: l2Normalize)
    }

    private func embedSingle(prefix: String, text: String) async throws -> [Float] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var prefixed = prefix + trimmed
        if prefixed.count > Self.maxInputCharacters {
            prefixed = String(prefixed.prefix(Self.maxInputCharacters))
        }

        let bundle = try await loadBundleIfNeeded()
        let pooled = try await meanPooledBatch(bundle: bundle, texts: [prefixed])
        // meanPooledBatch returns `batch * dimension` scalars; for batch=1
        // that's exactly `dimension` scalars. L2-normalize the single row.
        precondition(pooled.count == dimension,
                     "E5 single-text mean pool returned \(pooled.count) scalars, expected \(dimension)")
        return l2Normalize(pooled)
    }

    /// Core inference path. Tokenizes `texts` with padding, runs the
    /// underlying Bert model (not `ModelBundle.encode/batchEncode`
    /// — those slice CLS), and returns the masked mean pool over the
    /// sequence output as a flat `[batch * dimension]` scalar array.
    /// The caller is responsible for L2-normalizing each row.
    private func meanPooledBatch(bundle: Bert.ModelBundle, texts: [String]) async throws -> [Float] {
        // Pads every sequence in the batch to the longest. `tokens` is
        // [Int32] of length batch*seqLen; `attentionMask` is [Float] of
        // the same shape; `shape` is [batch, seqLen].
        let batchTokenize = try bundle.tokenizer.tokenizeTextsPaddingToLongest(
            texts, padTokenId: 0, maxLength: 512)

        // Graph construction and the `bundle.model(...)` call happen
        // inside `withMLTensorComputePolicy` so the E6 `--compute-policy`
        // flag (`auto` / `cpu` / `ane` / `gpu`) reaches the MLTensor
        // scope that compiles the CoreML graph for this run.
        // Materialization (`await pooled.cast(...).shapedArray(...)`)
        // runs outside the scope — MLTensor captures the policy at graph
        // construction time, same pattern `swift-embeddings`' NomicBert
        // uses internally (NomicBertModel.swift: batchEncode wraps its
        // body in `withMLTensorComputePolicy` and returns the tensor to
        // the caller to materialize).
        let pooled = withOptionalComputePolicy(computePolicy) { () -> MLTensor in
            let inputIds = MLTensor(
                shape: batchTokenize.shape,
                scalars: batchTokenize.tokens)
            let attentionMask = MLTensor(
                shape: batchTokenize.shape,
                scalars: batchTokenize.attentionMask)

            // Drive the model directly so the attention mask flows into the
            // encoder (for padding-aware attention) AND can be reused below
            // for masked mean pooling. `sequenceOutput` is shape
            // [batch, seqLen, hiddenSize].
            let (sequenceOutput, _) = bundle.model(
                inputIds: inputIds,
                attentionMask: attentionMask)

            // Masked mean pool. Broadcast the [batch, seqLen] mask across the
            // hidden dim by expanding to [batch, seqLen, 1], multiply to zero
            // out pad positions, sum over seqLen, then divide by the per-row
            // non-pad token count. `keepRank: true` on the denominator gives
            // a [batch, 1] tensor that broadcasts cleanly against the
            // [batch, hiddenSize] numerator. This mirrors the recipe used
            // internally by `swift-embeddings` for NomicBert's `.meanPool`
            // postProcess (see EmbeddingsUtils.swift `maskedMeanPool`).
            let expandedMask = attentionMask.expandingShape(at: 2)
            let masked = sequenceOutput * expandedMask
            let summed = masked.sum(alongAxes: 1, keepRank: false)
            let tokenCounts = attentionMask.sum(alongAxes: 1, keepRank: true)
            return summed / tokenCounts
        }

        return await pooled.cast(to: Float.self).shapedArray(of: Float.self).scalars
    }

    private func loadBundleIfNeeded() async throws -> Bert.ModelBundle {
        if let bundle { return bundle }
        let loaded = try await Bert.loadModelBundle(
            from: "intfloat/e5-base-v2"
        )
        self.bundle = loaded
        return loaded
    }
}
