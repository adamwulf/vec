import Foundation

/// Text-embedding backend. See `archived/pluggable-embedders.md` for the design.
public protocol Embedder: Sendable {
    nonisolated var name: String { get }
    nonisolated var dimension: Int { get }
    func embedDocument(_ text: String) async throws -> [Float]
    func embedQuery(_ text: String) async throws -> [Float]
    /// Batched document embedding. Output `[i]` corresponds to input `[i]`.
    /// Whole-batch failure throws; per-item failure may be signalled by
    /// returning `[]` at that index (the pipeline treats `isEmpty` as failed).
    func embedDocuments(_ texts: [String]) async throws -> [[Float]]
}

public extension Embedder {
    func embedDocuments(_ texts: [String]) async throws -> [[Float]] {
        var out: [[Float]] = []
        out.reserveCapacity(texts.count)
        for t in texts {
            out.append(try await embedDocument(t))
        }
        return out
    }
}

/// Errors raised by an `Embedder` implementation.
public enum EmbedderError: Error, LocalizedError {
    case modelUnavailable(embedder: String, detail: String)
    case embedFailed(embedder: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .modelUnavailable(let embedder, let detail):
            return "Embedder '\(embedder)' model unavailable: \(detail)"
        case .embedFailed(let embedder, let detail):
            return "Embedder '\(embedder)' failed to embed input: \(detail)"
        }
    }
}
