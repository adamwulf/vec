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
///     invocations at once (never more, regardless of item count), still
///     reach `limit` when there is enough work, process every item, propagate
///     the first error, and stop scheduling promptly when its parent task is
///     cancelled (even if the body never observes cancellation). This is the
///     primitive that guarantees a 325k-image corpus never spawns 325k tasks
///     or decodes more than `limit` images at a time.
///
///  2. **The wiring, end-to-end through `run()`.** The text/PDF path stays
///     strictly serial while image files fan out up to `ocrConcurrency`; a
///     cancelled run tears down without hanging; and a mixed corpus indexes
///     correctly with per-file chunk ordering preserved. The image path is
///     driven by an injected `ImageTextRecognizer` (engine API) so tests
///     never touch Vision; text concurrency is observed through an injected
///     `TextSplitter`. The two lanes are told apart by a content marker
///     because — post `image-ocr-v1` — OCR text is also handed to the
///     splitter.
///
/// Peak-concurrency assertions on `forEachBounded` use an async rendezvous
/// latch (all N bodies suspend until N have arrived, so the peak is reached
/// deterministically without relying on sleep/scheduler timing). The
/// end-to-end tests use a synchronous one-shot barrier for the same reason,
/// and `ocrCacheDirectory: nil` removes all OCR-cache file IO.
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

    /// The window reaches `limit` concurrent invocations, never exceeds it,
    /// and runs every item. The rendezvous latch makes "reaches `limit`"
    /// deterministic: the first `limit` bodies each suspend until all `limit`
    /// have arrived, so `peak == limit` holds regardless of scheduling.
    func testForEachBoundedReachesLimitNeverExceedsAndRunsAll() async throws {
        let limit = 4
        let items = Array(0..<24)
        let latch = RendezvousLatch(target: limit)

        try await IndexingPipeline.forEachBounded(items, limit: limit) { _ in
            await latch.begin()
            await latch.end()
        }

        let peak = await latch.peak
        let total = await latch.total
        XCTAssertLessThanOrEqual(peak, limit,
            "forEachBounded must never run more than `limit` bodies at once")
        XCTAssertEqual(peak, limit,
            "forEachBounded must reach `limit` when there is enough work")
        XCTAssertEqual(total, items.count,
            "forEachBounded must run every item exactly once")
    }

    /// With `limit == 1` the window is serial by construction: body N+1's task
    /// starts only after body N's task completes, so peak concurrency is 1
    /// with no sleep involved (the deterministic bound proof is the limit-4
    /// test above).
    func testForEachBoundedSerialWhenLimitIsOne() async throws {
        let recorder = ConcurrencyRecorder()
        let items = Array(0..<8)

        try await IndexingPipeline.forEachBounded(items, limit: 1) { _ in
            await recorder.enter()
            await recorder.leave()
        }

        let peak = await recorder.peak
        let total = await recorder.total
        XCTAssertEqual(peak, 1, "limit 1 must never run two bodies at once")
        XCTAssertEqual(total, items.count)
    }

    /// When `limit` exceeds the item count the peak is capped by the item
    /// count; an empty input runs nothing (no task, no crash).
    func testForEachBoundedCappedByItemCountAndEmptyInputIsNoop() async throws {
        let latch = RendezvousLatch(target: 3)
        try await IndexingPipeline.forEachBounded(Array(0..<3), limit: 10) { _ in
            await latch.begin()
            await latch.end()
        }
        let peak = await latch.peak
        let total = await latch.total
        XCTAssertEqual(peak, 3, "peak is bounded by item count when limit exceeds it")
        XCTAssertEqual(total, 3)

        let empty = ConcurrencyRecorder()
        try await IndexingPipeline.forEachBounded([Int](), limit: 4) { _ in
            await empty.enter()
            await empty.leave()
        }
        let emptyTotal = await empty.total
        XCTAssertEqual(emptyTotal, 0, "empty input must run no bodies")
    }

    /// The first body error propagates out of the window (which cancels the
    /// still-running siblings — the same cascade the pipeline relies on when
    /// a downstream stage fails).
    func testForEachBoundedPropagatesBodyError() async throws {
        do {
            try await IndexingPipeline.forEachBounded(Array(0..<12), limit: 3) { value in
                if value == 5 { throw ProbeError(value: value) }
            }
            XCTFail("forEachBounded must rethrow the first body error")
        } catch let error as ProbeError {
            XCTAssertEqual(error.value, 5)
        }
    }

    /// Cancelling the parent task must stop the window from scheduling more
    /// work, *even when the body never observes cancellation itself*. Without
    /// forEachBounded's own cancellation check, a cancelled walk over a
    /// 325k-item corpus would keep priming its way through every item.
    func testForEachBoundedStopsSchedulingAfterParentCancellation() async throws {
        let recorder = ConcurrencyRecorder()
        let started = OneShotGate()
        let itemCount = 500

        let task = Task {
            try await IndexingPipeline.forEachBounded(Array(0..<itemCount), limit: 2) { _ in
                await recorder.enter()
                await started.signalOnce()
                // Swallow cancellation so the *body* is not what stops the
                // walk — forEachBounded's own check must be.
                try? await Task.sleep(nanoseconds: 20_000_000)
                await recorder.leave()
            }
        }

        await started.wait()   // the walk is underway
        task.cancel()
        _ = try? await task.value

        let total = await recorder.total
        XCTAssertLessThan(total, itemCount,
            "forEachBounded must stop scheduling after parent cancellation")
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

    /// With `ocrConcurrency == 3`, image OCR reaches exactly 3 concurrent
    /// extractions and never exceeds it. The injected recognizer uses a
    /// one-shot barrier: the first 3 OCR calls rendezvous, so the peak is
    /// reached deterministically, and later calls pass straight through (no
    /// per-call timeout tail).
    func testImageLaneRunsUpToOCRConcurrency() async throws {
        let ocrConcurrency = 3
        let barrier = OCRBarrier(target: ocrConcurrency)
        let extractor = TextExtractor(
            splitter: RecursiveCharacterSplitter(chunkSize: 1200, chunkOverlap: 240),
            textExtraction: .imageOCRV1,
            ocrRecognizer: BarrierRecognizer(barrier: barrier, text: "image ocr text"),
            ocrCacheDirectory: nil
        )

        var workItems: [(file: FileInfo, label: String)] = []
        for i in 0..<9 {
            workItems.append((file: try makeImageFile("img_\(i).png"), label: "Added"))
        }

        let results = try await runPipeline(
            workItems: workItems, extractor: extractor, ocrConcurrency: ocrConcurrency
        )

        XCTAssertLessThanOrEqual(barrier.maxActive, ocrConcurrency,
            "image OCR must never exceed ocrConcurrency")
        XCTAssertEqual(barrier.maxActive, ocrConcurrency,
            "image OCR must reach ocrConcurrency when enough images exist")
        XCTAssertEqual(indexedCount(results), workItems.count,
            "every image file must be indexed")
    }

    /// The headline regression guard: with `ocrConcurrency > 1`, the text/PDF
    /// lane stays strictly serial (peak split concurrency 1) *while* the image
    /// lane runs concurrently (peak OCR concurrency == ocrConcurrency). Text
    /// and image split calls are told apart by a marker only the text-file
    /// bodies carry. The text-lane peak of 1 is structural (a single serial
    /// task); the hold widens the window so any accidental overlap would
    /// surface as peak > 1.
    func testTextLaneStaysSerialWhileImagesRunConcurrently() async throws {
        let ocrConcurrency = 3
        let textMarker = "TXTMARKER"

        let textProbe = SerialHoldProbe(hold: 0.08)
        let ocrBarrier = OCRBarrier(target: ocrConcurrency)

        let extractor = TextExtractor(
            splitter: MarkerProbeSplitter(probe: textProbe, marker: textMarker),
            textExtraction: .imageOCRV1,
            ocrRecognizer: BarrierRecognizer(barrier: ocrBarrier, text: "ocr body no marker"),
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
        XCTAssertLessThanOrEqual(ocrBarrier.maxActive, ocrConcurrency)
        XCTAssertEqual(ocrBarrier.maxActive, ocrConcurrency,
            "image OCR must run up to ocrConcurrency alongside the serial text lane")
        XCTAssertEqual(indexedCount(results), workItems.count,
            "every file in the mixed corpus must be indexed")
    }

    /// The conservative default (`ocrConcurrency == 1`) serializes image OCR.
    /// The peak of 1 is structural; the hold surfaces any accidental overlap.
    func testDefaultOCRConcurrencySerializesImages() async throws {
        let ocrProbe = SerialHoldProbe(hold: 0.1)
        let extractor = TextExtractor(
            splitter: RecursiveCharacterSplitter(chunkSize: 1200, chunkOverlap: 240),
            textExtraction: .imageOCRV1,
            ocrRecognizer: SerialHoldRecognizer(probe: ocrProbe, text: "serial ocr text"),
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

    // MARK: - End-to-end: cancellation tears down without hanging

    /// A run cancelled mid-flight (slow injected OCR) must tear down its
    /// streams/gates and return promptly rather than deadlock. The race
    /// against a 5s timeout fails the test on a hang instead of stalling the
    /// suite.
    ///
    /// Scope note on the cancellation contract: this validates *external*
    /// task cancellation, which is the reachable path — the extract gate and
    /// embedder pool are cancellation-aware, so a cancelled run unwinds. It
    /// does NOT cover a pre-existing, unrelated embed-stage limitation: if an
    /// `Embedder` were to throw `CancellationError` from `embedDocuments`
    /// *without* the surrounding task actually being cancelled, the embed
    /// task skips its per-chunk `extractGate.release()` while the
    /// embed-spawner is still parked in its `for await batchStream` loop (so
    /// the error never surfaces), and extract stays gate-blocked — a self
    /// deadlock independent of the outer loop's `for try await` vs
    /// `waitForAll()` choice. This is not production-reachable: real embedder
    /// failures throw `EmbedderError`, which the embed stage catches and
    /// turns into nil vectors (still releasing the gate); an embedder only
    /// observes `CancellationError` when its task is genuinely cancelled, in
    /// which case extract is cancelled too and unblocks. Redesigning that
    /// stage is out of scope for OCR concurrency.
    func testPipelineCancellationTearsDownWithoutHang() async throws {
        let extractor = TextExtractor(
            splitter: RecursiveCharacterSplitter(chunkSize: 1200, chunkOverlap: 240),
            textExtraction: .imageOCRV1,
            ocrRecognizer: SlowRecognizer(delaySeconds: 0.2),
            ocrCacheDirectory: nil
        )

        var workItems: [(file: FileInfo, label: String)] = []
        for i in 0..<24 {
            workItems.append((file: try makeImageFile("slow_\(i).png"), label: "Added"))
        }
        for i in 0..<6 {
            workItems.append((file: try makeFile("txt_\(i).txt", content: Data("body \(i)".utf8)), label: "Added"))
        }

        let profile = makeMockProfile()
        let database = VectorDatabase(databaseDirectory: dbDir, sourceDirectory: sourceDir, dimension: 768)
        try await database.initialize()
        let pipeline = IndexingPipeline(
            concurrency: 2, ocrConcurrency: 2, batchSize: 4, bucketWidth: 500, profile: profile
        )

        let runTask = Task {
            _ = try await pipeline.run(workItems: workItems, extractor: extractor, database: database)
        }

        // Let the run get underway, then cancel.
        try await Task.sleep(nanoseconds: 120_000_000)
        runTask.cancel()

        let finishedInTime = await raceCompletion(within: 5.0) {
            _ = try? await runTask.value
        }
        XCTAssertTrue(finishedInTime,
            "pipeline.run must tear down promptly on cancellation, not hang")
    }

    /// A downstream DB-writer error must surface and terminate within the
    /// timeout. Embedding stays healthy and releases backpressure permits;
    /// this verifies error propagation and teardown, but does not distinguish
    /// fail-fast iteration from a drain-all implementation on this small run.
    func testDownstreamDBErrorSurfacesAndTerminates() async throws {
        // Embedder emits 512-dim vectors; the DB is opened at 768, so the DB
        // writer's insert throws `VecError.dimensionMismatch`.
        let factory: @Sendable () -> any Embedder = { WrongDimensionEmbedder() }
        let profile = IndexingProfile(
            identity: "wrongdim@1200/240",
            embedder: factory(),
            embedderFactory: factory,
            splitter: RecursiveCharacterSplitter(chunkSize: 1200, chunkOverlap: 240),
            chunkSize: 1200,
            chunkOverlap: 240,
            isBuiltIn: false
        )
        let extractor = TextExtractor(
            splitter: RecursiveCharacterSplitter(chunkSize: 1200, chunkOverlap: 240),
            textExtraction: .imageOCRV1,
            ocrRecognizer: DeterministicRecognizer(text: "ocr caption"),
            ocrCacheDirectory: nil
        )

        var workItems: [(file: FileInfo, label: String)] = []
        for i in 0..<8 {
            workItems.append((file: try makeImageFile("d_\(i).png"), label: "Added"))
        }
        for i in 0..<8 {
            workItems.append((file: try makeFile("d_\(i).txt", content: Data("body \(i)".utf8)), label: "Added"))
        }

        let database = VectorDatabase(databaseDirectory: dbDir, sourceDirectory: sourceDir, dimension: 768)
        try await database.initialize()
        let pipeline = IndexingPipeline(
            concurrency: 2, ocrConcurrency: 2, batchSize: 4, bucketWidth: 500, profile: profile
        )

        let runTask = Task { () -> Error? in
            do {
                _ = try await pipeline.run(workItems: workItems, extractor: extractor, database: database)
                return nil
            } catch {
                return error
            }
        }

        let finished = await raceCompletion(within: 5.0) { _ = await runTask.value }
        XCTAssertTrue(finished, "a downstream DB error must terminate the run, not hang")
        if finished {
            let thrown = await runTask.value
            XCTAssertNotNil(thrown, "run() must surface the downstream DB error")
        } else {
            runTask.cancel()
        }
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

    /// Races `operation` against a timeout; returns true if it finished first.
    private func raceCompletion(
        within seconds: Double,
        _ operation: @escaping @Sendable () async -> Void
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await operation(); return true }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
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

/// 768-dim mock that emits the *wrong* dimension (512), so the DB writer's
/// insert throws `VecError.dimensionMismatch` — a realistic downstream error
/// where the embed stage itself stays healthy (releases the gate).
private actor WrongDimensionEmbedder: Embedder {
    nonisolated var name: String { "wrongdim-512" }
    nonisolated var dimension: Int { 512 }
    func embedDocument(_ text: String) async throws -> [Float] {
        Array(repeating: Float(0.1), count: 512)
    }
    func embedQuery(_ text: String) async throws -> [Float] {
        Array(repeating: Float(0.1), count: 512)
    }
    func embedDocuments(_ texts: [String]) async throws -> [[Float]] {
        texts.map { _ in Array(repeating: Float(0.1), count: 512) }
    }
}

private struct ProbeError: Error, Equatable {
    let value: Int
}

/// Records peak overlap and total runs across async bodies. `enter`/`leave`
/// bracket each body; because the callers of a serial or bounded window never
/// overlap beyond the bound, the recorded peak reflects the true concurrency.
private actor ConcurrencyRecorder {
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

/// Async rendezvous latch: the first `target` callers each suspend inside
/// `begin()` until all `target` have arrived, at which instant `active ==
/// target`, so `peak` deterministically reaches `target` without any sleep.
/// Callers after the barrier opens proceed immediately. Suspension (not
/// blocking) means it reaches the peak even on a single-thread executor.
/// A two-second deadline opens an under-filled latch too: peak assertions
/// then fail instead of hanging if a regression schedules too few tasks.
private actor RendezvousLatch {
    private let target: Int
    private var arrived = 0
    private var opened = false
    private var timeoutTask: Task<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var active = 0
    private(set) var peak = 0
    private(set) var total = 0

    init(target: Int) { self.target = target }

    func begin() async {
        active += 1
        total += 1
        peak = max(peak, active)
        if opened { return }
        arrived += 1
        if arrived >= target {
            open()
            return
        }
        if timeoutTask == nil {
            timeoutTask = Task {
                do { try await Task.sleep(nanoseconds: 2_000_000_000) }
                catch { return }
                open()
            }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    private func open() {
        guard !opened else { return }
        opened = true
        timeoutTask?.cancel()
        timeoutTask = nil
        let resume = waiters
        waiters.removeAll()
        for continuation in resume { continuation.resume() }
    }

    func end() { active -= 1 }
}

/// One-shot signal used to know a background walk is underway before
/// cancelling it.
private actor OneShotGate {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func signalOnce() {
        guard !signaled else { return }
        signaled = true
        let resume = waiters
        waiters.removeAll()
        for continuation in resume { continuation.resume() }
    }
    func wait() async {
        if signaled { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }
}

/// Synchronous one-shot barrier for the (synchronous) recognizer seam. The
/// first `target` callers block until all `target` have arrived, so the peak
/// reaches `target` deterministically; later callers pass straight through
/// (no per-call timeout tail). A bounded wait means a bug that fans out
/// *below* `target` fails the peak assertion instead of hanging the suite.
private final class OCRBarrier: @unchecked Sendable {
    private let cond = NSCondition()
    private let target: Int
    private let barrierTimeout: TimeInterval
    private var arrived = 0
    private var opened = false
    private var active = 0
    private var peak = 0

    init(target: Int, barrierTimeout: TimeInterval = 2.0) {
        self.target = target
        self.barrierTimeout = barrierTimeout
    }

    func run<T>(_ make: () -> T) -> T {
        cond.lock()
        active += 1
        peak = max(peak, active)
        if target > 1 && !opened {
            arrived += 1
            if arrived >= target {
                opened = true
                cond.broadcast()
            } else {
                let deadline = Date().addingTimeInterval(barrierTimeout)
                while !opened && Date() < deadline { cond.wait(until: deadline) }
                // Give up waiting so a bug fails the peak assertion (peak <
                // target) instead of deadlocking the test.
                opened = true
                cond.broadcast()
            }
        }
        cond.unlock()

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

/// Synchronous serial probe: no rendezvous, just a fixed hold so that any
/// accidental overlap surfaces as peak > 1. Correct (serial) callers yield
/// peak 1 regardless of timing.
private final class SerialHoldProbe: @unchecked Sendable {
    private let cond = NSCondition()
    private let hold: TimeInterval
    private var active = 0
    private var peak = 0

    init(hold: TimeInterval) { self.hold = hold }

    func run<T>(_ make: () -> T) -> T {
        cond.lock()
        active += 1
        peak = max(peak, active)
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

/// Injected recognizer that rendezvous-blocks through an `OCRBarrier`, so the
/// image lane's concurrency is observable without invoking Vision.
private struct BarrierRecognizer: ImageTextRecognizer {
    let barrier: OCRBarrier
    let text: String
    func recognizeText(in imageURL: URL) throws -> ImageOCRResult {
        barrier.run { ImageOCRResult(text: text, lines: [text], paragraphs: [text]) }
    }
}

/// Injected recognizer that routes through a `SerialHoldProbe` — for the
/// default (serial) case, where overlap detection, not rendezvous, is wanted.
private struct SerialHoldRecognizer: ImageTextRecognizer {
    let probe: SerialHoldProbe
    let text: String
    func recognizeText(in imageURL: URL) throws -> ImageOCRResult {
        probe.run { ImageOCRResult(text: text, lines: [text], paragraphs: [text]) }
    }
}

/// Injected recognizer that blocks for a fixed delay, so a run can be
/// cancelled while OCR is in flight.
private struct SlowRecognizer: ImageTextRecognizer {
    let delaySeconds: TimeInterval
    func recognizeText(in imageURL: URL) throws -> ImageOCRResult {
        Thread.sleep(forTimeInterval: delaySeconds)
        return ImageOCRResult(text: "slow", lines: ["slow"], paragraphs: ["slow"])
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
    let probe: SerialHoldProbe
    let marker: String
    func split(_ text: String) -> [TextChunk] {
        guard text.contains(marker) else { return [] }
        return probe.run { [] as [TextChunk] }
    }
}
