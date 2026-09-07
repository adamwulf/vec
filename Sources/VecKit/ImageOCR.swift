import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// The text recovered from a single image, already ordered for reading.
///
/// `lines` are the visual lines in reading order (top-to-bottom,
/// left-to-right); `paragraphs` groups adjacent lines separated by small
/// vertical gaps and reflows each group onto one string; `text` is the
/// paragraphs joined by blank lines. A blank image (or one whose recognized
/// text is empty) yields empty arrays and an empty `text`.
public struct ImageOCRResult: Sendable, Codable, Equatable {
    public let text: String
    public let lines: [String]
    public let paragraphs: [String]

    public init(text: String, lines: [String], paragraphs: [String]) {
        self.text = text
        self.lines = lines
        self.paragraphs = paragraphs
    }

    /// True when no text was recognized. Blank results are still valid
    /// outcomes and are cached so a text-less image is not re-OCR'd.
    public var isBlank: Bool { text.isEmpty }
}

/// Recognizes text in an image file. Injectable so the cache and pipeline
/// can be exercised without invoking Vision.
public protocol ImageTextRecognizer: Sendable {
    /// Recognize text in the image at `imageURL`.
    ///
    /// A successful call — including one that finds no text — returns an
    /// `ImageOCRResult` (blank when no text). A read or recognition failure
    /// throws; the caller treats such errors as transient and retries.
    func recognizeText(in imageURL: URL) throws -> ImageOCRResult
}

/// Errors raised while decoding an image for OCR.
public enum ImageOCRError: Error, LocalizedError, Equatable {
    /// ImageIO could not create an image source or decode a frame.
    case undecodable(URL)

    public var errorDescription: String? {
        switch self {
        case .undecodable(let url):
            return "Image could not be decoded for OCR: \(url.lastPathComponent)"
        }
    }
}

/// Vision-backed OCR engine. Reads the first frame of an image with ImageIO
/// (honoring EXIF orientation), bounds resolution with a downsample cap, runs
/// an accurate `VNRecognizeTextRequest` with language correction and
/// automatic language detection, and groups the observations into a
/// deterministic reading order.
public struct ImageOCR: ImageTextRecognizer {

    /// Cache-invalidation version. Bump whenever the recognition parameters
    /// or the reading-order grouping change so stale sidecars are ignored.
    public static let version: Int = 1

    /// Pin the Vision request algorithm rather than inheriting a future OS
    /// default revision under an unchanged persisted extraction mode.
    public static let requestRevision: Int = VNRecognizeTextRequestRevision3

    /// Longest edge, in pixels, that a decoded frame is downsampled to before
    /// recognition. Bounds peak memory on very large images. Text that stays
    /// legible after scaling to this size is recognized; extremely small text
    /// in an oversized image can be lost — see `ImageOCRTests`.
    public static let maxPixelDimension: Int = 4096

    /// Lowercase file extensions (no leading dot) the engine can decode.
    /// The fixed raster set is always present; `avif` is added only when the
    /// running ImageIO advertises AVIF decode support. `svg` is deliberately
    /// absent — vector images are skipped by the scanner and extractor.
    public static let supportedExtensions: Set<String> = ImageOCR.detectSupportedExtensions()

    /// Includes unsupported image names so scanner discovery and direct
    /// extraction share one rule for excluding image bytes from text sniffing.
    static let imageLikeExtensions: Set<String> = [
        "jpg", "jpeg", "png", "webp", "gif", "heic", "heif", "tif", "tiff",
        "bmp", "avif", "svg", "svgz"
    ]

    public init() {}

    // MARK: - Recognition

    public func recognizeText(in imageURL: URL) throws -> ImageOCRResult {
        // Per-image autoreleasepool: ImageIO and Vision allocate large
        // autoreleased buffers (the decoded frame, per-observation results).
        // Draining them per image keeps peak memory bounded when many images
        // are OCR'd in a run.
        try autoreleasepool {
            let (cgImage, orientation) = try Self.loadFirstFrame(from: imageURL)

            let request = VNRecognizeTextRequest()
            request.revision = Self.requestRevision
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            // Let Vision pick the language(s); do not pin recognitionLanguages
            // when auto-detection is on.
            request.automaticallyDetectsLanguage = true

            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
            try handler.perform([request])

            let observations = request.results ?? []
            let items = observations.compactMap { observation -> (text: String, box: CGRect)? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return (candidate.string, observation.boundingBox)
            }
            return Self.readingOrder(from: items)
        }
    }

    // MARK: - Image loading

