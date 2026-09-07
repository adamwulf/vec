import XCTest
import Foundation
@testable import VecKit

/// Tests for the bounded, configurable image-OCR extraction concurrency added
/// to `IndexingPipeline` for `image-ocr-v1`.
///
/// Two behaviors are under test:
///
///  1. **The bound itself.** `IndexingPipeline.forEachBounded` — the sliding
///     window that backs the image lane — must run at most `limit`
///     invocations at once (never more, regardless of item count), while
///     still reaching `limit` when there is enough work, and must process
///     every item and propagate the first error. This is the primitive that
///     guarantees a 325k-image corpus never spawns 325k tasks or decodes
///     more than `limit` images at a time.
///
///  2. **The wiring, end-to-end through `run()`.** The text/PDF path stays
///     strictly serial while image files fan out up to `ocrConcurrency`, and
///     the pipeline still indexes a mixed corpus correctly with per-file
///     chunk ordering preserved. The image path is driven by an injected
///     `ImageTextRecognizer` (engine API) so tests never touch Vision; text
///     concurrency is observed through an injected `TextSplitter`. The two
///     lanes are distinguished by a content marker because — post
///     `image-ocr-v1` — OCR text is also handed to the splitter.
///
/// All tests are fast and deterministic: a mock embedder replaces the real
/// model, `ocrCacheDirectory: nil` removes all OCR-cache file IO, and the
/// concurrency probes rely on short holds / rendezvous rather than wall-clock
/// races.
final class ImageOCRPipelineTests: XCTestCase {

