import Foundation

/// Versioned document preprocessing. Raw extraction remains the default.
/// A changed normalization algorithm must receive a new version so an
/// incremental update cannot mix incompatible document representations.
public enum TextExtractionMode: String, Codable, CaseIterable, Sendable {
    case raw
    case markdownV1 = "markdown-v1"
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
