import CoreGraphics
import CryptoKit
import Foundation
@preconcurrency import PDFKit
import Vision

/// Rendering controls that affect PDF OCR output and therefore participate in
/// every persisted cache key.
public struct PDFOCRRenderSettings: Sendable, Codable, Hashable {
    /// Requested raster resolution before the longest-edge cap is applied.
    public let dpi: Int
    /// Maximum raster dimension for either edge. This bounds a page bitmap's
    /// resident memory even for unusually large PDF page boxes.
    public let maxPixelDimension: Int

    public init(dpi: Int = 144, maxPixelDimension: Int = 4096) {
        precondition(dpi > 0, "dpi must be positive")
        precondition(maxPixelDimension > 0, "maxPixelDimension must be positive")
        self.dpi = dpi
        self.maxPixelDimension = maxPixelDimension
    }
}

/// A normalized Vision-style rectangle (origin at the lower-left) associated
/// with one OCR observation.
public struct PDFOCRBoundingBox: Sendable, Codable, Hashable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ rect: CGRect) {
        self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// Text and geometry returned by a PDF-page OCR engine.
public struct PDFOCRObservation: Sendable, Codable, Hashable {
    public let text: String
    public let boundingBox: PDFOCRBoundingBox

    public init(text: String, boundingBox: PDFOCRBoundingBox) {
        self.text = text
        self.boundingBox = boundingBox
    }
}

/// Successful recognition of one rendered page. An empty observation array is
/// a valid blank-page outcome and is cached.
public struct PDFPageOCRRecognition: Sendable, Codable, Equatable {
    public let observations: [PDFOCRObservation]

    public init(observations: [PDFOCRObservation]) {
        self.observations = observations
    }

