import Foundation

/// Maps short CLI aliases ("nomic", "nl") to concrete `Embedder`
/// implementations. The factory owns the single source of truth for
/// known embedder names; adding a new implementation (e.g. "llama")
/// only requires extending the alias table here.
///
/// Two name concepts:
/// - **alias** — the string the user types on the CLI: `nomic`, `nl`.
///   Short, stable, memorable.
/// - **canonical name** — what the embedder instance reports via
///   `Embedder.name` (e.g. "nomic-v1.5-768"). Stored in
///   `DatabaseConfig.embedder.name` so mismatch errors can show both
///   the exact recorded model+dim and the alias the user should
///   type to reuse it.
public enum EmbedderFactory {

    /// Default CLI alias used when `--embedder` is omitted and the
    /// DB has no recorded embedder.
    public static let defaultAlias = "nomic"

    /// All accepted `--embedder` aliases, in menu order.
    public static let knownAliases: [String] = ["nomic", "nl"]

    /// Produce a concrete embedder for the given CLI alias.
    ///
    /// Throws `VecError.unknownEmbedder` for unknown aliases so the
    /// CLI surfaces a consistent error regardless of where the alias
    /// was read from (flag, config, or fallback).
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

    /// Resolve a CLI alias to the canonical embedder name without
    /// paying the cost of loading the model. Useful for writing the
    /// alias+canonical pair into config *before* kicking off a run.
    public static func canonicalName(forAlias alias: String) throws -> String {
        let e = try make(alias: alias)
        return e.name
    }

    /// Resolve a canonical name recorded in `DatabaseConfig` back to a
    /// CLI alias. Used when producing mismatch error messages — "run
    /// `--embedder <alias>`" is more actionable than "run `--embedder
    /// nomic-v1.5-768`".
    public static func alias(forCanonicalName canonical: String) -> String? {
        for alias in knownAliases {
            if (try? canonicalName(forAlias: alias)) == canonical {
                return alias
            }
        }
        return nil
    }
}
