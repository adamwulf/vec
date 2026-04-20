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

    private func l2Normalize(_ vector: [Float]) -> [Float] {
        var sumSquares: Float = 0
        for v in vector { sumSquares += v * v }
        let norm = sqrt(sumSquares)
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }
}
