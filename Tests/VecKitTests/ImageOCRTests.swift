import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import VecKit

/// Tests for the image-OCR engine (`ImageOCR`), the content-addressed cache
/// (`ImageOCRCache`), and the `TextExtractor` image routing.
///
/// The engine's format table, reading-order grouping, ImageIO downsampling
/// and orientation reading, and the entire cache are tested deterministically
/// without Vision (synthetic boxes, injected recognizers, direct ImageIO).
/// A small number of end-to-end tests render real PNG/JPEG/GIF fixtures with
/// CoreText and assert that Vision recovers the drawn words — these are the
/// only Vision-dependent tests and, per the OCR runtime contract, they assert
/// rather than skip so an engine regression cannot hide.
final class ImageOCRTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("image-ocr-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try super.tearDownWithError()
    }

    // MARK: - Supported extensions (format table)

    func testSupportedExtensionsAreTheFrozenRasterSet() {
        let fixed: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "heic", "tiff", "tif", "bmp"]
        XCTAssertTrue(ImageOCR.supportedExtensions.isSuperset(of: fixed),
                      "Every frozen raster extension must be supported")
        // Vector and non-frozen raster extensions must never be OCR'd.
        for rejected in ["svg", "svgz", "heif", "pdf", "txt", "md", "vtt"] {
            XCTAssertFalse(ImageOCR.supportedExtensions.contains(rejected),
                           "\(rejected) must not be a supported OCR extension")
        }
        // AVIF is present exactly when the running ImageIO advertises it.
        XCTAssertEqual(ImageOCR.supportedExtensions.contains("avif"),
                       ImageOCR.imageIOAdvertisesAVIF(),
                       "avif support must track runtime ImageIO advertisement")
        // Beyond the frozen set and the optional avif, nothing else leaks in.
        XCTAssertTrue(ImageOCR.supportedExtensions.subtracting(fixed).subtracting(["avif"]).isEmpty,
                      "Only the frozen set (+avif) may be supported")
    }

    // MARK: - Reading-order grouping (deterministic, no Vision)

    func testReadingOrderSortsTopToBottomThenLeftToRight() {
        // Vision coords: origin bottom-left, y up. Fed out of reading order.
        let bottom = (text: "second", box: CGRect(x: 0.1, y: 0.10, width: 0.3, height: 0.05))
        let top = (text: "first", box: CGRect(x: 0.1, y: 0.80, width: 0.3, height: 0.05))
        let result = ImageOCR.readingOrder(from: [bottom, top])
        XCTAssertEqual(result.lines, ["first", "second"])
        XCTAssertEqual(result.text, "first\n\nsecond")
    }

    func testReadingOrderMergesSameLineFragmentsLeftToRight() {
        // Two fragments share a vertical band; the right one is fed first.
        let right = (text: "world", box: CGRect(x: 0.60, y: 0.80, width: 0.3, height: 0.05))
        let left = (text: "hello", box: CGRect(x: 0.10, y: 0.80, width: 0.3, height: 0.05))
        let result = ImageOCR.readingOrder(from: [right, left])
        XCTAssertEqual(result.lines, ["hello world"], "Same-line fragments join left-to-right")
        XCTAssertEqual(result.paragraphs, ["hello world"])
    }

    func testReadingOrderGroupsParagraphsByVerticalGap() {
        // Two tightly-spaced lines, then a large gap, then a third line.
        let items: [(text: String, box: CGRect)] = [
            (text: "p1 line1", box: CGRect(x: 0.1, y: 0.85, width: 0.3, height: 0.05)),
            (text: "p1 line2", box: CGRect(x: 0.1, y: 0.78, width: 0.3, height: 0.05)),
            (text: "p2 line1", box: CGRect(x: 0.1, y: 0.40, width: 0.3, height: 0.05)),
        ]
        let result = ImageOCR.readingOrder(from: items)
        XCTAssertEqual(result.lines, ["p1 line1", "p1 line2", "p2 line1"])
        XCTAssertEqual(result.paragraphs, ["p1 line1 p1 line2", "p2 line1"],
                       "A large vertical gap starts a new paragraph")
        XCTAssertTrue(result.text.contains("\n\n"), "Paragraphs are separated by a blank line")
    }

    func testReadingOrderIgnoresEmptyFragmentsAndBlankIsEmpty() {
        XCTAssertEqual(ImageOCR.readingOrder(from: []), ImageOCRResult(text: "", lines: [], paragraphs: []))
        let onlyBlanks: [(text: String, box: CGRect)] = [
            (text: "   ", box: CGRect(x: 0.1, y: 0.8, width: 0.1, height: 0.05)),
            (text: "", box: CGRect(x: 0.1, y: 0.7, width: 0.1, height: 0.05)),
        ]
        XCTAssertTrue(ImageOCR.readingOrder(from: onlyBlanks).isBlank)
    }

    // MARK: - ImageIO: bounded downsampling + orientation (deterministic)

    func testLoadFirstFrameDownsamplesOversizedImage() throws {
        let url = tempDir.appendingPathComponent("oversized.png")
        let cg = try renderCGImage(lines: ["x"], width: 6000, height: 1000, fontSize: 200)
        XCTAssertGreaterThan(cg.width, ImageOCR.maxPixelDimension, "Fixture must exceed the cap")
        try writeImage(cg, to: url, format: .png)

        let (decoded, _) = try ImageOCR.loadFirstFrame(from: url)
        XCTAssertLessThanOrEqual(max(decoded.width, decoded.height), ImageOCR.maxPixelDimension,
                                 "Oversized images are downsampled to the cap")
    }

    func testLoadFirstFrameDoesNotUpscaleSmallImage() throws {
        let url = tempDir.appendingPathComponent("small.png")
        let cg = try renderCGImage(lines: ["x"], width: 300, height: 120, fontSize: 40)
        try writeImage(cg, to: url, format: .png)

        let (decoded, _) = try ImageOCR.loadFirstFrame(from: url)
        XCTAssertEqual(decoded.width, 300, "A sub-cap image is not upscaled")
        XCTAssertEqual(decoded.height, 120)
    }

    func testLoadFirstFrameReadsOrientation() throws {
        let url = tempDir.appendingPathComponent("rotated.jpg")
        let cg = try renderCGImage(lines: ["x"], width: 200, height: 100, fontSize: 40)
        // EXIF orientation 6 == rotate 90° CW == CGImagePropertyOrientation.right.
        try writeImage(cg, to: url, format: .jpeg, orientation: 6)

        let (_, orientation) = try ImageOCR.loadFirstFrame(from: url)
        XCTAssertEqual(orientation, .right, "Orientation tag is read from the frame properties")
    }

    func testLoadFirstFrameThrowsOnUndecodableBytes() throws {
        let url = tempDir.appendingPathComponent("broken.png")
        try Data("not an image".utf8).write(to: url)
        XCTAssertThrowsError(try ImageOCR.loadFirstFrame(from: url)) { error in
            XCTAssertEqual(error as? ImageOCRError, .undecodable(url))
        }
    }

    // MARK: - End-to-end Vision recognition (assert-or-fail on native runtime)

    func testRenderedPNGBaselineRecognizesWords() throws {
        let url = tempDir.appendingPathComponent("baseline.png")
        try writeImage(try renderCGImage(lines: ["Hello World"], width: 800, height: 200, fontSize: 64),
                       to: url, format: .png)
        let result = try ImageOCR().recognizeText(in: url)
        assertRecognizes(result, expected: ["Hello", "World"], context: "PNG baseline")
    }

    func testRenderedJPEGBaselineRecognizesWords() throws {
        let url = tempDir.appendingPathComponent("baseline.jpg")
        try writeImage(try renderCGImage(lines: ["Vector Search"], width: 800, height: 200, fontSize: 64),
                       to: url, format: .jpeg)
        let result = try ImageOCR().recognizeText(in: url)
        assertRecognizes(result, expected: ["Vector", "Search"], context: "JPEG baseline")
    }

    func testRenderedBlankPNGAndJPEGProduceNoTextOrChunks() throws {
        let blank = try renderCGImage(lines: [], width: 800, height: 200, fontSize: 64)
        let extractor = TextExtractor(
            splitter: RecursiveCharacterSplitter(chunkSize: 200, chunkOverlap: 0),
            textExtraction: .imageOCRV1)
        for (ext, format) in [("png", UTType.png), ("jpg", UTType.jpeg)] {
            let url = tempDir.appendingPathComponent("blank.\(ext)")
            try writeImage(blank, to: url, format: format)
            let result = try ImageOCR().recognizeText(in: url)
            XCTAssertTrue(result.text.isEmpty, "Blank \(ext) must have no recognized text")
            XCTAssertTrue(result.lines.isEmpty)
            XCTAssertTrue(result.paragraphs.isEmpty)
            let info = FileInfo(relativePath: url.lastPathComponent, url: url,
                                modificationDate: Date(), fileExtension: ext)
            XCTAssertTrue(try extractor.extract(from: info).isEmpty,
                          "A real blank \(ext) must not generate image chunks")
        }
    }

    func testOversizedImageDownsampleStillRecognizesLegibleText() throws {
        // Native width 6000 > 4096, so the frame is downsampled before OCR.
        // Text drawn at 90pt scales to ~61px after the 4096 cap — well within
        // legibility. This proves the downsample path preserves text that
        // remains large after scaling. It does NOT claim arbitrarily small
        // text survives: sub-~16px-post-scale text can be lost, which is the
        // documented limitation of `maxPixelDimension`.
        let url = tempDir.appendingPathComponent("oversized-ocr.png")
        try writeImage(try renderCGImage(lines: ["Big Text"], width: 6000, height: 1000, fontSize: 90),
                       to: url, format: .png)
        let result = try ImageOCR().recognizeText(in: url)
        assertRecognizes(result, expected: ["Big", "Text"], context: "oversized downsample")
    }

    func testAnimatedGIFOCRsFirstFrameOnly() throws {
        let url = tempDir.appendingPathComponent("two-frame.gif")
        // Distinct single words so tokenization can't smear one into the other.
        let frame0 = try renderCGImage(lines: ["Alpha"], width: 700, height: 200, fontSize: 72)
        let frame1 = try renderCGImage(lines: ["Omega"], width: 700, height: 200, fontSize: 72)
        try writeGIF([frame0, frame1], to: url)

        // Sanity: the fixture really has two frames.
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 2)

        let result = try ImageOCR().recognizeText(in: url)
        assertRecognizes(result, expected: ["Alpha"], context: "GIF first frame")
        XCTAssertFalse(result.text.lowercased().contains("omega"),
                       "Only the first frame is OCR'd")
    }

    // MARK: - Cache: accounting, blank caching, disk reuse, version, errors

    func testCacheMissThenResidentHitInvokesRecognizerOnce() throws {
        let file = try writeDummyImage(named: "a.png")
        let recognizer = CountingRecognizer(result: .words("cached text"))
        let cache = ImageOCRCache(directory: tempDir, recognizer: recognizer)

        let first = try cache.recognizeText(in: file)
        let second = try cache.recognizeText(in: file)

        XCTAssertEqual(first, second)
        XCTAssertEqual(recognizer.callCount, 1, "Second call is served from cache")
        XCTAssertEqual(cache.statistics, ImageOCRCacheStatistics(hits: 1, misses: 1, ocrCalls: 1))
    }

    func testCacheStoresBlankResultsToAvoidReOCR() throws {
        let file = try writeDummyImage(named: "blank.png")
        let recognizer = CountingRecognizer(result: ImageOCRResult(text: "", lines: [], paragraphs: []))
        let cache = ImageOCRCache(directory: tempDir, recognizer: recognizer)

        let first = try cache.recognizeText(in: file)
        let second = try cache.recognizeText(in: file)

        XCTAssertTrue(first.isBlank)
        XCTAssertTrue(second.isBlank)
        XCTAssertEqual(recognizer.callCount, 1, "A blank result is cached, not recomputed")
        XCTAssertEqual(cache.statistics.hits, 1)
    }

    func testCacheContentAddressedAcrossDifferentPaths() throws {
        let bytes = Data((0..<4096).map { UInt8($0 & 0xFF) })
        let pathA = tempDir.appendingPathComponent("path-a.png")
        let pathB = tempDir.appendingPathComponent("path-b.png")
        try bytes.write(to: pathA)
        try bytes.write(to: pathB)

        let recognizer = CountingRecognizer(result: .words("same bytes"))
        let cache = ImageOCRCache(directory: tempDir, recognizer: recognizer)

        _ = try cache.recognizeText(in: pathA)
        _ = try cache.recognizeText(in: pathB)
        XCTAssertEqual(recognizer.callCount, 1, "Identical bytes hit regardless of path")
    }

    func testDiskSidecarReusedByFreshCacheInstance() throws {
        let file = try writeDummyImage(named: "persist.png")
        let expected = ImageOCRResult.words("persisted")

        let warmer = CountingRecognizer(result: expected)
        let firstCache = ImageOCRCache(directory: tempDir, recognizer: warmer)
        _ = try firstCache.recognizeText(in: file)
        XCTAssertEqual(warmer.callCount, 1)

        // A fresh instance (empty resident LRU) over the SAME directory reads
        // the on-disk sidecar — the fresh-process warm-pass scenario.
        let neverCalled = CountingRecognizer(result: .words("should not run"))
        let secondCache = ImageOCRCache(directory: tempDir, recognizer: neverCalled)
        let served = try secondCache.recognizeText(in: file)

        XCTAssertEqual(served, expected)
        XCTAssertEqual(neverCalled.callCount, 0, "Warm pass is served from the disk sidecar")
        XCTAssertEqual(secondCache.statistics, ImageOCRCacheStatistics(hits: 1, misses: 0, ocrCalls: 0))
    }

    func testCacheVersionMismatchForcesRecompute() throws {
        let file = try writeDummyImage(named: "versioned.png")

        let v1Recognizer = CountingRecognizer(result: .words("v1"))
        let v1 = ImageOCRCache(directory: tempDir, recognizer: v1Recognizer, version: 1)
        _ = try v1.recognizeText(in: file)

        // A different version must not read the v1 sidecar.
        let v2Recognizer = CountingRecognizer(result: .words("v2"))
        let v2 = ImageOCRCache(directory: tempDir, recognizer: v2Recognizer, version: 2)
        let served = try v2.recognizeText(in: file)

        XCTAssertEqual(served.text, "v2")
        XCTAssertEqual(v2Recognizer.callCount, 1, "Version mismatch is a miss")
        XCTAssertEqual(v2.statistics.misses, 1)
    }

    func testCacheTransientErrorPropagatesAndIsNotCached() throws {
        let file = try writeDummyImage(named: "transient.png")
        // Throws on the first call, succeeds on the second.
        let recognizer = CountingRecognizer(result: .words("recovered"), throwFirst: 1)
        let cache = ImageOCRCache(directory: tempDir, recognizer: recognizer)

        XCTAssertThrowsError(try cache.recognizeText(in: file), "Transient error propagates")

        let recovered = try cache.recognizeText(in: file)
        XCTAssertEqual(recovered.text, "recovered")
        XCTAssertEqual(recognizer.callCount, 2, "The failed attempt was not cached")
        XCTAssertEqual(cache.statistics, ImageOCRCacheStatistics(hits: 0, misses: 2, ocrCalls: 1),
                       "misses count both attempts; ocrCalls counts only the completed one")
    }

    func testCacheEvictsLeastRecentlyUsedResultsAtResidentLimit() throws {
        let files = try ["a.png", "b.png", "c.png"].map { try writeDummyImage(named: $0) }
        let recognizer = CountingRecognizer(result: .words("bounded cache"))
        let cache = ImageOCRCache(directory: tempDir, recognizer: recognizer, maxResidentEntries: 2)
        _ = try cache.recognizeText(in: files[0])
        _ = try cache.recognizeText(in: files[1])
        _ = try cache.recognizeText(in: files[0]) // A becomes most recent.
        _ = try cache.recognizeText(in: files[2]) // B must be evicted.
        XCTAssertEqual(recognizer.callCount, 3)

        // Remove sidecars so a hit can only come from the resident tier.
        for file in files.prefix(2) {
            let hash = try ImageOCRCache.contentKey(for: file)
            try FileManager.default.removeItem(at: tempDir.appendingPathComponent("image-ocr-cache/\(hash).json"))
        }
        _ = try cache.recognizeText(in: files[0])
        XCTAssertEqual(recognizer.callCount, 3, "Recently touched A remains resident")
        _ = try cache.recognizeText(in: files[1])
        XCTAssertEqual(recognizer.callCount, 4, "Evicted B with no sidecar must be recomputed")
        _ = try cache.recognizeText(in: files[2])
        XCTAssertEqual(recognizer.callCount, 4, "Evicted C is recovered from its disk sidecar")
    }

    func testCacheSingleFlightsConcurrentDuplicateColdCalls() throws {
        let file = try writeDummyImage(named: "concurrent.png")
        let releaseRecognition = DispatchSemaphore(value: 0)
        let recognizer = CountingRecognizer(result: .words("single flight"), onRecognize: { _ in
            releaseRecognition.wait()
        })
        let cache = ImageOCRCache(directory: tempDir, recognizer: recognizer)

        let workers = 8
        let group = DispatchGroup()
        for _ in 0..<workers {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                _ = try? cache.recognizeText(in: file)
            }
        }
        // Hold recognition until every other request reaches the in-flight
        // wait. Serial execution cannot satisfy this assertion.
        let deadline = Date().addingTimeInterval(3)
        while cache.statistics.coalescedRequests < workers - 1 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertEqual(cache.statistics.coalescedRequests, workers - 1)
        // Release all permits even if a regression invoked OCR N times.
        for _ in 0..<workers { releaseRecognition.signal() }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(recognizer.callCount, 1)
        XCTAssertEqual(cache.statistics, ImageOCRCacheStatistics(
            hits: workers - 1, misses: 1, ocrCalls: 1, coalescedRequests: workers - 1))
    }

    // MARK: - TextExtractor image routing

    func testExtractorRunsNoOCRWithoutImageMode() throws {
        let file = try imageFileInfo(named: "no-ocr.png")
        let recognizer = CountingRecognizer(result: .words("should not run"))
        let extractor = TextExtractor(splitter: RecursiveCharacterSplitter(chunkSize: 40, chunkOverlap: 0),
                                      textExtraction: .raw,
                                      ocrRecognizer: recognizer)

        let result = try extractor.extract(from: file)
        XCTAssertTrue(result.chunks.isEmpty, "Raw mode yields no image chunks")
        XCTAssertEqual(recognizer.callCount, 0, "The recognizer is never invoked without the OCR mode")
        XCTAssertFalse(extractor.isImageOCRFile(file))
    }

    func testExtractorImageOCRProducesImageChunksWithoutLineLocations() throws {
        let file = try imageFileInfo(named: "ocr.png")
        let long = "First paragraph sentence one. Second sentence continues here.\n\nSecond paragraph body text that is clearly long enough to force the splitter to emit sub-chunks."
        let recognizer = CountingRecognizer(result: ImageOCRResult(
            text: long, lines: long.components(separatedBy: "\n\n"), paragraphs: long.components(separatedBy: "\n\n")))
        let extractor = TextExtractor(splitter: RecursiveCharacterSplitter(chunkSize: 50, chunkOverlap: 0),
                                      textExtraction: .imageOCRV1,
                                      ocrRecognizer: recognizer)

        XCTAssertTrue(extractor.isImageOCRFile(file))
        let result = try extractor.extract(from: file)

        XCTAssertNil(result.linePageCount, "Images have no line/page count")
        XCTAssertGreaterThan(result.chunks.count, 1, "Long OCR text is sub-chunked")
        XCTAssertEqual(result.chunks.first?.type, .image)
        XCTAssertEqual(result.chunks.first?.text, long, "The whole-image chunk holds the full OCR text")
        for chunk in result.chunks {
            XCTAssertEqual(chunk.type, .image, "Splitter output retains the image chunk type")
            XCTAssertNil(chunk.lineStart, "Image chunks carry no fake source line locations")
            XCTAssertNil(chunk.lineEnd)
            XCTAssertNil(chunk.pageNumber)
        }
        XCTAssertEqual(recognizer.callCount, 1)
    }

    func testExtractorBlankOCRYieldsNoChunks() throws {
        let file = try imageFileInfo(named: "blank-ocr.png")
        let recognizer = CountingRecognizer(result: ImageOCRResult(text: "", lines: [], paragraphs: []))
        let extractor = TextExtractor(splitter: RecursiveCharacterSplitter(chunkSize: 50, chunkOverlap: 0),
                                      textExtraction: .imageOCRV1,
                                      ocrRecognizer: recognizer)
        XCTAssertTrue(try extractor.extract(from: file).chunks.isEmpty)
        XCTAssertEqual(recognizer.callCount, 1)
    }

    func testExtractorTransientOCRErrorPropagates() throws {
        let file = try imageFileInfo(named: "err-ocr.png")
        let recognizer = CountingRecognizer(result: .words("never"), throwFirst: 1)
        let extractor = TextExtractor(splitter: RecursiveCharacterSplitter(chunkSize: 50, chunkOverlap: 0),
                                      textExtraction: .imageOCRV1,
                                      ocrRecognizer: recognizer)
        XCTAssertThrowsError(try extractor.extract(from: file),
                             "A transient OCR error propagates so the pipeline retries")
    }

    func testExtractorExposesCacheStatistics() throws {
        let file = try writeDummyImage(named: "stats.png")
        let info = FileInfo(relativePath: "stats.png", url: file,
                            modificationDate: Date(), fileExtension: "png")
        let recognizer = CountingRecognizer(result: .words("stat text"))
        let extractor = TextExtractor(splitter: RecursiveCharacterSplitter(chunkSize: 200, chunkOverlap: 0),
                                      textExtraction: .imageOCRV1,
                                      ocrRecognizer: recognizer,
                                      ocrCacheDirectory: tempDir)

        _ = try extractor.extract(from: info)
        _ = try extractor.extract(from: info)

        let stats = try XCTUnwrap(extractor.ocrCacheStatistics)
        XCTAssertEqual(stats, ImageOCRCacheStatistics(hits: 1, misses: 1, ocrCalls: 1))
        XCTAssertEqual(recognizer.callCount, 1, "The cache serves the second extraction")
    }

    func testExtractorWithoutCacheDirectoryHasNilStatistics() {
        let extractor = TextExtractor(splitter: RecursiveCharacterSplitter(chunkSize: 50, chunkOverlap: 0),
                                      textExtraction: .imageOCRV1,
                                      ocrRecognizer: CountingRecognizer(result: .words("x")))
        XCTAssertNil(extractor.ocrCacheStatistics)
    }

    func testIsImageOCRFileIsModeAndExtensionAware() {
        func info(_ ext: String) -> FileInfo {
            FileInfo(relativePath: "f.\(ext)", url: tempDir.appendingPathComponent("f.\(ext)"),
                     modificationDate: Date(), fileExtension: ext)
        }
        let splitter = RecursiveCharacterSplitter(chunkSize: 50, chunkOverlap: 0)
        let recognizer = CountingRecognizer(result: .words("x"))

        let raw = TextExtractor(splitter: splitter, textExtraction: .raw, ocrRecognizer: recognizer)
        XCTAssertFalse(raw.isImageOCRFile(info("png")), "Raw mode OCRs nothing")

        let ocr = TextExtractor(splitter: splitter, textExtraction: .imageOCRV1, ocrRecognizer: recognizer)
        XCTAssertTrue(ocr.isImageOCRFile(info("png")))
        XCTAssertTrue(ocr.isImageOCRFile(info("PNG")), "Extension match is case-insensitive")
        XCTAssertFalse(ocr.isImageOCRFile(info("txt")), "Non-image extensions are excluded")
        XCTAssertFalse(ocr.isImageOCRFile(info("svg")), "SVG is never an OCR file")
    }

    // MARK: - Combined-mode normalization (mode predicates, not equality)

    func testCombinedOCRModeStillNormalizesMarkdown() throws {
        let source = "See [Anthropic](https://anthropic.example) for details."
        let file = try textFileInfo(named: "doc.md", content: source)
        let recognizer = CountingRecognizer(result: .words("unused"))

        // Markdown + image OCR: the .md file must still be markdown-normalized,
        // so the link URL is dropped. Equality checks against .markdownV1 would
        // have skipped normalization under this combined mode.
        let combined = TextExtractor(splitter: RecursiveCharacterSplitter(chunkSize: 500, chunkOverlap: 0),
                                     textExtraction: .markdownV1ImageOCRV1, ocrRecognizer: recognizer)
        let whole = try XCTUnwrap(try combined.extract(from: file).chunks.first)
        XCTAssertTrue(whole.text.contains("Anthropic"), "Link text is kept")
        XCTAssertFalse(whole.text.contains("https://anthropic.example"), "Markdown normalization drops the URL")

        // A mode that includes OCR but NOT markdown leaves the .md raw.
        let ocrOnly = TextExtractor(splitter: RecursiveCharacterSplitter(chunkSize: 500, chunkOverlap: 0),
                                    textExtraction: .imageOCRV1, ocrRecognizer: recognizer)
        let rawWhole = try XCTUnwrap(try ocrOnly.extract(from: file).chunks.first)
        XCTAssertTrue(rawWhole.text.contains("https://anthropic.example"), "Without markdown mode, content is raw")
        XCTAssertEqual(recognizer.callCount, 0, "Text files never invoke the OCR recognizer")
    }

    func testCombinedOCRModeStillNormalizesVTT() throws {
        let source = "WEBVTT\n\n00:00:01.000 --> 00:00:03.000\nHello from the transcript.\n"
        let file = try textFileInfo(named: "clip.vtt", content: source)
        let recognizer = CountingRecognizer(result: .words("unused"))

        // VTT + image OCR: the .vtt file must still be VTT-normalized, dropping
        // the cue timestamps and the WEBVTT header.
        let combined = TextExtractor(splitter: RecursiveCharacterSplitter(chunkSize: 500, chunkOverlap: 0),
                                     textExtraction: .vttV1ImageOCRV1, ocrRecognizer: recognizer)
        let whole = try XCTUnwrap(try combined.extract(from: file).chunks.first)
        XCTAssertTrue(whole.text.contains("Hello from the transcript"), "Cue text is kept")
        XCTAssertFalse(whole.text.contains("-->"), "VTT normalization drops timestamps")
        XCTAssertFalse(whole.text.contains("WEBVTT"), "VTT normalization drops the header")

        // OCR-only mode leaves the .vtt raw (timestamps present).
        let ocrOnly = TextExtractor(splitter: RecursiveCharacterSplitter(chunkSize: 500, chunkOverlap: 0),
                                    textExtraction: .imageOCRV1, ocrRecognizer: recognizer)
        let rawWhole = try XCTUnwrap(try ocrOnly.extract(from: file).chunks.first)
        XCTAssertTrue(rawWhole.text.contains("-->"), "Without VTT mode, content is raw")
        XCTAssertEqual(recognizer.callCount, 0)
    }

    // MARK: - Direct-insert-style extraction: image-like files never leak as text

    func testExtractorSkipsSVGRatherThanIndexingItsXML() throws {
        // SVG conforms to both .image and .text; it must be skipped, not read
        // as XML text, under every mode (matching the scanner + insert path).
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\"><text>diagram label</text></svg>"
        let file = try textFileInfo(named: "diagram.svg", content: svg)
        let recognizer = CountingRecognizer(result: .words("unused"))

        for mode: TextExtractionMode in [.raw, .imageOCRV1, .markdownV1VttV1ImageOCRV1] {
            let extractor = TextExtractor(splitter: RecursiveCharacterSplitter(chunkSize: 100, chunkOverlap: 0),
                                          textExtraction: mode, ocrRecognizer: recognizer)
            let result = try extractor.extract(from: file)
            XCTAssertTrue(result.chunks.isEmpty, "SVG yields no chunks under \(mode.rawValue)")
        }
        XCTAssertEqual(recognizer.callCount, 0, "SVG is never OCR'd")
    }

    func testExtractorSkipsSVGZ() throws {
        // SVGZ has no registered UTType, so it relies on the extension mirror.
        let file = try textFileInfo(named: "diagram.svgz", content: "not really gzipped, but text-like")
        let extractor = TextExtractor(splitter: RecursiveCharacterSplitter(chunkSize: 100, chunkOverlap: 0),
                                      textExtraction: .imageOCRV1, ocrRecognizer: CountingRecognizer(result: .words("x")))
        XCTAssertTrue(try extractor.extract(from: file).chunks.isEmpty, "SVGZ is skipped, not read as text")
    }

    func testExtractorSkipsUnsupportedRasterUnderOCRMode() throws {
        // HEIF is an image but not in the frozen supported set; under an OCR
        // mode it must be skipped (empty) and never reach the recognizer.
        let file = try imageFileInfo(named: "photo.heif")
        let recognizer = CountingRecognizer(result: .words("should not run"))
        let extractor = TextExtractor(splitter: RecursiveCharacterSplitter(chunkSize: 100, chunkOverlap: 0),
                                      textExtraction: .imageOCRV1, ocrRecognizer: recognizer)
        XCTAssertTrue(try extractor.extract(from: file).chunks.isEmpty)
        XCTAssertEqual(recognizer.callCount, 0, "Unsupported raster types are not OCR'd")
        XCTAssertFalse(extractor.isImageOCRFile(file))
    }

    // MARK: - Cache TOCTOU: source replaced during OCR must not poison the cache

    func testCacheDoesNotPersistWhenSourceReplacedDuringOCR() throws {
        let url = tempDir.appendingPathComponent("swapped.png")
        try Data("original bytes A".utf8).write(to: url)

        // The recognizer replaces the file with different bytes mid-OCR, so the
        // result describes content that no longer matches the claimed hash.
        let poisoning = CountingRecognizer(result: .words("text for replaced bytes"), onRecognize: { swapURL in
            try? Data("different bytes B".utf8).write(to: swapURL)
        })
        let cache1 = ImageOCRCache(directory: tempDir, recognizer: poisoning)
        _ = try cache1.recognizeText(in: url)
        XCTAssertEqual(poisoning.callCount, 1)

        // Restore the original bytes and read through a fresh cache. If the
        // first cache had (wrongly) persisted under the original hash, this
        // would hit the poisoned sidecar and never call the recognizer.
        try Data("original bytes A".utf8).write(to: url)
        let clean = CountingRecognizer(result: .words("correct text for A"))
        let cache2 = ImageOCRCache(directory: tempDir, recognizer: clean)
        let served = try cache2.recognizeText(in: url)

        XCTAssertEqual(served.text, "correct text for A")
        XCTAssertEqual(clean.callCount, 1, "Original content must be re-recognized, not served from a poisoned entry")
    }

    // MARK: - Reading order is permutation-invariant

    func testReadingOrderIsPermutationInvariant() {
        let fragments: [(text: String, box: CGRect)] = [
            ("Hello", CGRect(x: 0.10, y: 0.85, width: 0.20, height: 0.05)),
            ("World", CGRect(x: 0.45, y: 0.85, width: 0.20, height: 0.05)),
            ("Second", CGRect(x: 0.10, y: 0.78, width: 0.30, height: 0.05)),
            ("New", CGRect(x: 0.10, y: 0.40, width: 0.20, height: 0.05)),
            ("Paragraph", CGRect(x: 0.35, y: 0.40, width: 0.30, height: 0.05)),
        ]
        let expected = ImageOCRResult(
            text: "Hello World Second\n\nNew Paragraph",
            lines: ["Hello World", "Second", "New Paragraph"],
            paragraphs: ["Hello World Second", "New Paragraph"])

        var permutationCount = 0
        permutations(of: fragments) { ordering in
            permutationCount += 1
            XCTAssertEqual(ImageOCR.readingOrder(from: ordering), expected,
                           "Reading order must be independent of input order")
        }
        XCTAssertEqual(permutationCount, 120, "All 5! orderings exercised")
    }

    /// Invokes `body` once per distinct permutation of `items` (Heap's
    /// algorithm): `k - 1` swap-separated recursive calls, then one final call.
    private func permutations<T>(of items: [T], _ body: ([T]) -> Void) {
        var array = items
        func generate(_ k: Int) {
            if k <= 1 { body(array); return }
            for i in 0..<(k - 1) {
                generate(k - 1)
                if k.isMultiple(of: 2) {
                    array.swapAt(i, k - 1)
                } else {
                    array.swapAt(0, k - 1)
                }
            }
            generate(k - 1)
        }
        generate(array.count)
    }

    // MARK: - Fixtures & helpers

    /// Draws `lines` top-to-bottom in black Helvetica on a white background.
    private func renderCGImage(lines: [String], width: Int, height: Int, fontSize: CGFloat) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw TestError.contextCreationFailed
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))

        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let lineHeight = fontSize * 1.6
        // CGContext origin is bottom-left; place the first line near the top.
        var y = CGFloat(height) - lineHeight
        for line in lines {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1)
            ]
            let attributed = NSAttributedString(string: line, attributes: attributes)
            let ctLine = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: 24, y: y)
            CTLineDraw(ctLine, context)
            y -= lineHeight
        }
        guard let image = context.makeImage() else { throw TestError.imageRenderFailed }
        return image
    }

    private func writeImage(_ image: CGImage, to url: URL, format: UTType, orientation: UInt32? = nil) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, format.identifier as CFString, 1, nil) else {
            throw TestError.destinationCreationFailed
        }
        var properties: [CFString: Any] = [:]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw TestError.imageWriteFailed }
    }

    private func writeGIF(_ frames: [CGImage], to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
            throw TestError.destinationCreationFailed
        }
        let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]] as CFDictionary
        for frame in frames {
            CGImageDestinationAddImage(destination, frame, frameProperties)
        }
        guard CGImageDestinationFinalize(destination) else { throw TestError.imageWriteFailed }
    }

    /// A tiny non-image file — enough bytes to hash for cache tests that use a
    /// fake recognizer (the fake never decodes it).
    @discardableResult
    private func writeDummyImage(named name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data("dummy bytes for \(name)".utf8).write(to: url)
        return url
    }

    private func imageFileInfo(named name: String) throws -> FileInfo {
        let url = try writeDummyImage(named: name)
        let ext = (name as NSString).pathExtension.lowercased()
        return FileInfo(relativePath: name, url: url, modificationDate: Date(), fileExtension: ext)
    }

    /// Writes `content` to a real file and returns its `FileInfo` — used for
    /// the direct, insert-style `extract(from:)` tests.
    private func textFileInfo(named name: String, content: String) throws -> FileInfo {
        let url = tempDir.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        let ext = (name as NSString).pathExtension.lowercased()
        return FileInfo(relativePath: name, url: url, modificationDate: Date(), fileExtension: ext)
    }

    private func assertRecognizes(_ result: ImageOCRResult, expected: [String], context: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let lowered = result.text.lowercased()
        for word in expected {
            XCTAssertTrue(lowered.contains(word.lowercased()),
                          "\(context): expected OCR text to contain '\(word)', got '\(result.text)'",
                          file: file, line: line)
        }
    }

    private enum TestError: Error {
        case contextCreationFailed, imageRenderFailed, destinationCreationFailed, imageWriteFailed
    }
}

