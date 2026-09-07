import CryptoKit
import Foundation

/// Resource limits and local-file policy for one HTML extraction.
///
/// There is deliberately no implicit production default here. E14 freezes
/// these values against representative saved pages before shared pipeline
/// wiring constructs the options. Requiring every caller to supply them also
/// keeps tests honest about which bound they exercise.
public struct HTMLExtractionOptions: Sendable, Equatable {
    public let maximumInputBytes: Int
    public let maximumElementCount: Int
    /// Nil for `html-v1`: visible image alt text is still rendered, but no
    /// reference is resolved, read, hashed, or decoded. Non-nil only for a
    /// mode that combines `html-v1` with `image-ocr-v1`.
    public let ocrAssets: HTMLOCRAssetOptions?

    public init(
        maximumInputBytes: Int,
        maximumElementCount: Int,
        ocrAssets: HTMLOCRAssetOptions? = nil
    ) throws {
        let integerLimits = [
            ("maximumInputBytes", maximumInputBytes),
            ("maximumElementCount", maximumElementCount),
        ]
        if let invalid = integerLimits.first(where: { $0.1 <= 0 }) {
            throw HTMLExtractionError.invalidLimit(name: invalid.0, value: Int64(invalid.1))
        }

        self.maximumInputBytes = maximumInputBytes
        self.maximumElementCount = maximumElementCount
        self.ocrAssets = ocrAssets
    }
}

/// Policy for the optional inline-image OCR preparation phase.
///
/// This policy is absent for plain HTML extraction. Consequently `html-v1`
/// cannot fail because an image is missing or unreadable and does not pay the
/// cost of asset hashing or data-URI decoding.
public struct HTMLOCRAssetOptions: Sendable, Equatable {
    /// Bump whenever source preference, path eligibility, hashing, or inline
    /// decoding semantics change. Only the current policy is executable;
    /// older values remain meaningful in persisted manifests for invalidation.
    public static let currentPolicyVersion = 1

    public let policyVersion: Int
    public let allowedAssetRoot: URL
    public let temporaryAssetDirectory: URL
    public let maximumImages: Int
    public let maximumLocalImageBytes: Int64
    public let maximumInlineImageBytes: Int
    /// Aggregate retained decoded data across distinct inline images. This is
    /// independent of the per-image bound and prevents `maximumImages`
    /// individually valid data URIs from multiplying resident memory.
    public let maximumTotalInlineImageBytes: Int

    public init(
        policyVersion: Int,
        allowedAssetRoot: URL,
        temporaryAssetDirectory: URL,
        maximumImages: Int,
        maximumLocalImageBytes: Int64,
        maximumInlineImageBytes: Int,
        maximumTotalInlineImageBytes: Int
    ) throws {
        let integerLimits = [
            ("assetPolicyVersion", policyVersion),
            ("maximumImages", maximumImages),
            ("maximumInlineImageBytes", maximumInlineImageBytes),
            ("maximumTotalInlineImageBytes", maximumTotalInlineImageBytes),
        ]
        if let invalid = integerLimits.first(where: { $0.1 <= 0 }) {
            throw HTMLExtractionError.invalidLimit(name: invalid.0, value: Int64(invalid.1))
        }
        guard policyVersion == Self.currentPolicyVersion else {
            throw HTMLExtractionError.unsupportedAssetPolicyVersion(policyVersion)
        }
        guard maximumLocalImageBytes > 0 else {
            throw HTMLExtractionError.invalidLimit(
                name: "maximumLocalImageBytes",
                value: maximumLocalImageBytes
            )
        }
        guard allowedAssetRoot.isFileURL else {
            throw HTMLExtractionError.nonFileAssetDirectory(allowedAssetRoot)
        }
        guard temporaryAssetDirectory.isFileURL else {
            throw HTMLExtractionError.nonFileAssetDirectory(temporaryAssetDirectory)
        }
        self.policyVersion = policyVersion
        self.allowedAssetRoot = allowedAssetRoot.standardizedFileURL
        self.temporaryAssetDirectory = temporaryAssetDirectory.standardizedFileURL
        self.maximumImages = maximumImages
        self.maximumLocalImageBytes = maximumLocalImageBytes
        self.maximumInlineImageBytes = maximumInlineImageBytes
        self.maximumTotalInlineImageBytes = maximumTotalInlineImageBytes
    }
}

/// The output of HTML selection and structural rendering before chunking.
///
/// Text and images remain in DOM order so optional OCR can be inserted beside
/// its surrounding prose instead of appended as an unrelated tail. The shared
/// `TextExtractor` owns OCR composition and chunk construction.
public struct HTMLReadableContent: Sendable, Equatable {
    public let strategyIdentifier: String
    public let extractorVersion: Int
    public let title: String?
    public let segments: [HTMLContentSegment]
    /// Nil when `HTMLExtractionOptions.ocrAssets` is nil. Plain HTML
    /// extraction does no referenced-asset I/O.
    public let assetManifest: HTMLAssetManifest?
    public let diagnostics: [HTMLExtractionDiagnostic]