    /// Decode the first frame of `url`, downsampled to `maxPixelDimension`,
    /// and read its EXIF orientation. The thumbnail is created *without* the
    /// orientation transform so the raw pixels are handed to Vision alongside
    /// the orientation tag (Vision applies it), avoiding a double rotation.
    static func loadFirstFrame(from url: URL) throws -> (CGImage, CGImagePropertyOrientation) {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary),
              CGImageSourceGetCount(source) > 0 else {
            throw ImageOCRError.undecodable(url)
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let rawOrientation = (properties?[kCGImagePropertyOrientation] as? UInt32) ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: rawOrientation) ?? .up

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceThumbnailMaxPixelSize: Self.maxPixelDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            throw ImageOCRError.undecodable(url)
        }
        return (image, orientation)
    }

    // MARK: - Reading-order grouping

    /// Order recognized fragments into lines and paragraphs deterministically.
    ///
    /// Input boxes use Vision's normalized coordinate space (origin at the
    /// bottom-left, y increasing upward). Fragments are converted to a
    /// top-down space, sorted top-to-bottom then left-to-right, grouped into
    /// visual lines by vertical-band membership, and lines are grouped into
    /// paragraphs by comparing the inter-line gap to the median line height.
    /// The transformation is pure and total, so it is unit-testable with
    /// synthetic boxes and never depends on Vision's availability.
    static func readingOrder(from items: [(text: String, box: CGRect)]) -> ImageOCRResult {
        let cleaned: [(text: String, box: CGRect)] = items.compactMap { item in
            let trimmed = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : (trimmed, item.box)
        }
        guard !cleaned.isEmpty else {
            return ImageOCRResult(text: "", lines: [], paragraphs: [])
        }

        struct Fragment {
            let text: String
            let top: Double
            let bottom: Double
            let left: Double
            var midY: Double { (top + bottom) / 2 }
            // A hairline positive floor so a zero-height box still has a
            // usable tolerance; matches `epsilon` but stated inline because a
            // local type cannot reference the enclosing scope's statics.
            var height: Double { max(bottom - top, 1e-9) }
        }

        // Convert to top-down coordinates so "smaller top" reads first.
        let fragments = cleaned.map { item -> Fragment in
            let box = item.box
            return Fragment(
                text: item.text,
                top: 1.0 - Double(box.maxY),
                bottom: 1.0 - Double(box.minY),
                left: Double(box.minX)
            )
        }

        // Deterministic total order on EXACT keys: top, then left, then text.
        // Exact `<`/`!=` on the coordinates is a strict weak ordering (an
        // epsilon-tolerant comparator is not transitive and can crash or
        // scramble `sort`). Near-equal tops are reconciled later by the
        // line-grouping tolerance, not by fuzzing the comparator.
        let sorted = fragments.sorted { lhs, rhs in
            if lhs.top != rhs.top { return lhs.top < rhs.top }
            if lhs.left != rhs.left { return lhs.left < rhs.left }
            return lhs.text < rhs.text
        }

        struct Line {
            var fragments: [Fragment]
            var top: Double
            var bottom: Double
        }

        // Group fragments into visual lines. A fragment joins the current line
        // when its vertical center sits inside that line's band, grown by a
        // fraction of the fragment's own height (tolerates minor baseline
        // jitter between neighboring fragments on the same line).
        var lines: [Line] = []
        for fragment in sorted {
            if var current = lines.last {
                let tolerance = 0.3 * fragment.height
                if fragment.midY <= current.bottom + tolerance,
                   fragment.midY >= current.top - tolerance {
                    current.fragments.append(fragment)
                    current.top = min(current.top, fragment.top)
                    current.bottom = max(current.bottom, fragment.bottom)
                    lines[lines.count - 1] = current
                    continue
                }
            }
            lines.append(Line(fragments: [fragment], top: fragment.top, bottom: fragment.bottom))
        }

        // Order each line left-to-right and join with single spaces. Exact
        // keys again (left, then text) for a strict weak ordering.
        let lineTexts = lines.map { line -> String in
            line.fragments
                .sorted { lhs, rhs in
                    if lhs.left != rhs.left { return lhs.left < rhs.left }
                    return lhs.text < rhs.text
                }
                .map(\.text)
                .joined(separator: " ")
        }

        // Group lines into paragraphs by vertical gap vs. median line height.
        let heights = lines.map { max($0.bottom - $0.top, epsilon) }
        let medianHeight = median(heights)
        var paragraphLineIndices: [[Int]] = []
        for index in lines.indices {
            if index == 0 {
                paragraphLineIndices.append([index])
                continue
            }
            let gap = lines[index].top - lines[index - 1].bottom
            if gap > paragraphGapFactor * medianHeight {
                paragraphLineIndices.append([index])
            } else {
                paragraphLineIndices[paragraphLineIndices.count - 1].append(index)
            }
        }

        let paragraphs = paragraphLineIndices.map { indices in
            indices.map { lineTexts[$0] }.joined(separator: " ")
        }
        let text = paragraphs.joined(separator: "\n\n")
        return ImageOCRResult(text: text, lines: lineTexts, paragraphs: paragraphs)
    }

    /// A vertical gap larger than this fraction of the median line height
    /// starts a new paragraph.
    private static let paragraphGapFactor = 0.6
    /// Coordinate comparison slack; boxes are normalized to [0, 1].
    private static let epsilon = 1e-9

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    // MARK: - Supported extensions

    private static func detectSupportedExtensions() -> Set<String> {
        // Frozen raster set for E12. `heif` is intentionally excluded (heic is
        // the frozen HEVC-still extension); `svg`/`svgz` are skipped.
        var extensions: Set<String> = [
            "jpg", "jpeg", "png", "webp", "gif", "heic", "tiff", "tif", "bmp"
        ]
        if imageIOAdvertisesAVIF() {
            extensions.insert("avif")
        }
        return extensions
    }

    /// Whether the running ImageIO advertises AVIF decode support. AVIF is
    /// only decodable on some OS versions, so it is gated at runtime rather
    /// than hardcoded into the frozen set.
    static func imageIOAdvertisesAVIF() -> Bool {
        let identifiers = (CGImageSourceCopyTypeIdentifiers() as NSArray).compactMap { $0 as? String }
        let advertised = Set(identifiers)
        if advertised.contains("public.avif") || advertised.contains("public.avif-sequence") {
            return true
        }
        if let type = UTType(filenameExtension: "avif") {
            return advertised.contains(type.identifier)
        }
        return false
    }
}