    private var tempDir: URL!
    private var sourceDir: URL!
    private var dbDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VecImageOCRPipeline-\(UUID().uuidString)")
        sourceDir = tempDir.appendingPathComponent("source")
        dbDir = tempDir.appendingPathComponent("db")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try super.tearDownWithError()
    }

    // MARK: - forEachBounded: the bound primitive

    /// The window must reach `limit` concurrent invocations (given enough
    /// work), never exceed it, and still run every item exactly once.
    func testForEachBoundedReachesLimitNeverExceedsAndRunsAll() async throws {
        let probe = AsyncConcurrencyProbe()
        let items = Array(0..<24)
        let limit = 4

        try await IndexingPipeline.forEachBounded(items, limit: limit) { _ in
            await probe.enter()
            // Long enough that the primed window overlaps deterministically.
            try await Task.sleep(nanoseconds: 30_000_000)
            await probe.leave()
        }

        let peak = await probe.peak
        let total = await probe.total
        XCTAssertLessThanOrEqual(peak, limit,
            "forEachBounded must never run more than `limit` bodies at once")
        XCTAssertEqual(peak, limit,
            "forEachBounded must reach `limit` when there is enough work")
        XCTAssertEqual(total, items.count,
            "forEachBounded must run every item exactly once")
    }

    /// With `limit == 1` the window is fully serial: peak concurrency 1.
    func testForEachBoundedSerialWhenLimitIsOne() async throws {
        let probe = AsyncConcurrencyProbe()
        let items = Array(0..<8)

        try await IndexingPipeline.forEachBounded(items, limit: 1) { _ in
            await probe.enter()
            try await Task.sleep(nanoseconds: 10_000_000)
            await probe.leave()
        }

        let peak = await probe.peak
        XCTAssertEqual(peak, 1, "limit 1 must serialize all invocations")
        XCTAssertEqual(await probe.total, items.count)
    }

    /// When `limit` exceeds the item count the window is capped by the item
    /// count, and an empty input runs nothing (no task, no crash).
    func testForEachBoundedCappedByItemCountAndEmptyInputIsNoop() async throws {
        let probe = AsyncConcurrencyProbe()
        try await IndexingPipeline.forEachBounded(Array(0..<3), limit: 10) { _ in
            await probe.enter()
            try await Task.sleep(nanoseconds: 20_000_000)
            await probe.leave()
        }
        XCTAssertEqual(await probe.peak, 3, "peak is bounded by item count")
        XCTAssertEqual(await probe.total, 3)

        let empty = AsyncConcurrencyProbe()
        try await IndexingPipeline.forEachBounded([Int](), limit: 4) { _ in
            await empty.enter(); await empty.leave()
        }
        XCTAssertEqual(await empty.total, 0, "empty input must run no bodies")
    }

    /// The first body error propagates out of the window (which cancels the
    /// still-running siblings — the same cascade the pipeline relies on when
    /// a downstream stage fails).
    func testForEachBoundedPropagatesBodyError() async throws {
        do {
            try await IndexingPipeline.forEachBounded(Array(0..<12), limit: 3) { value in
                if value == 5 { throw ProbeError(value: value) }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTFail("forEachBounded must rethrow the first body error")
        } catch let error as ProbeError {
            XCTAssertEqual(error.value, 5)
        }
    }

    // MARK: - Init contract

    func testInitStoresOCRConcurrencyAndDefaultsToOne() {
        let profile = makeMockProfile()
        let explicit = IndexingPipeline(
            concurrency: 2, ocrConcurrency: 3, batchSize: 4, bucketWidth: 500, profile: profile
        )
        XCTAssertEqual(explicit.ocrConcurrency, 3)

        let defaulted = IndexingPipeline(concurrency: 2, batchSize: 4, profile: profile)
        XCTAssertEqual(defaulted.ocrConcurrency, IndexingPipeline.defaultOCRConcurrency)
        XCTAssertEqual(IndexingPipeline.defaultOCRConcurrency, 1,
            "the conservative default keeps first-index behavior serial")
    }

    // MARK: - End-to-end: image lane honors ocrConcurrency

    /// With `ocrConcurrency == 3`, image OCR must reach exactly 3 concurrent
    /// extractions and never exceed it. Driven by an injected recognizer that
    /// rendezvous-blocks until the bound is filled, so "reaches the bound" is
    /// deterministic rather than a timing race.
    func testImageLaneRunsUpToOCRConcurrency() async throws {
        let ocrConcurrency = 3
        let ocrProbe = SyncConcurrencyProbe(rendezvous: ocrConcurrency, hold: 0.01, timeout: 0.5)
        let recognizer = ProbeRecognizer(probe: ocrProbe, text: "image ocr text")

        let extractor = TextExtractor(
            splitter: RecursiveCharacterSplitter(chunkSize: 1200, chunkOverlap: 240),
            textExtraction: .imageOCRV1,
            ocrRecognizer: recognizer,
            ocrCacheDirectory: nil
        )

        var workItems: [(file: FileInfo, label: String)] = []
        for i in 0..<9 {
            workItems.append((file: try makeImageFile("img_\(i).png"), label: "Added"))
        }

        let results = try await runPipeline(
            workItems: workItems, extractor: extractor, ocrConcurrency: ocrConcurrency
        )

        XCTAssertLessThanOrEqual(ocrProbe.maxActive, ocrConcurrency,
            "image OCR must never exceed ocrConcurrency")
        XCTAssertEqual(ocrProbe.maxActive, ocrConcurrency,
            "image OCR must reach ocrConcurrency when enough images exist")
        XCTAssertEqual(indexedCount(results), workItems.count,
            "every image file must be indexed")
    }

    /// The headline regression guard: with `ocrConcurrency > 1`, the text/PDF
    /// lane stays strictly serial (peak split concurrency 1) *while* the
    /// image lane runs concurrently (peak recognizer concurrency ==
    /// ocrConcurrency). Text and image split calls are told apart by a marker
    /// only the text-file bodies carry.
    func testTextLaneStaysSerialWhileImagesRunConcurrently() async throws {
        let ocrConcurrency = 3
        let textMarker = "TXTMARKER"

        let textProbe = SyncConcurrencyProbe(rendezvous: nil, hold: 0.08)
        let ocrProbe = SyncConcurrencyProbe(rendezvous: ocrConcurrency, hold: 0.01, timeout: 0.5)

        let extractor = TextExtractor(
            splitter: MarkerProbeSplitter(probe: textProbe, marker: textMarker),
            textExtraction: .imageOCRV1,
            ocrRecognizer: ProbeRecognizer(probe: ocrProbe, text: "ocr body no marker"),
            ocrCacheDirectory: nil
        )

        var workItems: [(file: FileInfo, label: String)] = []
        for i in 0..<6 {
            let content = Data("\(textMarker) text file body number \(i)".utf8)
            workItems.append((file: try makeFile("doc_\(i).txt", content: content), label: "Added"))
        }
        for i in 0..<8 {
            workItems.append((file: try makeImageFile("pic_\(i).png"), label: "Added"))
        }

        let results = try await runPipeline(
            workItems: workItems, extractor: extractor, ocrConcurrency: ocrConcurrency
        )

        XCTAssertEqual(textProbe.maxActive, 1,
            "text/PDF extraction must stay serial even when ocrConcurrency > 1")
        XCTAssertLessThanOrEqual(ocrProbe.maxActive, ocrConcurrency)
        XCTAssertEqual(ocrProbe.maxActive, ocrConcurrency,
            "image OCR must run up to ocrConcurrency alongside the serial text lane")
        XCTAssertEqual(indexedCount(results), workItems.count,
            "every file in the mixed corpus must be indexed")
    }

    /// The conservative default (`ocrConcurrency == 1`) serializes image OCR:
    /// a fixed hold would surface any accidental overlap as peak > 1.
    func testDefaultOCRConcurrencySerializesImages() async throws {
        let ocrProbe = SyncConcurrencyProbe(rendezvous: nil, hold: 0.1)
        let extractor = TextExtractor(
            splitter: RecursiveCharacterSplitter(chunkSize: 1200, chunkOverlap: 240),
            textExtraction: .imageOCRV1,
            ocrRecognizer: ProbeRecognizer(probe: ocrProbe, text: "serial ocr text"),
            ocrCacheDirectory: nil
        )

        var workItems: [(file: FileInfo, label: String)] = []
        for i in 0..<4 {
            workItems.append((file: try makeImageFile("solo_\(i).png"), label: "Added"))
        }

        // Default init: ocrConcurrency omitted -> defaultOCRConcurrency (1).
        let results = try await runPipeline(
            workItems: workItems, extractor: extractor, ocrConcurrency: nil
        )

        XCTAssertEqual(ocrProbe.maxActive, 1,
            "the default must extract images one at a time")
        XCTAssertEqual(indexedCount(results), workItems.count)
    }

    // MARK: - End-to-end: mixed-corpus regression + per-file ordering

    /// A mixed corpus at `ocrConcurrency > 1` indexes every file, and a
    /// multi-chunk text file preserves per-file ordinal ordering: the
    /// whole-document chunk (ordinal 0) is stored first even though the embed
    /// stage delivers chunks out of order.
    func testMixedCorpusIndexesAllFilesAndPreservesChunkOrder() async throws {
        let extractor = TextExtractor(
            splitter: RecursiveCharacterSplitter(chunkSize: 200, chunkOverlap: 40),
            textExtraction: .imageOCRV1,
            ocrRecognizer: DeterministicRecognizer(text: "short image caption"),
            ocrCacheDirectory: nil
        )

        // A text body comfortably larger than chunkSize so the real splitter
        // emits a whole chunk plus several sub-chunks.
        let longBody = String(
            repeating: "This sentence is about vectors, chunks, and indexing order. ",
            count: 14
        )
        let longDoc = try makeFile("long.txt", content: Data(longBody.utf8))
        let shortDoc = try makeFile("short.txt", content: Data("just a short line".utf8))
        let image = try makeImageFile("scan.png")

        let workItems: [(file: FileInfo, label: String)] = [
            (file: longDoc, label: "Added"),
            (file: shortDoc, label: "Added"),
            (file: image, label: "Added")
        ]

        let (results, database) = try await runPipelineReturningDatabase(
            workItems: workItems,
            extractor: extractor,
            ocrConcurrency: 4,
            chunkSize: 200,
            chunkOverlap: 40
        )

        XCTAssertEqual(indexedCount(results), workItems.count,
            "text, short text, and image files must all be indexed")

        // Long doc: multiple chunks, whole-doc chunk first (ordinal order).
        let longCount = try await database.chunkCount(filePath: "long.txt")
        XCTAssertGreaterThan(longCount, 1, "the long doc must split into multiple chunks")
        let firstLong = try await database.fetchChunk(filePath: "long.txt", index: 1)
        XCTAssertEqual(firstLong?.chunkType, .whole,
            "the whole-document chunk (ordinal 0) must be stored first")

        // Image: exactly one .image chunk from the short OCR caption.
        let imageCount = try await database.chunkCount(filePath: "scan.png")
        XCTAssertEqual(imageCount, 1)
        let firstImage = try await database.fetchChunk(filePath: "scan.png", index: 1)
        XCTAssertEqual(firstImage?.chunkType, .image,
            "an OCR'd image file must produce an .image chunk")
    }

    // MARK: - Pipeline helpers

    private func indexedCount(_ results: [IndexResult]) -> Int {
        results.reduce(into: 0) { acc, r in
            if case .indexed = r { acc += 1 }
        }
    }

    private func runPipeline(
        workItems: [(file: FileInfo, label: String)],
        extractor: TextExtractor,
        ocrConcurrency: Int?
    ) async throws -> [IndexResult] {
        let (results, _) = try await runPipelineReturningDatabase(
            workItems: workItems,
            extractor: extractor,
            ocrConcurrency: ocrConcurrency,
            chunkSize: 1200,
            chunkOverlap: 240
        )
        return results
    }

    private func runPipelineReturningDatabase(
        workItems: [(file: FileInfo, label: String)],
        extractor: TextExtractor,
        ocrConcurrency: Int?,
        chunkSize: Int,
        chunkOverlap: Int
    ) async throws -> ([IndexResult], VectorDatabase) {
        let profile = makeMockProfile(chunkSize: chunkSize, chunkOverlap: chunkOverlap)
        let database = VectorDatabase(
            databaseDirectory: dbDir,
            sourceDirectory: sourceDir,
            dimension: 768
        )
        try await database.initialize()

        // Small pool + batch so tests stay light; ocrConcurrency is the knob
        // under test, independent of the embedder pool size.
        let pipeline: IndexingPipeline
        if let ocrConcurrency {
            pipeline = IndexingPipeline(
                concurrency: 2, ocrConcurrency: ocrConcurrency, batchSize: 4,
                bucketWidth: 500, profile: profile
            )
        } else {
            pipeline = IndexingPipeline(concurrency: 2, batchSize: 4, profile: profile)
        }

        let (results, _) = try await pipeline.run(
            workItems: workItems,
            extractor: extractor,
            database: database
        )
        return (results, database)
    }

    private func makeMockProfile(chunkSize: Int = 1200, chunkOverlap: Int = 240) -> IndexingProfile {
        let factory: @Sendable () -> any Embedder = { MockEmbedder() }
        return IndexingProfile(
            identity: "mock@\(chunkSize)/\(chunkOverlap)",
            embedder: factory(),
            embedderFactory: factory,
            splitter: RecursiveCharacterSplitter(chunkSize: chunkSize, chunkOverlap: chunkOverlap),
            chunkSize: chunkSize,
            chunkOverlap: chunkOverlap,
            isBuiltIn: false
        )
    }

    // MARK: - File helpers

    private func makeFile(_ name: String, content: Data) throws -> FileInfo {
        let url = sourceDir.appendingPathComponent(name)
        try content.write(to: url)
        return FileInfo(
            relativePath: name,
            url: url,
            modificationDate: Date(),
            fileExtension: (name as NSString).pathExtension.lowercased()
        )
    }

    /// Image files carry dummy bytes: with `ocrCacheDirectory: nil` the
    /// extractor hands the URL straight to the injected recognizer without
    /// reading or decoding, so the bytes are never inspected.
    private func makeImageFile(_ name: String) throws -> FileInfo {
        try makeFile(name, content: Data([0x89, 0x50, 0x4E, 0x47]))
    }
}