    public init(
        strategyIdentifier: String,
        extractorVersion: Int,
        title: String?,
        segments: [HTMLContentSegment],
        assetManifest: HTMLAssetManifest? = nil,
        diagnostics: [HTMLExtractionDiagnostic] = []
    ) {
        self.strategyIdentifier = strategyIdentifier
        self.extractorVersion = extractorVersion
        self.title = title
        self.segments = segments
        self.assetManifest = assetManifest
        self.diagnostics = diagnostics
    }

    /// Compose the selected document for chunking. Passing no OCR text is the
    /// `html-v1` behavior: image alt text remains visible without touching the
    /// referenced asset. A combined HTML+OCR mode supplies recognized text by
    /// image ordinal after processing eligible image segments sequentially.
    ///
    /// Only an exact comparison after case-folding and whitespace collapse is
    /// deduplicated. Distinct alt and OCR text are both retained.
    public func renderedText(ocrTextByImageOrdinal: [Int: String] = [:]) -> String {
        var pieces: [String] = []
        pieces.reserveCapacity(segments.count)
        for segment in segments {
            switch segment {
            case .text(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { pieces.append(trimmed) }
            case .image(let image):
                let alt = image.altText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let ocr = ocrTextByImageOrdinal[image.ordinal]?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if alt.isEmpty {
                    if !ocr.isEmpty { pieces.append(ocr) }
                } else if ocr.isEmpty || Self.comparisonKey(alt) == Self.comparisonKey(ocr) {
                    pieces.append(alt)
                } else {
                    pieces.append(alt + "\n" + ocr)
                }
            }
        }
        return pieces.joined(separator: "\n\n")
    }

    private static func comparisonKey(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

public enum HTMLContentSegment: Sendable, Equatable {
    case text(String)
    case image(HTMLImageReference)
}

/// One inline image at its position in the selected DOM.
///
/// `source == nil` means the image is intentionally not OCR-eligible (for
/// example, a remote URL, a missing local file, or an oversized asset). Its
/// alt text can still be retained in the extracted document.
public struct HTMLImageReference: Sendable, Equatable {
    public let ordinal: Int
    public let altText: String?
    public let source: HTMLImageSource?
    public let contentDigest: String?

    public init(
        ordinal: Int,
        altText: String?,
        source: HTMLImageSource?,
        contentDigest: String?
    ) {
        self.ordinal = ordinal
        self.altText = altText
        self.source = source
        self.contentDigest = contentDigest
    }

    /// Invoke `body` with a URL accepted by the existing image recognizer.
    /// Inline bytes are materialized one image at a time in the caller-owned
    /// temporary directory and removed on every success or throw path.
    public func withMaterializedURL<T>(
        in temporaryDirectory: URL,
        _ body: (URL) throws -> T
    ) throws -> T? {
        guard let source else { return nil }
        switch source {
        case .localFile(let url):
            return try body(url)
        case .inlineData(let format, let data):
            let fm = FileManager.default
            try fm.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            let filename = "html-inline-\(UUID().uuidString).\(format.fileExtension)"
            let url = temporaryDirectory.appendingPathComponent(filename, isDirectory: false)
            try data.write(to: url, options: [.atomic])
            defer { try? fm.removeItem(at: url) }
            return try body(url)
        }
    }
}

public enum HTMLImageSource: Sendable, Equatable {
    case localFile(URL)
    case inlineData(format: HTMLInlineRasterFormat, data: Data)
}

/// Raster data-URI formats that may be materialized for the E12 recognizer.
/// SVG is intentionally absent because the OCR engine does not accept it.
public enum HTMLInlineRasterFormat: String, Codable, CaseIterable, Sendable {
    case jpeg
    case png
    case webp
    case gif
    case heic
    case tiff
    case bmp
    case avif

    public var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        default: rawValue
        }
    }

    public init?(mimeType: String) {
        switch mimeType.lowercased() {
        case "image/jpeg", "image/jpg": self = .jpeg
        case "image/png": self = .png
        case "image/webp": self = .webp
        case "image/gif": self = .gif
        case "image/heic": self = .heic
        case "image/tiff", "image/tif": self = .tiff
        case "image/bmp", "image/x-ms-bmp": self = .bmp
        case "image/avif": self = .avif
        default: return nil
        }
    }
}

/// Versioned external-asset state persisted beside an indexed HTML file.
///
/// Entries describe selected, local image references only. Inline data is
/// already part of the HTML bytes and remote references are never read. A
/// present local asset is identified by a streaming content hash rather than
/// mtime so byte changes are detected even when timestamps are preserved.
public struct HTMLAssetManifest: Codable, Sendable, Equatable {
    public static let schemaVersion = 1

