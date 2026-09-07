import Foundation

/// Versioned, opt-in preprocessing recorded with the indexing profile.
/// Canonical combinations list Markdown, VTT, image OCR, then PDF OCR. Changing any
/// component requires reset/reindexing so representations cannot be mixed.
/// Raw extracts text and PDF content; raster images require image-ocr-v1.
public enum TextExtractionMode: String, Codable, CaseIterable, Sendable {
    case raw
    case markdownV1 = "markdown-v1"
    case vttV1 = "vtt-v1"
    case markdownV1VttV1 = "markdown-v1+vtt-v1"
    case imageOCRV1 = "image-ocr-v1"
    case markdownV1ImageOCRV1 = "markdown-v1+image-ocr-v1"
    case vttV1ImageOCRV1 = "vtt-v1+image-ocr-v1"
    case markdownV1VttV1ImageOCRV1 = "markdown-v1+vtt-v1+image-ocr-v1"
    case pdfOCRV1 = "pdf-ocr-v1"
    case markdownV1PDFOCRV1 = "markdown-v1+pdf-ocr-v1"
    case vttV1PDFOCRV1 = "vtt-v1+pdf-ocr-v1"
    case markdownV1VttV1PDFOCRV1 = "markdown-v1+vtt-v1+pdf-ocr-v1"
    case imageOCRV1PDFOCRV1 = "image-ocr-v1+pdf-ocr-v1"
    case markdownV1ImageOCRV1PDFOCRV1 = "markdown-v1+image-ocr-v1+pdf-ocr-v1"
    case vttV1ImageOCRV1PDFOCRV1 = "vtt-v1+image-ocr-v1+pdf-ocr-v1"
    case markdownV1VttV1ImageOCRV1PDFOCRV1 = "markdown-v1+vtt-v1+image-ocr-v1+pdf-ocr-v1"

    public var includesMarkdown: Bool {
        rawValue.split(separator: "+").contains("markdown-v1")
    }

    public var includesVTT: Bool {
        rawValue.split(separator: "+").contains("vtt-v1")
    }

    public var includesImageOCR: Bool {
        rawValue.split(separator: "+").contains("image-ocr-v1")
    }

    public var includesPDFOCR: Bool {
        rawValue.split(separator: "+").contains("pdf-ocr-v1")
    }
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
