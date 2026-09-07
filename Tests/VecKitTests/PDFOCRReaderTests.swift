import CoreGraphics
import CoreText
import CryptoKit
import Darwin
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

    func testCacheSingleFlightsConcurrentSamePDFPage() throws {
        let url = tempDirectory.appendingPathComponent("single-flight.pdf")
        try writePDF([PageFixture()], to: url)
        let recognizer = ConcurrencyTrackingRecognizer()
        let reader = PDFOCRReader(recognizer: recognizer,
                                  cacheDirectory: tempDirectory.appendingPathComponent("single-flight-cache"),
                                  maximumConcurrentPageOperations: 2)
        let group = DispatchGroup()
        for _ in 0..<2 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                _ = try? reader.read(from: url)
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(recognizer.attemptCount, 1,
                       "Concurrent requests for identical PDF bytes/page/settings must share OCR")
        XCTAssertEqual(reader.cacheStatistics,
                       PDFOCRCacheStatistics(hits: 1, misses: 1, ocrCalls: 1,
                                             coalescedRequests: 1))
    }

    /// Bounded, opt-in cost measurement for the reader itself. The separate
    /// retrieval ranking waits for the manager's shared mode/pipeline wiring.
    /// This benchmark never downloads and fails (rather than silently
    /// continuing) on any page recognition error.
    func testPDFOCRThroughputBenchmark() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["VEC_E13_BENCHMARK"] == "1",
                          "Opt-in E13 reader cost benchmark")
        guard let outputPath = environment["VEC_E13_OUTPUT_DIRECTORY"], !outputPath.isEmpty else {
            throw BenchmarkError.missingOutputDirectory
        }
        let outputDirectory = URL(fileURLWithPath: outputPath, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: outputDirectory.path) else {
            throw BenchmarkError.outputAlreadyExists
        }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        // Six pages exercise native-only, raster-only, mixed, blank, duplicate
        // overlap, and another raster page. The generated bytes are frozen and
        // hashed before either timed pass; both passes read the same file.
        let sampleURL = outputDirectory.appendingPathComponent("frozen-bounded-sample.pdf")
        let duplicate = "COPPER LANTERN ARCHIVE"
        try writePDF([
            PageFixture(native: ["NATIVE ORCHARD SIGNAL"]),
            PageFixture(images: [ImageLine("RASTER NEBULA TOKEN", y: 330)]),
            PageFixture(native: ["NATIVE CEDAR HEADER"],
                        images: [ImageLine("RASTER QUARTZ DETAIL", y: 300)]),
            PageFixture(),
            PageFixture(native: [duplicate], images: [ImageLine(duplicate, y: 300)]),
            PageFixture(images: [ImageLine("BOUND SAMPLE FINAL", y: 330)]),
        ], to: sampleURL)
        let sampleData = try Data(contentsOf: sampleURL)
        let sampleHash = SHA256.hash(data: sampleData).map { String(format: "%02x", $0) }.joined()
        let cacheDirectory = outputDirectory.appendingPathComponent("cache", isDirectory: true)
        let settings = PDFOCRRenderSettings(dpi: 144, maxPixelDimension: 4096)

        let coldReader = PDFOCRReader(settings: settings, cacheDirectory: cacheDirectory,
                                      maximumConcurrentPageOperations: 1)
        let cold = try measuredPass(reader: coldReader, url: sampleURL, expectedPages: 6)
        let warmReader = PDFOCRReader(settings: settings, cacheDirectory: cacheDirectory,
                                      maximumConcurrentPageOperations: 1)
        let warm = try measuredPass(reader: warmReader, url: sampleURL, expectedPages: 6)
        XCTAssertEqual(cold.cache.ocrCalls, 6)
        XCTAssertEqual(cold.cache.misses, 6)
        XCTAssertEqual(warm.cache.hits, 6)
        XCTAssertEqual(warm.cache.ocrCalls, 0, "Warm pass must skip Vision entirely")

        let payload: [String: Any] = [
            "experiment": "E13-pdf-extraction",
            "scope": "reader-only bounded synthetic sample; not retrieval ranking",
            "synthetic_limitations": "CoreText fixtures are clean, high-contrast, English, and not representative of scans, handwriting, compression, or complex real layouts.",
            "sample": ["path": sampleURL.lastPathComponent, "bytes": sampleData.count,
                       "sha256": sampleHash, "pages": 6],
            "settings": ["pdf_ocr_version": PDFOCRReader.version,
                         "vision_request_revision": ImageOCR.requestRevision,
                         "dpi": settings.dpi,
                         "max_pixel_dimension": settings.maxPixelDimension,
                         "maximum_concurrent_page_operations": 1],
            "host": ["os": ProcessInfo.processInfo.operatingSystemVersionString,
                     "active_processor_count": ProcessInfo.processInfo.activeProcessorCount],
            "cold": cold.dictionary,
            "warm": warm.dictionary,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: outputDirectory.appendingPathComponent("reader-throughput.json"), options: .atomic)
        let command = "VEC_E13_BENCHMARK=1 VEC_E13_OUTPUT_DIRECTORY=\(outputDirectory.path) swift test --disable-sandbox --disable-swift-testing -c release --filter PDFOCRReaderTests/testPDFOCRThroughputBenchmark\n"
        try Data(command.utf8).write(to: outputDirectory.appendingPathComponent("execution-command.txt"),
                                     options: .atomic)
    }

    /// Production-path retrieval comparison. This is intentionally separate
    /// from the reader cost benchmark: it freezes seven generated PDF files
    /// and the committed rubric before running either arm, then drives the
    /// real scanner -> TextExtractor -> IndexingPipeline -> VectorDatabase
    /// path with the same pinned local E5 model and geometry for both arms.
    func testPDFOCRRetrievalBenchmark() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["VEC_E13_RETRIEVAL"] == "1",
                          "Opt-in E13 production retrieval comparison")
        guard let outputPath = environment["VEC_E13_OUTPUT_DIRECTORY"], !outputPath.isEmpty else {
            throw BenchmarkError.missingOutputDirectory
        }
        let outputDirectory = URL(fileURLWithPath: outputPath, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: outputDirectory.path) else {
            throw BenchmarkError.outputAlreadyExists
        }
        let modelPath = environment["VEC_E13_MODEL_DIRECTORY"]
            ?? "/private/tmp/vec-e10-model/f52bf8ec8c7124536f0efb74aca902b2995e5bcd"
        let modelDirectory = URL(fileURLWithPath: modelPath, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: modelDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw BenchmarkError.missingModelDirectory(modelPath) }

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let corpusDirectory = outputDirectory.appendingPathComponent("frozen-corpus", isDirectory: true)
        try FileManager.default.createDirectory(at: corpusDirectory, withIntermediateDirectories: true)
        try writeRetrievalFixtures(to: corpusDirectory)

        let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let manifestURL = repositoryRoot.appendingPathComponent(
            "experiments/E13-pdf-extraction/queries/rubric-queries.json")
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(E13PDFRubric.self, from: manifestData)
        guard manifest.frozen_before_ranking,
              manifest.corpus.expected_pdf_files == 7,
              manifest.arms.map(\.key) == ["raw", "pdf-ocr-v1"],
              Set(manifest.queries.map(\.id)).count == manifest.queries.count else {
            throw BenchmarkError.invalidRubric
        }

        // FREEZE before constructing an embedder, database, arm, or rank.
        let frozenFiles = try FileManager.default.contentsOfDirectory(
            at: corpusDirectory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
            .filter { $0.pathExtension.lowercased() == "pdf" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url -> [String: Any] in
                let data = try Data(contentsOf: url)
                return ["path": url.lastPathComponent, "bytes": data.count,
                        "sha256": Self.sha256(data)]
            }
        guard frozenFiles.count == manifest.corpus.expected_pdf_files else {
            throw BenchmarkError.unexpectedPDFCount(frozenFiles.count)
        }
        let manifestHash = Self.sha256(manifestData)
        let modelFiles = try Self.hashFiles(in: modelDirectory)
        let build = Self.gitBuildIdentity(repositoryRoot: repositoryRoot)
        let settings: [String: Any] = [
            "profile_identity": "e5-base@1200/0", "embedder": "e5-base-v2",
            "chunk_chars": 1200, "chunk_overlap": 0, "concurrency": 2,
            "ocr_concurrency": 1, "pdf_ocr_version": PDFOCRReader.version,
            "vision_request_revision": ImageOCR.requestRevision, "pdf_dpi": 144,
            "pdf_max_pixel_dimension": 4096,
        ]
        let runIdentityData = try JSONSerialization.data(withJSONObject: [
            "files": frozenFiles, "query_manifest_sha256": manifestHash,
            "model_files": modelFiles, "settings": settings,
        ], options: [.sortedKeys])
        let runIdentity = Self.sha256(runIdentityData)
        let frozenManifest: [String: Any] = [
            "experiment": "E13-pdf-extraction", "run_identity": runIdentity,
            "frozen_at": ISO8601DateFormatter().string(from: Date()),
            "files": frozenFiles, "file_count": frozenFiles.count,
            "query_manifest_sha256": manifestHash, "query_count": manifest.queries.count,
            "query_manifest_path": "experiments/E13-pdf-extraction/queries/rubric-queries.json",
            "model_directory": modelDirectory.path, "model_files": modelFiles,
            "build": build, "settings": settings,
            "synthetic_limitations": "Clean high-contrast CoreText English fixtures; not representative of real scans or complex layouts.",
        ]
        try Self.writeJSONObject(frozenManifest,
                                 to: outputDirectory.appendingPathComponent("frozen-input-manifest.json"))
        try manifestData.write(to: outputDirectory.appendingPathComponent("query-manifest.json"),
                               options: .atomic)
        let command = "VEC_E13_RETRIEVAL=1 VEC_E13_MODEL_DIRECTORY=\(modelDirectory.path) VEC_E13_OUTPUT_DIRECTORY=\(outputDirectory.path) swift test --disable-sandbox --disable-swift-testing -c release --filter PDFOCRReaderTests/testPDFOCRRetrievalBenchmark\n"
        try Data(command.utf8).write(to: outputDirectory.appendingPathComponent("execution-command.txt"),
                                     options: .atomic)

        for arm in manifest.arms {
            guard let mode = TextExtractionMode(rawValue: arm.text_extraction) else {
                throw BenchmarkError.invalidRubric
            }
            let armDirectory = outputDirectory.appendingPathComponent(arm.key, isDirectory: true)
            try FileManager.default.createDirectory(at: armDirectory, withIntermediateDirectories: true)
            let databaseDirectory = tempDirectory.appendingPathComponent("retrieval-db-\(arm.key)")
            let cacheDirectory = tempDirectory.appendingPathComponent("retrieval-cache-\(arm.key)")
            let factory: @Sendable () -> any Embedder = { E5BaseEmbedder(modelDirectory: modelDirectory) }
            let profile = IndexingProfile(
                identity: "e5-base@1200/0", embedder: factory(), embedderFactory: factory,
                splitter: RecursiveCharacterSplitter(chunkSize: 1200, chunkOverlap: 0),
                chunkSize: 1200, chunkOverlap: 0, isBuiltIn: true)
            let database = VectorDatabase(databaseDirectory: databaseDirectory,
                                          sourceDirectory: corpusDirectory,
                                          dimension: profile.embedder.dimension)
            try await database.initialize()
            let scanner = FileScanner(directory: corpusDirectory, respectsGitignore: false,
                                      textExtraction: mode)
            let files = try scanner.scan()
            guard files.count == frozenFiles.count else {
                throw BenchmarkError.unexpectedPDFCount(files.count)
            }
            let extractor = TextExtractor(splitter: profile.splitter, textExtraction: mode,
                                          ocrCacheDirectory: cacheDirectory)
            let pipeline = IndexingPipeline(concurrency: 2, ocrConcurrency: 1,
                                            batchSize: IndexingPipeline.defaultBatchSize,
                                            bucketWidth: IndexingPipeline.defaultBucketWidth,
                                            profile: profile)
            let rssBefore = E13Memory.residentBytes()
            let start = DispatchTime.now().uptimeNanoseconds
            let (results, _) = try await pipeline.run(
                workItems: files.map { (file: $0, label: "Added") },
                extractor: extractor, database: database)
            let end = DispatchTime.now().uptimeNanoseconds
            let rssAfter = E13Memory.residentBytes()
            guard results.count == files.count else { throw BenchmarkError.incompletePipeline }
            if results.contains(where: {
                if case .skippedEmbedFailure = $0 { return true }
                if case .indexed(_, _, _, let failed) = $0 { return failed > 0 }
                return false
            }) { throw BenchmarkError.incompletePipeline }

            var perFile: [[String: Any]] = []
            var chunksByFile: [String: [TextChunk]] = [:]
            for file in files {
                let extraction = try extractor.extract(from: file)
                chunksByFile[file.relativePath] = extraction.chunks
                perFile.append(["path": file.relativePath, "chunks": extraction.chunks.count])
            }
            let totalChunks = try await database.totalChunkCount()
            guard perFile.reduce(0, { $0 + ($1["chunks"] as? Int ?? 0) }) == totalChunks else {
                throw BenchmarkError.incompletePipeline
            }
            let cache = extractor.pdfOCRCacheStatistics ?? PDFOCRCacheStatistics()
            let summary: [String: Any] = [
                "arm": arm.key, "text_extraction": arm.text_extraction,
                "processed_count": files.count, "failed_count": 0,
                "indexed_count": perFile.filter { ($0["chunks"] as? Int ?? 0) > 0 }.count,
                "blank_count": perFile.filter { ($0["chunks"] as? Int ?? 0) == 0 }.count,
                "total_chunks": totalChunks, "per_file_chunks": perFile,
                "index_wall_seconds": Double(end - start) / 1_000_000_000,
                "rss_before_bytes": rssBefore, "rss_after_bytes": rssAfter,
                "pdf_ocr_cache": ["hits": cache.hits, "misses": cache.misses,
                                  "ocr_calls": cache.ocrCalls,
                                  "coalesced_requests": cache.coalescedRequests],
            ]
            try Self.writeJSONObject(summary, to: armDirectory.appendingPathComponent("arm-summary.json"))

            for query in manifest.queries {
                let vector = try await profile.embedder.embedQuery(query.text)
                let rawResults = try await database.search(embedding: vector, limit: 30)
                let groups = SearchResultCoalescer.coalesce(rawResults, limit: 10)
                let serializedGroups: [[String: Any]] = groups.enumerated().map { offset, group in
                    ["file": group.filePath, "rank": offset + 1, "best_score": group.bestScore,
                     "matches": group.matches.map { match in
                        ["score": max(0, 1 - match.distance), "distance": match.distance,
                         "page_number": match.pageNumber.map { $0 as Any } ?? NSNull(),
                         "chunk_type": match.chunkType.rawValue,
                         "preview": match.contentPreview ?? ""]
                     }]
                }
                let fileRank = groups.firstIndex { $0.filePath == query.primary_file }.map { $0 + 1 }
                let primaryChunks = chunksByFile[query.primary_file] ?? []
                let passagePass = primaryChunks.contains { chunk in
                    let normalized = PDFOCRReader.normalizedTokens(chunk.text).joined(separator: " ")
                    let termsPresent = query.passage_terms.allSatisfy { normalized.contains($0.lowercased()) }
                    let maximum = query.maximum_normalized_passage_occurrences ?? Int.max
                    let phrase = query.passage_terms.joined(separator: " ").lowercased()
                    return termsPresent && occurrences(of: phrase, in: normalized) <= maximum
                }
                let result: [String: Any] = [
                    "id": query.id, "text": query.text, "arm": arm.key,
                    "primary_file": query.primary_file, "primary_page": query.primary_page,
                    "file_rank": fileRank.map { $0 as Any } ?? NSNull(),
                    "passage_criteria_met": passagePass,
                    "groups": serializedGroups,
                ]
                try Self.writeJSONObject(result,
                                         to: armDirectory.appendingPathComponent("\(query.id).json"))
            }
        }
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

    func testTextExtractorRawBeforeAndPDFOCROptInAfter() throws {
        let url = tempDirectory.appendingPathComponent("extractor-mixed.pdf")
        try writePDF([PageFixture(native: ["NATIVE BEFORE TEXT"])], to: url)
        let file = FileInfo(relativePath: "extractor-mixed.pdf", url: url,
                            modificationDate: Date(), fileExtension: "pdf")
        let splitter = RecursiveCharacterSplitter(chunkSize: 1200, chunkOverlap: 0)
        XCTAssertTrue(try FileScanner(directory: tempDirectory, respectsGitignore: false,
                                      textExtraction: .raw).scan().contains {
            $0.relativePath == "extractor-mixed.pdf"
        }, "Raw scanner must continue discovering PDFs")
        XCTAssertTrue(try FileScanner(directory: tempDirectory, respectsGitignore: false,
                                      textExtraction: .pdfOCRV1).scan().contains {
            $0.relativePath == "extractor-mixed.pdf"
        }, "PDF OCR scanner must discover the identical PDF set")

        let raw = TextExtractor(splitter: splitter, textExtraction: .raw,
                                ocrRecognizer: CountingImageRecognizer())
        let before = try raw.extract(from: file)
        XCTAssertFalse(raw.isOCRFile(file))
        XCTAssertTrue(before.chunks.contains { normalized($0.text).contains("native before text") })
        XCTAssertFalse(before.chunks.contains { normalized($0.text).contains("raster after text") })

        let pageRecognizer = CountingPDFRecognizer(result: recognition("RASTER AFTER TEXT"))
        let pdfReader = PDFOCRReader(recognizer: pageRecognizer)
        let enabled = TextExtractor(splitter: splitter, textExtraction: .pdfOCRV1,
                                    ocrRecognizer: CountingImageRecognizer(),
                                    pdfOCRReader: pdfReader)
        let after = try enabled.extract(from: file)
        XCTAssertTrue(enabled.isOCRFile(file))
        XCTAssertEqual(after.linePageCount, 1)
        XCTAssertEqual(after.chunks.filter { $0.type == .pdfPage }.map(\.pageNumber), [1])
        XCTAssertTrue(after.chunks.contains { normalized($0.text).contains("native before text") })
        XCTAssertTrue(after.chunks.contains { normalized($0.text).contains("raster after text") })
        XCTAssertEqual(pageRecognizer.attemptCount, 1)
    }

    func testEveryPDFOCRCombinationAdvertisesItsComponent() {
        for mode in TextExtractionMode.allCases {
            XCTAssertEqual(mode.includesPDFOCR, mode.rawValue.split(separator: "+").contains("pdf-ocr-v1"),
                           "PDF OCR predicate drifted for \(mode.rawValue)")
        }
        XCTAssertTrue(TextExtractionMode.markdownV1VttV1ImageOCRV1PDFOCRV1.includesMarkdown)
        XCTAssertTrue(TextExtractionMode.markdownV1VttV1ImageOCRV1PDFOCRV1.includesVTT)
        XCTAssertTrue(TextExtractionMode.markdownV1VttV1ImageOCRV1PDFOCRV1.includesImageOCR)
        XCTAssertTrue(TextExtractionMode.markdownV1VttV1ImageOCRV1PDFOCRV1.includesPDFOCR)
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

    private func writeRetrievalFixtures(to directory: URL) throws {
        try writePDF([PageFixture(native: ["NATIVE ORCHARD SIGNAL"])],
                     to: directory.appendingPathComponent("native-only.pdf"))
        try writePDF([PageFixture(images: [ImageLine("RASTER NEBULA TOKEN", y: 330)])],
                     to: directory.appendingPathComponent("image-only.pdf"))
        try writePDF([PageFixture(native: ["NATIVE CEDAR HEADER"],
                                  images: [ImageLine("RASTER QUARTZ DETAIL", y: 300)])],
                     to: directory.appendingPathComponent("mixed.pdf"))
        try writePDF([PageFixture()], to: directory.appendingPathComponent("blank.pdf"))
        try writePDF([
            PageFixture(native: ["MULTIPAGE ALABASTER DISTRACTOR"]),
            PageFixture(images: [ImageLine("INDIGO PROVENANCE MARKER", y: 330)]),
        ], to: directory.appendingPathComponent("multipage.pdf"))
        let duplicate = "COPPER LANTERN ARCHIVE"
        try writePDF([PageFixture(native: [duplicate], images: [ImageLine(duplicate, y: 300)])],
                     to: directory.appendingPathComponent("duplicate-overlap.pdf"))

        let crop = CGRect(x: 55, y: 100, width: 500, height: 300)
        let unrotated = tempDirectory.appendingPathComponent("retrieval-rotation-source.pdf")
        try writePDF([PageFixture(images: [ImageLine("ROTATED CROP MARKER", y: 190)], cropBox: crop)],
                     to: unrotated)
        let document = try XCTUnwrap(PDFDocument(url: unrotated))
        let page = try XCTUnwrap(document.page(at: 0))
        page.setBounds(crop, for: .cropBox)
        page.rotation = 90
        let rotated = directory.appendingPathComponent("rotation-crop.pdf")
        guard document.write(to: rotated) else { throw FixtureError.couldNotCreatePDF }
        let verification = try XCTUnwrap(PDFDocument(url: rotated)?.page(at: 0))
        XCTAssertEqual(verification.rotation, 90)
        XCTAssertEqual(try XCTUnwrap(verification.pageRef).getBoxRect(.cropBox), crop)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(file url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1 << 20)
            guard let data, !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func hashFiles(in directory: URL) throws -> [[String: Any]] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else { throw BenchmarkError.missingModelDirectory(directory.path) }
        var result: [[String: Any]] = []
        while let url = enumerator.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            let relative = url.path.replacingOccurrences(of: directory.path + "/", with: "")
            result.append(["path": relative, "bytes": values.fileSize ?? 0,
                           "sha256": try sha256(file: url)])
        }
        return result.sorted { ($0["path"] as? String ?? "") < ($1["path"] as? String ?? "") }
    }

    private static func gitBuildIdentity(repositoryRoot: URL) -> [String: Any] {
        let head = runProcess("/usr/bin/git", arguments: ["rev-parse", "HEAD"],
                              directory: repositoryRoot) ?? "unknown"
        let status = runProcess("/usr/bin/git", arguments: ["status", "--porcelain"],
                                directory: repositoryRoot)
        let packageResolved = repositoryRoot.appendingPathComponent("Package.resolved")
        return ["git_head": head, "git_dirty": !(status ?? "unknown").isEmpty,
                "package_resolved_sha256": (try? sha256(file: packageResolved)) ?? "missing",
                "swift_version": runProcess("/usr/bin/swift", arguments: ["--version"],
                                             directory: repositoryRoot) ?? "unknown",
                "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
                "active_processor_count": ProcessInfo.processInfo.activeProcessorCount,
                "host_name": ProcessInfo.processInfo.hostName]
    }

    private static func runProcess(_ executable: String,
                                   arguments: [String],
                                   directory: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func writeJSONObject(_ object: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
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

    private enum BenchmarkError: Error {
        case missingOutputDirectory
        case outputAlreadyExists
        case missingModelDirectory(String)
        case invalidRubric
        case unexpectedPDFCount(Int)
        case incompletePipeline
        case missingCacheStatistics
        case unexpectedPageCount
    }

    private struct PassMeasurement {
        let seconds: Double
        let rssBefore: UInt64
        let rssAfter: UInt64
        let rssPeak: UInt64
        let rssSamples: Int
        let cache: PDFOCRCacheStatistics
        let pages: Int

        var dictionary: [String: Any] {
            ["wall_seconds": seconds,
             "pages": pages,
             "pages_per_second": seconds > 0 ? Double(pages) / seconds : 0,
             "rss_before_bytes": rssBefore,
             "rss_after_bytes": rssAfter,
             "rss_peak_bytes": rssPeak,
             "rss_sample_count": rssSamples,
             "cache_hits": cache.hits,
             "cache_misses": cache.misses,
             "ocr_calls": cache.ocrCalls,
             "coalesced_requests": cache.coalescedRequests]
        }
    }

    private func measuredPass(reader: PDFOCRReader,
                              url: URL,
                              expectedPages: Int) throws -> PassMeasurement {
        let before = E13Memory.residentBytes()
        let sampler = E13RSSSampler(intervalMilliseconds: 10)
        sampler.start()
        let start = DispatchTime.now().uptimeNanoseconds
        let result = try reader.read(from: url)
        let end = DispatchTime.now().uptimeNanoseconds
        let sampled = sampler.stop()
        let after = E13Memory.residentBytes()
        guard result.pageCount == expectedPages else { throw BenchmarkError.unexpectedPageCount }
        guard let cache = reader.cacheStatistics else { throw BenchmarkError.missingCacheStatistics }
        return PassMeasurement(seconds: Double(end - start) / 1_000_000_000,
                               rssBefore: before, rssAfter: after,
                               rssPeak: max(before, after, sampled.peak),
                               rssSamples: sampled.count, cache: cache, pages: result.pageCount)
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

    private struct CountingImageRecognizer: ImageTextRecognizer {
        func recognizeText(in imageURL: URL) throws -> ImageOCRResult {
            XCTFail("PDF extraction must not invoke the raster-file recognizer")
            return ImageOCRResult(text: "", lines: [], paragraphs: [])
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

private final class E13RSSSampler: @unchecked Sendable {
    private let intervalMicroseconds: UInt32
    private let lock = NSLock()
    private var running = false
    private var peak: UInt64 = 0
    private var count = 0

    init(intervalMilliseconds: UInt32) {
        intervalMicroseconds = intervalMilliseconds * 1_000
    }

    func start() {
        lock.lock()
        running = true
        peak = 0
        count = 0
        lock.unlock()
        Thread.detachNewThread { [weak self] in
            guard let self else { return }
            while true {
                self.lock.lock()
                let shouldContinue = self.running
                self.lock.unlock()
                guard shouldContinue else { return }
                let rss = E13Memory.residentBytes()
                self.lock.lock()
                self.peak = max(self.peak, rss)
                self.count += 1
                self.lock.unlock()
                usleep(self.intervalMicroseconds)
            }
        }
    }

    func stop() -> (peak: UInt64, count: Int) {
        lock.lock()
        running = false
        let result = (peak, count)
        lock.unlock()
        return result
    }
}

private enum E13Memory {
    static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size
                                            / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        return status == KERN_SUCCESS ? info.resident_size : 0
    }
}

private struct E13PDFRubric: Decodable {
    struct Corpus: Decodable { let expected_pdf_files: Int }
    struct Arm: Decodable { let key: String; let text_extraction: String }
    struct Query: Decodable {
        let id: String
        let text: String
        let primary_file: String
        let primary_page: Int
        let passage_terms: [String]
        let maximum_normalized_passage_occurrences: Int?
    }

    let frozen_before_ranking: Bool
    let corpus: Corpus
    let arms: [Arm]
    let queries: [Query]
}