/// An injectable recognizer that counts calls, can delay to widen the
/// single-flight window, and can throw for the first N calls to simulate a
/// transient failure. Thread-safe.
private final class CountingRecognizer: ImageTextRecognizer, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let result: ImageOCRResult
    private let delay: TimeInterval
    private let throwFirst: Int
    /// Side effect run inside recognition, e.g. to replace the source file
    /// mid-OCR and exercise the cache's content-verification guard.
    private let onRecognize: (@Sendable (URL) -> Void)?

    init(result: ImageOCRResult, delay: TimeInterval = 0, throwFirst: Int = 0,
         onRecognize: (@Sendable (URL) -> Void)? = nil) {
        self.result = result
        self.delay = delay
        self.throwFirst = throwFirst
        self.onRecognize = onRecognize
    }

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return calls
    }

    func recognizeText(in imageURL: URL) throws -> ImageOCRResult {
        lock.lock()
        calls += 1
        let current = calls
        lock.unlock()

        if current <= throwFirst { throw FakeOCRError.transient }
        onRecognize?(imageURL)
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        return result
    }

    enum FakeOCRError: Error { case transient }
}

private extension ImageOCRResult {
    /// A single-line result whose text/lines/paragraphs are the given string.
    static func words(_ text: String) -> ImageOCRResult {
        ImageOCRResult(text: text, lines: [text], paragraphs: [text])
    }
}