    public var isBlank: Bool {
        observations.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

/// Injectable page-image recognizer. Geometry is retained so the reader can
/// interleave native PDF lines with raster-only lines in page reading order.
public protocol PDFPageTextRecognizer: Sendable {
    func recognizeText(in pageImage: CGImage) throws -> PDFPageOCRRecognition
}

/// Vision-backed page recognizer. Its request parameters deliberately match
/// E12 ImageOCR and pin revision 3, preventing an OS default change from
/// silently changing a persisted extraction version.
public struct VisionPDFPageTextRecognizer: PDFPageTextRecognizer {
    public init() {}

    public func recognizeText(in pageImage: CGImage) throws -> PDFPageOCRRecognition {
        let request = VNRecognizeTextRequest()
        request.revision = ImageOCR.requestRevision
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

        let handler = VNImageRequestHandler(cgImage: pageImage, orientation: .up, options: [:])
        try handler.perform([request])
        let observations = (request.results ?? []).compactMap { observation -> PDFOCRObservation? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return PDFOCRObservation(text: text, boundingBox: PDFOCRBoundingBox(observation.boundingBox))
        }
        return PDFPageOCRRecognition(observations: observations)
    }
}

/// Text recovered from one PDF page.
public struct PDFOCRPageResult: Sendable, Equatable {
    public let pageNumber: Int
    /// PDFKit's authoritative embedded text, preserved verbatim apart from
    /// leading/trailing whitespace.
    public let nativeText: String
    /// OCR-only additions after conservative native-text deduplication, in
    /// visual order. This excludes OCR copies of embedded text.
    public let ocrText: String
    /// Native lines and OCR-only additions merged by page geometry when
    /// PDFKit supplies usable line bounds; otherwise a documented native-first
    /// fallback is used.
    public let combinedText: String
    public let usedGeometricReadingOrder: Bool

    public init(pageNumber: Int,
                nativeText: String,
                ocrText: String,
                combinedText: String,
                usedGeometricReadingOrder: Bool) {
        self.pageNumber = pageNumber
        self.nativeText = nativeText
        self.ocrText = ocrText
        self.combinedText = combinedText
        self.usedGeometricReadingOrder = usedGeometricReadingOrder
    }
}

/// Result for a PDF document. `pages` includes blank pages so page provenance
/// is never renumbered; callers omit pages whose `combinedText` is empty when
/// producing chunks.
public struct PDFOCRDocumentResult: Sendable, Equatable {
    public let pageCount: Int
    public let pages: [PDFOCRPageResult]

    public init(pageCount: Int, pages: [PDFOCRPageResult]) {
        self.pageCount = pageCount
        self.pages = pages
    }
}

public enum PDFOCRReaderError: Error, LocalizedError, Equatable {
    case invalidPDF(URL)
    case missingPageReference(pageNumber: Int)
    case couldNotRender(pageNumber: Int, width: Int, height: Int)
    case sourceChangedDuringRead(URL)

    public var errorDescription: String? {
        switch self {
        case .invalidPDF(let url):
            return "PDF could not be decoded for OCR: \(url.lastPathComponent)"
        case .missingPageReference(let pageNumber):
            return "PDF page \(pageNumber) has no Core Graphics page reference"
        case .couldNotRender(let pageNumber, let width, let height):
            return "Could not render PDF page \(pageNumber) at \(width)x\(height)"
        case .sourceChangedDuringRead(let url):
            return "PDF changed while it was being read: \(url.lastPathComponent)"
        }
    }
}

/// Native-text-plus-OCR PDF reader.
///
/// Pages are processed serially within a document. A reader-wide permit pool
/// also bounds concurrent documents sharing this reader (the default is one
/// page render/recognition globally). Each page bitmap and Vision request live
/// inside an autorelease pool and are released before the next page begins;
/// the full document is never rasterized at once.
public final class PDFOCRReader: @unchecked Sendable {
    /// Cache invalidation version for rendering, ordering, and deduplication.
    public static let version = 1

    private let settings: PDFOCRRenderSettings
    private let recognizer: PDFPageTextRecognizer
    private let cache: PDFOCRCache?
    private let limiter: PageOperationLimiter

    public init(settings: PDFOCRRenderSettings = PDFOCRRenderSettings(),
                recognizer: PDFPageTextRecognizer = VisionPDFPageTextRecognizer(),
                cacheDirectory: URL? = nil,
                maximumConcurrentPageOperations: Int = 1) {
        precondition(maximumConcurrentPageOperations >= 1,
                     "maximumConcurrentPageOperations must be >= 1")
        self.settings = settings
        self.recognizer = recognizer
        self.limiter = PageOperationLimiter(limit: maximumConcurrentPageOperations)
        self.cache = cacheDirectory.map {
            PDFOCRCache(directory: $0, version: Self.version)
        }
    }

    public var cacheStatistics: PDFOCRCacheStatistics? { cache?.statistics }

    public func read(from url: URL) throws -> PDFOCRDocumentResult {
        // Hash exactly once while taking an immutable in-memory byte snapshot.
        // PDFKit reads the snapshot rather than reopening the path, so a later
        // replacement cannot cause results for different bytes to be written
        // under this hash. File identity before/after the stream catches a
        // writer changing the source during the snapshot itself.
        let snapshot = try Self.snapshot(from: url)
        guard let document = PDFDocument(data: snapshot.data) else {
            throw PDFOCRReaderError.invalidPDF(url)
        }

        var pages: [PDFOCRPageResult] = []
        pages.reserveCapacity(document.pageCount)
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let pageNumber = pageIndex + 1
            let result = try autoreleasepool {
                try limiter.withPermit {
                    try read(page: page, pageNumber: pageNumber, documentHash: snapshot.hash)
                }
            }
            pages.append(result)
        }
        // The page results came from the immutable snapshot, so any sidecars
        // already written describe exactly `snapshot.hash`. Re-hash the live
        // path after extraction as the authoritative guard against a writer
        // changing the source while this call was in flight; such a run must
        // not be reported as a successful extraction to the indexing layer.
        guard try Self.contentHash(from: url) == snapshot.hash else {
            throw PDFOCRReaderError.sourceChangedDuringRead(url)
        }
        return PDFOCRDocumentResult(pageCount: document.pageCount, pages: pages)
    }

    private func read(page: PDFPage,
                      pageNumber: Int,
                      documentHash: String) throws -> PDFOCRPageResult {
        guard let pageReference = page.pageRef else {
            throw PDFOCRReaderError.missingPageReference(pageNumber: pageNumber)
        }
        let geometry = Self.renderGeometry(for: pageReference, settings: settings)
        let nativeText = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let nativeLines = Self.nativeLines(on: page, drawingTransform: geometry.drawingTransform,
                                           pixelSize: geometry.pixelSize)

        let recognition: PDFPageOCRRecognition
        if let cache {
            recognition = try cache.value(documentHash: documentHash,
                                          pageNumber: pageNumber,
                                          settings: settings) {
                let image = try Self.render(pageReference: pageReference,
                                            pageNumber: pageNumber,
                                            geometry: geometry)
                return try recognizer.recognizeText(in: image)
            }
        } else {
            let image = try Self.render(pageReference: pageReference,
                                        pageNumber: pageNumber,
                                        geometry: geometry)
            recognition = try recognizer.recognizeText(in: image)
        }

        return Self.compose(pageNumber: pageNumber,
                            nativeText: nativeText,
                            nativeLines: nativeLines,
                            recognition: recognition)
    }

    // MARK: - Composition and deduplication

    private struct PositionedLine {
        enum Source { case native, ocr }
        let text: String
        let box: CGRect
        let source: Source
    }

    static func compose(pageNumber: Int,
                        nativeText: String,
                        nativeLines: [(text: String, box: CGRect)],
                        recognition: PDFPageOCRRecognition) -> PDFOCRPageResult {
        let authoritativeNative = nativeText.trimmingCharacters(in: .whitespacesAndNewlines)
        let nativeTokens = normalizedTokens(authoritativeNative)
        let orderedOCR = recognition.observations
            .compactMap { observation -> PositionedLine? in
                let text = observation.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return PositionedLine(text: text, box: observation.boundingBox.cgRect, source: .ocr)
            }
            .sorted(by: readingOrder)

        var additions: [PositionedLine] = []
        var acceptedOCRTokens: [[String]] = []
        for line in orderedOCR {
            guard let novelText = novelOCRText(line.text,
                                               nativeTokens: nativeTokens,
                                               acceptedOCRTokens: acceptedOCRTokens) else { continue }
            let tokens = normalizedTokens(novelText)
            guard !tokens.isEmpty else { continue }
            acceptedOCRTokens.append(tokens)
            additions.append(PositionedLine(text: novelText, box: line.box, source: .ocr))
        }
        let ocrText = additions.map(\.text).joined(separator: "\n")

        let cleanedNativeLines = nativeLines.compactMap { line -> PositionedLine? in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, line.box.width > 0, line.box.height > 0 else { return nil }
            return PositionedLine(text: text, box: line.box, source: .native)
        }
        let selectionTokens = normalizedTokens(cleanedNativeLines.map(\.text).joined(separator: " "))
        let hasCompleteNativeGeometry = !authoritativeNative.isEmpty
            && !cleanedNativeLines.isEmpty
            && selectionTokens == nativeTokens

        let combined: String
        let usedGeometry: Bool
        if authoritativeNative.isEmpty {
            combined = ocrText
            usedGeometry = !additions.isEmpty
        } else if additions.isEmpty {
            combined = authoritativeNative
            usedGeometry = false
        } else if hasCompleteNativeGeometry {
            combined = (cleanedNativeLines + additions)
                .sorted(by: readingOrder)
                .map(\.text)
                .joined(separator: "\n")
            usedGeometry = true
        } else {
            // Complex encodings can make PDFSelection line text diverge from
            // PDFPage.string. Preserve the authoritative native string and
            // append only proven-novel OCR lines rather than risking loss.
            combined = [authoritativeNative, ocrText].filter { !$0.isEmpty }.joined(separator: "\n\n")
            usedGeometry = false
        }

        return PDFOCRPageResult(pageNumber: pageNumber,
                                nativeText: authoritativeNative,
                                ocrText: ocrText,
                                combinedText: combined,
                                usedGeometricReadingOrder: usedGeometry)
    }

    private static func readingOrder(_ lhs: PositionedLine, _ rhs: PositionedLine) -> Bool {
        // Normalized boxes use bottom-left origin. A 0.35-line-height band
        // treats small baseline jitter as one row, then orders left-to-right.
        let lhsTop = 1 - lhs.box.maxY
        let rhsTop = 1 - rhs.box.maxY
        let tolerance = 0.35 * min(lhs.box.height, rhs.box.height)
        if abs(lhsTop - rhsTop) > tolerance { return lhsTop < rhsTop }
        if lhs.box.minX != rhs.box.minX { return lhs.box.minX < rhs.box.minX }
        // Prefer native text for an exact geometric tie.
        if lhs.source != rhs.source { return lhs.source == .native }
        return lhs.text < rhs.text
    }

    /// Return the novel portion of an OCR line, or nil when it is already
    /// represented by native text / a prior OCR line. Matching is deliberately
    /// sequence-based, never bag-of-words: "total 100" cannot suppress
    /// "total 200". Exact 3+-token prefix/suffix overlap is trimmed so a line
    /// such as "existing native phrase novel fact" retains "novel fact".
    static func novelOCRText(_ text: String,
                             nativeTokens: [String],
                             acceptedOCRTokens: [[String]] = []) -> String? {
        let tokens = normalizedTokens(text)
        guard !tokens.isEmpty else { return nil }
        if containsSequence(nativeTokens, tokens)
            || acceptedOCRTokens.contains(where: { containsSequence($0, tokens) }) {
            return nil
        }

        var retained = tokens
        let sources = [nativeTokens] + acceptedOCRTokens
        let prefixOverlap = sources.map { longestContainedPrefix(of: retained, in: $0) }.max() ?? 0
        if prefixOverlap >= 3, prefixOverlap < retained.count {
            retained.removeFirst(prefixOverlap)
        }
        let suffixOverlap = sources.map { longestContainedSuffix(of: retained, in: $0) }.max() ?? 0
        if suffixOverlap >= 3, suffixOverlap < retained.count {
            retained.removeLast(suffixOverlap)
        }
        guard !retained.isEmpty else { return nil }
        if retained == tokens { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return retained.joined(separator: " ")
    }

    static func normalizedTokens(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars
            .split { !CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
    }

    private static func containsSequence(_ haystack: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<(start + needle.count)]) == needle { return true }
        }
        return false
    }