// MARK: - Test doubles

/// Deterministic 768-dim mock embedder; keeps the embed stage fast so the
/// tests exercise the extract stage's concurrency, not model latency.
private actor MockEmbedder: Embedder {
    nonisolated var name: String { "mock-768" }
    nonisolated var dimension: Int { 768 }
    func embedDocument(_ text: String) async throws -> [Float] {
        Array(repeating: Float(0.1), count: 768)
    }
    func embedQuery(_ text: String) async throws -> [Float] {
        Array(repeating: Float(0.1), count: 768)
    }
    func embedDocuments(_ texts: [String]) async throws -> [[Float]] {
        texts.map { _ in Array(repeating: Float(0.1), count: 768) }
    }
}

private struct ProbeError: Error, Equatable {
    let value: Int
}

/// Async concurrency probe for the `forEachBounded` unit tests: `enter`/`leave`
/// bracket each body and the actor tracks the peak overlap and total runs.
private actor AsyncConcurrencyProbe {
    private var active = 0
    private(set) var peak = 0
    private(set) var total = 0
    func enter() {
        active += 1
        peak = max(peak, active)
        total += 1
    }
    func leave() { active -= 1 }
}

/// Synchronous concurrency probe used from inside the (synchronous) recognizer
/// and splitter seams. Tracks peak overlap. Two modes:
///  - `rendezvous == N`: a call blocks until `N` calls are concurrently inside
///    (or `timeout` elapses), forcing a deterministic peak of `N`.
///  - `rendezvous == nil`: each call simply holds for `hold` seconds, so any
///    accidental overlap surfaces as peak > 1.
private final class SyncConcurrencyProbe: @unchecked Sendable {
    private let cond = NSCondition()
    private var active = 0
    private var peak = 0
    private let rendezvous: Int?
    private let hold: TimeInterval
    private let timeout: TimeInterval