    public enum State: String, Codable, Sendable {
        case present
        case missing
        case tooLarge
    }

    public struct Entry: Codable, Sendable, Equatable {
        public let ordinal: Int
        public let relativePath: String
        public let state: State
        public let byteCount: Int64?
        public let sha256: String?

        public init(
            ordinal: Int,
            relativePath: String,
            state: State,
            byteCount: Int64? = nil,
            sha256: String? = nil
        ) {
            self.ordinal = ordinal
            self.relativePath = relativePath
            self.state = state
            self.byteCount = byteCount
            self.sha256 = sha256
        }
    }

    public let schemaVersion: Int
    public let policyVersion: Int
    public let entries: [Entry]
    public let digest: String

    public init(policyVersion: Int, entries: [Entry]) throws {
        guard policyVersion > 0 else {
            throw HTMLExtractionError.invalidLimit(
                name: "assetManifestPolicyVersion",
                value: Int64(policyVersion)
            )
        }
        self.schemaVersion = Self.schemaVersion
        self.policyVersion = policyVersion
        self.entries = entries
        self.digest = try Self.makeDigest(
            schemaVersion: Self.schemaVersion,
            policyVersion: policyVersion,
            entries: entries
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case policyVersion
        case entries
        case digest
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        let policyVersion = try values.decode(Int.self, forKey: .policyVersion)
        let entries = try values.decode([Entry].self, forKey: .entries)
        let digest = try values.decode(String.self, forKey: .digest)
        guard schemaVersion == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: values,
                debugDescription: "Unsupported HTML asset manifest schema \(schemaVersion)"
            )
        }
        let expected = try Self.makeDigest(
            schemaVersion: schemaVersion,
            policyVersion: policyVersion,
            entries: entries
        )
        guard digest == expected else {
            throw DecodingError.dataCorruptedError(
                forKey: .digest,
                in: values,
                debugDescription: "HTML asset manifest digest does not match its entries"
            )
        }
        self.schemaVersion = schemaVersion
        self.policyVersion = policyVersion
        self.entries = entries
        self.digest = digest
    }

    private struct DigestPayload: Encodable {
        let schemaVersion: Int
        let policyVersion: Int
        let entries: [Entry]
    }

    private static func makeDigest(
        schemaVersion: Int,
        policyVersion: Int,
        entries: [Entry]
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = DigestPayload(
            schemaVersion: schemaVersion,
            policyVersion: policyVersion,
            entries: entries
        )
        let data = try encoder.encode(payload)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct HTMLExtractionDiagnostic: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case articleSelectionFailed
        case articleTooShort
        case imageLimitReached
        case remoteImageIgnored
        case unsupportedImageIgnored
        case imageOutsideAllowedRoot
        case localImageMissing
        case localImageTooLarge
        case inlineImageMalformed
        case inlineImageTooLarge
        case imageUndecodable
    }

    public let kind: Kind
    public let detail: String?

    public init(kind: Kind, detail: String? = nil) {
        self.kind = kind
        self.detail = detail
    }
}

public enum HTMLExtractionError: Error, LocalizedError, Equatable {
    case invalidLimit(name: String, value: Int64)
    case unsupportedAssetPolicyVersion(Int)
    case nonFileSourceURL(URL)
    case nonFileAssetDirectory(URL)
    case inputTooLarge(actualBytes: Int, maximumBytes: Int)
    case elementLimitExceeded(actual: Int, maximum: Int)
    case localAssetTooLarge(path: String, actualBytes: Int64, maximumBytes: Int64)

    public var errorDescription: String? {
        switch self {
        case .invalidLimit(let name, let value):
            return "HTML extraction limit '\(name)' must be positive (got \(value))."
        case .unsupportedAssetPolicyVersion(let version):
            return "HTML OCR asset policy version \(version) is unsupported."
        case .nonFileSourceURL(let url):
            return "HTML extraction accepts local file URLs only (got \(url.absoluteString))."
        case .nonFileAssetDirectory(let url):
            return "HTML OCR asset directories must be local file URLs (got \(url.absoluteString))."
        case .inputTooLarge(let actual, let maximum):
            return "HTML input is \(actual) bytes, exceeding the \(maximum)-byte extraction limit."
        case .elementLimitExceeded(let actual, let maximum):
            return "HTML contains \(actual) elements, exceeding the \(maximum)-element extraction limit."
        case .localAssetTooLarge(let path, let actual, let maximum):
            return "HTML image asset '\(path)' grew to \(actual) bytes while reading, exceeding the \(maximum)-byte limit."
        }
    }
}