    private static func longestContainedPrefix(of tokens: [String], in source: [String]) -> Int {
        guard !tokens.isEmpty else { return 0 }
        for length in stride(from: tokens.count, through: 1, by: -1) {
            if containsSequence(source, Array(tokens.prefix(length))) { return length }
        }
        return 0
    }

    private static func longestContainedSuffix(of tokens: [String], in source: [String]) -> Int {
        guard !tokens.isEmpty else { return 0 }
        for length in stride(from: tokens.count, through: 1, by: -1) {
            if containsSequence(source, Array(tokens.suffix(length))) { return length }
        }
        return 0
    }

    // MARK: - Native line geometry

    private static func nativeLines(on page: PDFPage,
                                    drawingTransform: CGAffineTransform,
                                    pixelSize: CGSize) -> [(text: String, box: CGRect)] {
        guard pixelSize.width > 0, pixelSize.height > 0,
              let pageText = page.string, !pageText.isEmpty else { return [] }

        // `PDFPage.string` and `numberOfCharacters` use NSString/UTF-16
        // indexing. Walking NSString line ranges therefore stays aligned with
        // `characterBounds(at:)`, including non-ASCII embedded text.
        let nsText = pageText as NSString
        var lines: [(text: String, box: CGRect)] = []
        var location = 0
        while location < nsText.length {
            let range = nsText.lineRange(for: NSRange(location: location, length: 0))
            let rawLine = nsText.substring(with: range)
            let text = rawLine.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if !text.isEmpty {
                var pageBounds = CGRect.null
                let upperBound = min(NSMaxRange(range), page.numberOfCharacters)
                if location < upperBound {
                    for characterIndex in location..<upperBound {
                        let bounds = page.characterBounds(at: characterIndex)
                        if !bounds.isNull, !bounds.isInfinite, bounds.width > 0, bounds.height > 0 {
                            pageBounds = pageBounds.union(bounds)
                        }
                    }
                }
                if !pageBounds.isNull, !pageBounds.isInfinite {
                    let pixelBounds = pageBounds.applying(drawingTransform).standardized
                    let normalized = CGRect(x: pixelBounds.minX / pixelSize.width,
                                            y: pixelBounds.minY / pixelSize.height,
                                            width: pixelBounds.width / pixelSize.width,
                                            height: pixelBounds.height / pixelSize.height)
                    lines.append((text, normalized))
                }
            }
            let next = NSMaxRange(range)
            guard next > location else { break }
            location = next
        }
        return lines
    }

