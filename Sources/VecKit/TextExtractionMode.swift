import Foundation

/// Versioned document preprocessing. Raw extraction remains the default.
/// A changed normalization algorithm must receive a new version so an
/// incremental update cannot mix incompatible document representations.
///
/// Each mode names the exact normalizer(s) applied before chunking, so a
/// mode string is a complete, reproducible description of how a database's
/// text was preprocessed:
/// - `raw` — no normalization; every file is embedded as read.
/// - `markdown-v1` — the v1 Markdown normalizer runs on `.md` / `.markdown`
///   files; all other file types pass through unchanged.
/// - `vtt-v1` — the v1 WebVTT normalizer runs on `.vtt` files; all other
///   file types (Markdown included) pass through unchanged.
/// - `markdown-v1+vtt-v1` — the combined mode: the v1 Markdown normalizer
///   runs on `.md` / `.markdown` files and the v1 WebVTT normalizer runs on
///   `.vtt` files. Both are the same versioned algorithms as the
///   single-format modes, so the combination is fully described by its two
///   component versions.
public enum TextExtractionMode: String, Codable, CaseIterable, Sendable {
    case raw
    case markdownV1 = "markdown-v1"
    case vttV1 = "vtt-v1"
    case markdownV1VttV1 = "markdown-v1+vtt-v1"
}

public enum TextExtractionError: Error, LocalizedError {
    case mismatch(recorded: TextExtractionMode, requested: TextExtractionMode)

    public var errorDescription: String? {
        switch self {
        case .mismatch(let recorded, let requested):
            return "Database uses text extraction '\(recorded.rawValue)', but '\(requested.rawValue)' was requested. Run 'vec reset --db <name>' and re-index to change extraction, or omit --text-extraction to reuse the recorded mode."
        }
    }
}
