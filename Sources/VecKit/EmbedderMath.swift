import Foundation
import CoreML

/// Runs `body` either directly (when `policy` is nil) or inside
/// `withMLTensorComputePolicy(policy)` so the enclosed MLTensor /
/// CoreML graph honors the requested CPU/ANE/GPU placement. Used by
/// every Bert-family embedder in the registry (BGE*, GTE, E5-base,
/// mxbai-large) so the E6 `--compute-policy` CLI flag reaches the
/// MLTensor scope that actually dispatches the work.
///
/// Thrown errors and return values pass through unchanged.
///
/// Note: NLEmbedder / NLContextualEmbedder use Apple NaturalLanguage
/// APIs that don't go through MLTensor / MLComputePolicy; they
/// accept and ignore the policy.
@inline(__always)
func withOptionalComputePolicy<T>(_ policy: MLComputePolicy?, _ body: () throws -> T) rethrows -> T {
    if let policy {
        return try withMLTensorComputePolicy(policy, body)
    }
    return try body()
}

/// L2-normalize a vector in place and return the result. `Bert.ModelBundle.encode`
/// returns CLS-token output without normalization, so BERT-based embedders
/// (BGE, Arctic) must normalize themselves before returning a vector for
/// cosine-similarity search.
///
/// Returns the input unchanged if its norm is zero (e.g. the caller fed an
/// empty string through a lower layer that still produced an all-zero vector).
func l2Normalize(_ vector: [Float]) -> [Float] {
    var sumSquares: Float = 0
    for v in vector { sumSquares += v * v }
    let norm = sqrt(sumSquares)
    guard norm > 0 else { return vector }
    return vector.map { $0 / norm }
}

/// Bert-family batch input normalization. Trims whitespace, caps length
/// at `maxChars`, optionally prepends a per-call prefix, and marks empty
/// slots as `nil` so the caller can skip them in the model call and
/// re-interleave `[]` placeholders after decode.
///
/// The paired `unpackAndReinterleave` consumes the `slots` returned here.
struct BertBatchInputs {
    /// One slot per input text, in input order. `nil` means the input
    /// was empty/whitespace-only and should get `[]` at decode time.
    let slots: [String?]
    /// The non-nil slots in order — exactly what gets fed to `batchEncode`.
    let liveInputs: [String]
}

func normalizeBertInputs(_ texts: [String], prefix: String = "", maxChars: Int) -> BertBatchInputs {
    var slots: [String?] = []
    slots.reserveCapacity(texts.count)
    for t in texts {
        var trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            slots.append(nil)
            continue
        }
        if trimmed.count > maxChars {
            trimmed = String(trimmed.prefix(maxChars))
        }
        slots.append(prefix.isEmpty ? trimmed : prefix + trimmed)
    }
    return BertBatchInputs(slots: slots, liveInputs: slots.compactMap { $0 })
}

/// Unpack a flat scalar tensor into per-row `[Float]` vectors, apply
/// `normalizer` to each row (pass `{ $0 }` for a no-op when the model
/// already normalized via `postProcess`), then re-interleave `[]` at
/// each `nil` slot so the output indices match the original input
/// indices. `embedderName` is only used in the shape precondition's
/// failure message.
func unpackAndReinterleave(
    scalars: [Float],
    slots: [String?],
    dim: Int,
    embedderName: String,
    normalizer: ([Float]) -> [Float]
) -> [[Float]] {
    let batch = slots.reduce(0) { $0 + ($1 == nil ? 0 : 1) }
    precondition(scalars.count == batch * dim,
                 "\(embedderName) batchEncode returned \(scalars.count) scalars, expected \(batch * dim)")

    var rows: [[Float]] = []
    rows.reserveCapacity(batch)
    for i in 0..<batch {
        let row = Array(scalars[(i * dim)..<((i + 1) * dim)])
        rows.append(normalizer(row))
    }

    var out: [[Float]] = []
    out.reserveCapacity(slots.count)
    var liveIdx = 0
    for slot in slots {
        if slot == nil {
            out.append([])
        } else {
            out.append(rows[liveIdx])
            liveIdx += 1
        }
    }
    return out
}
