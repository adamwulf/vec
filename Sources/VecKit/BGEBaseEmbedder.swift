import Foundation
import Embeddings

/// `Embedder` wrapping `swift-embeddings`' Bert loader against
/// `BAAI/bge-base-en-v1.5`. BGE v1.5 is trained to work without a
/// query/document prefix. `Bert.ModelBundle.encode` returns the
/// CLS-token output but does NOT L2-normalize — we normalize here
/// so cosine-similarity search against the stored vectors is correct.
public actor BGEBaseEmbedder: Embedder {

    public nonisolated let name = "bge-base-en-v1.5"
    public nonisolated let dimension = 768

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
        // Normalize inputs the same way `embed(_:)` does. Preserve index
        // alignment: empty/whitespace-only inputs get `[]` at their slot
        // and are excluded from the batch sent to the model.
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
            normalized.append(trimmed)
        }

        let liveInputs = normalized.compactMap { $0 }
        guard !liveInputs.isEmpty else {
            return Array(repeating: [], count: texts.count)
        }

        let bundle = try await loadBundleIfNeeded()
        let tensor = try bundle.batchEncode(liveInputs, padTokenId: 0, maxLength: 512)
        let scalars = await tensor.cast(to: Float.self).shapedArray(of: Float.self).scalars

        let batch = liveInputs.count
        let dim = dimension
        precondition(scalars.count == batch * dim,
                     "BGE batchEncode returned \(scalars.count) scalars, expected \(batch * dim)")

        var rows: [[Float]] = []
        rows.reserveCapacity(batch)
        for i in 0..<batch {
            let row = Array(scalars[(i * dim)..<((i + 1) * dim)])
            rows.append(l2Normalize(row))
        }

        // Re-interleave `[]` placeholders for the empty inputs so output
        // indices match input indices exactly.
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
            from: "BAAI/bge-base-en-v1.5"
        )
        self.bundle = loaded
        return loaded
    }
}