    // MARK: - Rendering

    struct RenderGeometry {
        let pixelSize: CGSize
        let drawingTransform: CGAffineTransform
    }

    static func renderGeometry(for page: CGPDFPage,
                               settings: PDFOCRRenderSettings) -> RenderGeometry {
        let box = page.getBoxRect(.cropBox).standardized
        let normalizedRotation = ((page.rotationAngle % 360) + 360) % 360
        let displayedPoints: CGSize
        if normalizedRotation == 90 || normalizedRotation == 270 {
            displayedPoints = CGSize(width: box.height, height: box.width)
        } else {
            displayedPoints = box.size
        }
        let requestedScale = CGFloat(settings.dpi) / 72
        let requestedLongest = max(displayedPoints.width, displayedPoints.height) * requestedScale
        let cappedScale = requestedLongest > CGFloat(settings.maxPixelDimension)
            ? CGFloat(settings.maxPixelDimension) / max(displayedPoints.width, displayedPoints.height)
            : requestedScale
        let width = max(1, Int(ceil(displayedPoints.width * cappedScale)))
        let height = max(1, Int(ceil(displayedPoints.height * cappedScale)))
        let pixelRect = CGRect(x: 0, y: 0, width: width, height: height)
        let transform = page.getDrawingTransform(.cropBox, rect: pixelRect,
                                                 rotate: 0, preserveAspectRatio: true)
        return RenderGeometry(pixelSize: CGSize(width: width, height: height),
                              drawingTransform: transform)
    }

