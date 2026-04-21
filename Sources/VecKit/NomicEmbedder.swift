import Foundation
import Embeddings

/// `Embedder` wrapping `swift-embeddings`' NomicBert (`nomic-embed-text-v1.5`). See `archived/pluggable-embedders.md`.
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

    public func embedDocuments(_ texts: [String]) async throws -> [[Float]] {
        // Normalize inputs the same way `embed(prefix:text:)` does, then
        // exclude empty slots from the model call and re-interleave `[]`
        // back at their original indices.
        var normalized: [String?] = []
        normalized.reserveCapacity(texts.count)
        for t in texts {
            var trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                normalized.append(nil)
                continue
            }
            if trimmed.count > Self.maxInputCharacters {
                trimmed = String(trimmed.prefix(Self.maxInputCharacters))
            }
            normalized.append("search_document: " + trimmed)
        }

        let liveInputs = normalized.compactMap { $0 }
        guard !liveInputs.isEmpty else {
            return Array(repeating: [], count: texts.count)
        }

        let bundle = try await loadBundleIfNeeded()
        // computePolicy must be .cpuOnly. The batched path feeds an
        // attention mask into the graph and, on macOS 26.3.1+, CoreML
        // tries to compile that graph for ANE and fails with
        // "Incompatible element type for ANE: expected fp16, si8, or ui8".
        // Neither the default nor an explicit .cpuAndGPU prevents this
        // (both were observed to fail — zero chunks indexed, and
        // segfaulting at the tokenizer's default maxLength of 2048).
        // The single-text encode() path is unaffected because it runs
        // with uniform sequence length and no attention mask, so we
        // only override the policy on the batched call.
        let tensor = try bundle.batchEncode(
            liveInputs,
            padTokenId: 0,
            postProcess: .meanPoolAndNormalize,
            computePolicy: .cpuOnly)
        let scalars = await tensor.cast(to: Float.self).shapedArray(of: Float.self).scalars

        let batch = liveInputs.count
        let dim = dimension
        precondition(scalars.count == batch * dim,
                     "Nomic batchEncode returned \(scalars.count) scalars, expected \(batch * dim)")

        var rows: [[Float]] = []
        rows.reserveCapacity(batch)
        for i in 0..<batch {
            rows.append(Array(scalars[(i * dim)..<((i + 1) * dim)]))
        }

        var out: [[Float]] = []
        out.reserveCapacity(texts.count)
        var liveIdx = 0
        for slot in normalized {
            if slot == nil {
                out.append([])
            } else {
                out.append(rows[liveIdx])
                liveIdx += 1
            }
        }
        return out
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
