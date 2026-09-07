import CoreGraphics
import CoreText
import Foundation
@preconcurrency import PDFKit
import XCTest
@testable import VecKit

/// PDF fixtures are rendered at test time. Vision tests assert-or-fail on the
/// pre-approved native macOS runtime; there are no availability skips that can
/// turn a broken OCR engine into a green build.
final class PDFOCRReaderTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-ocr-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory { try? FileManager.default.removeItem(at: tempDirectory) }
        try super.tearDownWithError()
    }

    // MARK: - Real Vision fixtures

    func testRealVisionReadsNativeImageMixedBlankAndMultipageWithProvenance() throws {
        let url = tempDirectory.appendingPathComponent("all-page-kinds.pdf")
        try writePDF([
            PageFixture(native: ["NATIVE ORCHARD SIGNAL"]),
            PageFixture(images: [ImageLine("RASTER NEBULA TOKEN", y: 330)]),
            PageFixture(native: ["NATIVE CEDAR HEADER"],
                        images: [ImageLine("RASTER QUARTZ DETAIL", y: 300)]),
            PageFixture(),
            PageFixture(native: ["PAGE FIVE PROVENANCE"]),
        ], to: url)

        let result = try PDFOCRReader().read(from: url)

        XCTAssertEqual(result.pageCount, 5)
        XCTAssertEqual(result.pages.map(\.pageNumber), [1, 2, 3, 4, 5])
        assertContains(result.pages[0].nativeText, words: ["native", "orchard", "signal"])
        assertContains(result.pages[0].combinedText, words: ["native", "orchard", "signal"])
        assertContains(result.pages[1].ocrText, words: ["raster", "nebula", "token"])
        XCTAssertTrue(result.pages[1].nativeText.isEmpty, "Raster-only page must have no embedded text")
        assertContains(result.pages[2].combinedText,
                       words: ["native", "cedar", "header", "raster", "quartz", "detail"])
        XCTAssertTrue(result.pages[3].combinedText.isEmpty, "Blank page must yield no extractable page text")
        XCTAssertTrue(result.pages[3].nativeText.isEmpty)
        XCTAssertTrue(result.pages[3].ocrText.isEmpty)
        assertContains(result.pages[4].combinedText, words: ["page", "five", "provenance"])
    }

    func testRealVisionDeduplicatesNativePassageAlsoPresentAsRaster() throws {
        let phrase = "COPPER LANTERN ARCHIVE"
        let url = tempDirectory.appendingPathComponent("duplicate-overlap.pdf")
        try writePDF([
            PageFixture(native: [phrase], images: [ImageLine(phrase, y: 300)])
        ], to: url)

        let page = try XCTUnwrap(PDFOCRReader().read(from: url).pages.first)
        assertContains(page.nativeText, words: ["copper", "lantern", "archive"])
        XCTAssertFalse(normalized(page.ocrText).contains("copper lantern archive"),
                       "OCR copy of authoritative embedded text must be removed")
        XCTAssertEqual(occurrences(of: "copper lantern archive", in: normalized(page.combinedText)), 1,
                       "Duplicate native+raster passage must occur exactly once")
    }

    func testRealVisionHonorsCropBoxAndPageRotation() throws {
        let originalURL = tempDirectory.appendingPathComponent("crop-unrotated.pdf")
        let finalURL = tempDirectory.appendingPathComponent("crop-rotated.pdf")
        let crop = CGRect(x: 55, y: 100, width: 500, height: 300)
        try writePDF([
            PageFixture(images: [ImageLine("ROTATED CROP MARKER", y: 190)], cropBox: crop)
        ], to: originalURL)
        let document = try XCTUnwrap(PDFDocument(url: originalURL))
        let page = try XCTUnwrap(document.page(at: 0))
        page.setBounds(crop, for: .cropBox)
        page.rotation = 90
        XCTAssertTrue(document.write(to: finalURL), "PDFKit must persist the /Rotate fixture")

        let rotatedDocument = try XCTUnwrap(PDFDocument(url: finalURL))
        let reopenedPage = try XCTUnwrap(rotatedDocument.page(at: 0))
        XCTAssertEqual(reopenedPage.rotation, 90, "Fixture must persist /Rotate before testing the reader")
        let pageReference = try XCTUnwrap(reopenedPage.pageRef)
        XCTAssertEqual(pageReference.getBoxRect(.cropBox), crop,
                       "Fixture must persist the non-default crop box before testing the reader")
        let geometry = PDFOCRReader.renderGeometry(for: pageReference,
                                                   settings: PDFOCRRenderSettings(dpi: 144,
                                                                                 maxPixelDimension: 4096))
        XCTAssertEqual(Int(geometry.pixelSize.width), 600,
                       "90-degree rotation swaps the 500x300 crop dimensions")
        XCTAssertEqual(Int(geometry.pixelSize.height), 1000)

        let result = try PDFOCRReader().read(from: finalURL)
        let extracted = try XCTUnwrap(result.pages.first)
        assertContains(extracted.combinedText, words: ["rotated", "crop", "marker"])
    }

    // MARK: - Cache outcomes and retries

    func testDiskCacheSkipsRenderingRecognizerAndKeysPagesSeparately() throws {
        let url = tempDirectory.appendingPathComponent("two-pages.pdf")
        try writePDF([PageFixture(), PageFixture()], to: url)
        let cacheDirectory = tempDirectory.appendingPathComponent("cache")

        let warmer = CountingPDFRecognizer(result: recognition("warm result"))
        let firstReader = PDFOCRReader(recognizer: warmer, cacheDirectory: cacheDirectory)
        let first = try firstReader.read(from: url)
        XCTAssertEqual(warmer.attemptCount, 2, "Each page is an independent cold cache entry")
        XCTAssertEqual(firstReader.cacheStatistics,
                       PDFOCRCacheStatistics(hits: 0, misses: 2, ocrCalls: 2))
        XCTAssertEqual(first.pages.map(\.pageNumber), [1, 2])

        let shouldNotRun = CountingPDFRecognizer(result: recognition("wrong result"))
        let secondReader = PDFOCRReader(recognizer: shouldNotRun, cacheDirectory: cacheDirectory)
        let second = try secondReader.read(from: url)
        XCTAssertEqual(shouldNotRun.attemptCount, 0, "Fresh reader must use persisted page sidecars")
        XCTAssertEqual(secondReader.cacheStatistics,
                       PDFOCRCacheStatistics(hits: 2, misses: 0, ocrCalls: 0))
        XCTAssertTrue(second.pages.allSatisfy { normalized($0.ocrText).contains("warm result") })
    }

    func testBlankSuccessIsCachedAndRecognitionFailureRetries() throws {
        let blankURL = tempDirectory.appendingPathComponent("blank.pdf")
        try writePDF([PageFixture()], to: blankURL)
        let blankRecognizer = CountingPDFRecognizer(result: PDFPageOCRRecognition(observations: []))
        let blankReader = PDFOCRReader(recognizer: blankRecognizer,
                                       cacheDirectory: tempDirectory.appendingPathComponent("blank-cache"))
        XCTAssertTrue(try blankReader.read(from: blankURL).pages[0].combinedText.isEmpty)
        XCTAssertTrue(try blankReader.read(from: blankURL).pages[0].combinedText.isEmpty)
        XCTAssertEqual(blankRecognizer.attemptCount, 1, "Successful blank OCR is cacheable")

        let retrying = CountingPDFRecognizer(result: recognition("recovered OCR"), failuresBeforeSuccess: 1)
        let retryReader = PDFOCRReader(recognizer: retrying,
                                       cacheDirectory: tempDirectory.appendingPathComponent("retry-cache"))
        XCTAssertThrowsError(try retryReader.read(from: blankURL))
        let recovered = try retryReader.read(from: blankURL)
        assertContains(recovered.pages[0].ocrText, words: ["recovered", "ocr"])
        XCTAssertEqual(retrying.attemptCount, 2, "Failed recognition must not be cached")
        XCTAssertEqual(retryReader.cacheStatistics,
                       PDFOCRCacheStatistics(hits: 0, misses: 2, ocrCalls: 1))
    }

    func testRenderSettingsParticipateInCacheKey() throws {
        let url = tempDirectory.appendingPathComponent("settings.pdf")
        try writePDF([PageFixture()], to: url)
        let cacheDirectory = tempDirectory.appendingPathComponent("settings-cache")
        let first = CountingPDFRecognizer(result: recognition("first"))
        _ = try PDFOCRReader(settings: PDFOCRRenderSettings(dpi: 144, maxPixelDimension: 4096),
                             recognizer: first, cacheDirectory: cacheDirectory).read(from: url)
        let changed = CountingPDFRecognizer(result: recognition("changed"))
        let changedReader = PDFOCRReader(settings: PDFOCRRenderSettings(dpi: 216,
                                                                        maxPixelDimension: 4096),
                                         recognizer: changed,
                                         cacheDirectory: cacheDirectory)
        let result = try changedReader.read(from: url)
        XCTAssertEqual(changed.attemptCount, 1, "DPI change must invalidate the page sidecar")
        XCTAssertTrue(normalized(result.pages[0].ocrText).contains("changed"))
    }

    func testPDFContentChangeAtSamePathInvalidatesCache() throws {
        let url = tempDirectory.appendingPathComponent("mutable.pdf")
        try writePDF([PageFixture(native: ["FIRST DOCUMENT"])], to: url)
        let recognizer = CountingPDFRecognizer(result: recognition("raster addition"))
        let reader = PDFOCRReader(recognizer: recognizer,
                                  cacheDirectory: tempDirectory.appendingPathComponent("content-cache"))
        _ = try reader.read(from: url)
        XCTAssertEqual(recognizer.attemptCount, 1)

        // Same path and page number, different PDF bytes: the content hash
        // must produce a cold page key rather than reusing the old sidecar.
        try writePDF([PageFixture(native: ["SECOND DOCUMENT"])], to: url)
        let changed = try reader.read(from: url)
        XCTAssertEqual(recognizer.attemptCount, 2)
        assertContains(changed.pages[0].nativeText, words: ["second", "document"])
        XCTAssertEqual(reader.cacheStatistics,
                       PDFOCRCacheStatistics(hits: 0, misses: 2, ocrCalls: 2))
    }

    func testReaderWidePageLimiterBoundsConcurrentDocuments() throws {
        let firstURL = tempDirectory.appendingPathComponent("concurrent-a.pdf")
        let secondURL = tempDirectory.appendingPathComponent("concurrent-b.pdf")
        try writePDF([PageFixture()], to: firstURL)
        try writePDF([PageFixture()], to: secondURL)
        let recognizer = ConcurrencyTrackingRecognizer()
        let reader = PDFOCRReader(recognizer: recognizer, maximumConcurrentPageOperations: 1)
        let group = DispatchGroup()
        for url in [firstURL, secondURL] {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                _ = try? reader.read(from: url)
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(recognizer.attemptCount, 2)
        XCTAssertEqual(recognizer.maximumActiveCount, 1,
                       "One shared reader must never retain more page operations than configured")
    }

    // MARK: - Pure ordering and deduplication

    func testCompositionInterleavesNativeAndRasterLinesByGeometry() {
        let recognition = PDFPageOCRRecognition(observations: [
            observation("image middle", x: 0.1, y: 0.45),
            observation("native top", x: 0.1, y: 0.80), // duplicate of native line
        ])
        let result = PDFOCRReader.compose(
            pageNumber: 7,
            nativeText: "native top\nnative bottom",
            nativeLines: [
                ("native top", CGRect(x: 0.1, y: 0.80, width: 0.5, height: 0.05)),
                ("native bottom", CGRect(x: 0.1, y: 0.15, width: 0.5, height: 0.05)),
            ],
            recognition: recognition)

        XCTAssertEqual(result.pageNumber, 7)
        XCTAssertEqual(result.ocrText, "image middle")
        XCTAssertEqual(result.combinedText, "native top\nimage middle\nnative bottom")
        XCTAssertTrue(result.usedGeometricReadingOrder)
    }

    func testDedupIsSequenceBasedAndPreservesDistinctFacts() {
        let native = PDFOCRReader.normalizedTokens("Quarterly total 100 units. Existing native phrase.")
        XCTAssertNil(PDFOCRReader.novelOCRText("existing native phrase", nativeTokens: native))
        XCTAssertEqual(PDFOCRReader.novelOCRText("total 200", nativeTokens: native), "total 200",
                       "Shared vocabulary must not erase a distinct numeric fact")
        XCTAssertEqual(PDFOCRReader.novelOCRText("existing native phrase novel raster fact",
                                                nativeTokens: native),
                       "novel raster fact",
                       "Exact duplicate prefix is trimmed without losing the raster-only suffix")
    }

    // MARK: - Fixture helpers

    private struct ImageLine {
        let text: String
        let y: CGFloat

        init(_ text: String, y: CGFloat) {
            self.text = text
            self.y = y
        }
    }

    private struct PageFixture {
        let native: [String]
        let images: [ImageLine]
        let cropBox: CGRect?

        init(native: [String] = [], images: [ImageLine] = [], cropBox: CGRect? = nil) {
            self.native = native
            self.images = images
            self.cropBox = cropBox
        }
    }

    private func writePDF(_ pages: [PageFixture], to url: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw FixtureError.couldNotCreatePDF
        }
        for fixture in pages {
            var pageInfo: [String: Any] = [kCGPDFContextMediaBox as String: mediaBox]
            if let cropBox = fixture.cropBox {
                pageInfo[kCGPDFContextCropBox as String] = cropBox
            }
            context.beginPDFPage(pageInfo as CFDictionary)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(mediaBox)

            var nativeY: CGFloat = fixture.cropBox.map { $0.maxY - 55 } ?? 700
            for line in fixture.native {
                drawText(line, at: CGPoint(x: fixture.cropBox.map { $0.minX + 30 } ?? 60, y: nativeY),
                         fontSize: 28, in: context)
                nativeY -= 50
            }
            for imageLine in fixture.images {
                let image = try renderImageText(imageLine.text)
                let originX = fixture.cropBox.map { $0.minX + 25 } ?? 55
                context.draw(image, in: CGRect(x: originX, y: imageLine.y, width: 500, height: 105))
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    private func renderImageText(_ text: String) throws -> CGImage {
        let width = 1200
        let height = 250
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw FixtureError.couldNotCreateImage
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        drawText(text, at: CGPoint(x: 45, y: 85), fontSize: 66, in: context)
        guard let image = context.makeImage() else { throw FixtureError.couldNotCreateImage }
        return image
    }

    private func drawText(_ text: String, at point: CGPoint, fontSize: CGFloat, in context: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil),
            .foregroundColor: CGColor(gray: 0, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text,
                                                                        attributes: attributes))
        context.saveGState()
        context.textPosition = point
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private func recognition(_ text: String) -> PDFPageOCRRecognition {
        PDFPageOCRRecognition(observations: [observation(text, x: 0.1, y: 0.5)])
    }

    private func observation(_ text: String, x: Double, y: Double) -> PDFOCRObservation {
        PDFOCRObservation(text: text,
                          boundingBox: PDFOCRBoundingBox(x: x, y: y, width: 0.7, height: 0.08))
    }

    private func normalized(_ text: String) -> String {
        PDFOCRReader.normalizedTokens(text).joined(separator: " ")
    }

    private func assertContains(_ text: String,
                                words: [String],
                                file: StaticString = #filePath,
                                line: UInt = #line) {
        let value = normalized(text)
        for word in words {
            XCTAssertTrue(value.contains(word.lowercased()),
                          "Expected OCR text to contain \(word); got: \(text)", file: file, line: line)
        }
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var remaining = haystack[...]
        while let range = remaining.range(of: needle) {
            count += 1
            remaining = remaining[range.upperBound...]
        }
        return count
    }

    private enum FixtureError: Error {
        case couldNotCreatePDF
        case couldNotCreateImage
        case syntheticRecognitionFailure
    }

    private final class CountingPDFRecognizer: PDFPageTextRecognizer, @unchecked Sendable {
        private let lock = NSLock()
        private let result: PDFPageOCRRecognition
        private let failuresBeforeSuccess: Int
        private var attempts = 0

        init(result: PDFPageOCRRecognition, failuresBeforeSuccess: Int = 0) {
            self.result = result
            self.failuresBeforeSuccess = failuresBeforeSuccess
        }

        var attemptCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return attempts
        }

        func recognizeText(in pageImage: CGImage) throws -> PDFPageOCRRecognition {
            lock.lock()
            attempts += 1
            let shouldFail = attempts <= failuresBeforeSuccess
            lock.unlock()
            if shouldFail { throw FixtureError.syntheticRecognitionFailure }
            return result
        }
    }

    private final class ConcurrencyTrackingRecognizer: PDFPageTextRecognizer, @unchecked Sendable {
        private let lock = NSLock()
        private var attempts = 0
        private var active = 0
        private var maximumActive = 0

        var attemptCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return attempts
        }

        var maximumActiveCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return maximumActive
        }

        func recognizeText(in pageImage: CGImage) throws -> PDFPageOCRRecognition {
            lock.lock()
            attempts += 1
            active += 1
            maximumActive = max(maximumActive, active)
            lock.unlock()
            Thread.sleep(forTimeInterval: 0.05)
            lock.lock()
            active -= 1
            lock.unlock()
            return PDFPageOCRRecognition(observations: [])
        }
    }
}