    static func render(pageReference: CGPDFPage,
                       pageNumber: Int,
                       geometry: RenderGeometry) throws -> CGImage {
        let width = Int(geometry.pixelSize.width)
        let height = Int(geometry.pixelSize.height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw PDFOCRReaderError.couldNotRender(pageNumber: pageNumber, width: width, height: height)
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: geometry.pixelSize))
        context.saveGState()
        context.concatenate(geometry.drawingTransform)
        context.drawPDFPage(pageReference)
        context.restoreGState()
        guard let image = context.makeImage() else {
            throw PDFOCRReaderError.couldNotRender(pageNumber: pageNumber, width: width, height: height)
        }
        return image
    }

    // MARK: - Stable source snapshot

    private struct Snapshot {
        let data: Data
        let hash: String
    }

    private struct SourceIdentity: Equatable {
        let size: Int?
        let modificationDate: Date?
    }

    private static let hashChunkSize = 1 << 20

    private static func snapshot(from url: URL) throws -> Snapshot {
        let before = try sourceIdentity(for: url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        if let size = before.size, size > 0 { data.reserveCapacity(size) }
        var hasher = SHA256()
        while true {
            let chunk = try autoreleasepool { try handle.read(upToCount: hashChunkSize) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            data.append(chunk)
        }
        let after = try sourceIdentity(for: url)
        guard before == after else { throw PDFOCRReaderError.sourceChangedDuringRead(url) }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return Snapshot(data: data, hash: hash)
    }

    private static func sourceIdentity(for url: URL) throws -> SourceIdentity {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return SourceIdentity(size: values.fileSize,
                              modificationDate: values.contentModificationDate)
    }

    private static func contentHash(from url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try autoreleasepool { try handle.read(upToCount: hashChunkSize) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Blocking permit pool used because the reader API and the surrounding
/// extraction pipeline are synchronous. The manager's OCR lane may call a
/// reader concurrently for several PDFs; this ensures only the configured
/// number of page bitmaps/Vision requests are alive across those calls.
private final class PageOperationLimiter: @unchecked Sendable {
    private let condition = NSCondition()
    private let limit: Int
    private var active = 0

    init(limit: Int) { self.limit = limit }

    func withPermit<T>(_ operation: () throws -> T) rethrows -> T {
        condition.lock()
        while active >= limit { condition.wait() }
        active += 1
        condition.unlock()
        defer {
            condition.lock()
            active -= 1
            condition.signal()
            condition.unlock()
        }
        return try operation()
    }
}