    init(rendezvous: Int?, hold: TimeInterval, timeout: TimeInterval = 2.0) {
        self.rendezvous = rendezvous
        self.hold = hold
        self.timeout = timeout
    }

    func run<T>(_ make: () -> T) -> T {
        cond.lock()
        active += 1
        peak = max(peak, active)
        if let rendezvous, active >= rendezvous { cond.broadcast() }
        if let rendezvous {
            let deadline = Date().addingTimeInterval(timeout)
            while active < rendezvous && Date() < deadline {
                cond.wait(until: deadline)
            }
        }
        cond.unlock()

        if hold > 0 { Thread.sleep(forTimeInterval: hold) }
        let result = make()

        cond.lock()
        active -= 1
        cond.unlock()
        return result
    }

    var maxActive: Int {
        cond.lock()
        defer { cond.unlock() }
        return peak
    }
}

/// Injected recognizer that routes through a `SyncConcurrencyProbe` so the
/// image lane's concurrency is observable without invoking Vision.
private struct ProbeRecognizer: ImageTextRecognizer {
    let probe: SyncConcurrencyProbe
    let text: String
    func recognizeText(in imageURL: URL) throws -> ImageOCRResult {
        probe.run { ImageOCRResult(text: text, lines: [text], paragraphs: [text]) }
    }
}

/// Injected recognizer returning fixed OCR text with no probing — for the
/// mixed-corpus regression test where only the result matters.
private struct DeterministicRecognizer: ImageTextRecognizer {
    let text: String
    func recognizeText(in imageURL: URL) throws -> ImageOCRResult {
        ImageOCRResult(text: text, lines: [text], paragraphs: [text])
    }
}

/// Splitter that measures concurrency of the *text* lane only. Post
/// `image-ocr-v1` the splitter is also called on OCR text, so it counts a
/// call only when the text carries the text-file marker; OCR bodies (no
/// marker) return no sub-chunks without touching the probe.
private struct MarkerProbeSplitter: TextSplitter {
    let probe: SyncConcurrencyProbe
    let marker: String
    func split(_ text: String) -> [TextChunk] {
        guard text.contains(marker) else { return [] }
        return probe.run { [] as [TextChunk] }
    }
}
