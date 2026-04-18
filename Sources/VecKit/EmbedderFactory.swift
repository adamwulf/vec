import Foundation

/// Maps CLI aliases to `Embedder` instances. See `pluggable-embedders.md`.
public enum EmbedderFactory {

    private struct Entry {
        let alias: String
        let canonicalName: String
    }

    private static let embedders: [Entry] = [
        Entry(alias: "nomic", canonicalName: "nomic-v1.5-768"),
        Entry(alias: "nl", canonicalName: "nl-en-512"),
    ]

    public static let defaultAlias = "nomic"

    public static var knownAliases: [String] { embedders.map(\.alias) }

    public static func make(alias: String) throws -> any Embedder {
        switch alias {
        case "nomic":
            return NomicEmbedder()
        case "nl":
            return NLEmbedder()
        default:
            throw VecError.unknownEmbedder(alias)
        }
    }

    public static func canonicalName(forAlias alias: String) throws -> String {
        guard let entry = embedders.first(where: { $0.alias == alias }) else {
            throw VecError.unknownEmbedder(alias)
        }
        return entry.canonicalName
    }

    public static func alias(forCanonicalName canonical: String) -> String? {
        embedders.first(where: { $0.canonicalName == canonical })?.alias
    }
}
