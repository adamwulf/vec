import Foundation

/// Text-embedding backend. See `pluggable-embedders.md` for the design.
public protocol Embedder: Sendable {
    nonisolated var name: String { get }
    nonisolated var dimension: Int { get }
    func embedDocument(_ text: String) async throws -> [Float]
    func embedQuery(_ text: String) async throws -> [Float]
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
