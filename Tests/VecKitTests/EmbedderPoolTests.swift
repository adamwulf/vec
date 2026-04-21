import XCTest
@testable import VecKit

/// Unit-level coverage for the in-pipeline `EmbedderPool` actor that
/// gates batched embedding. The pipeline's integration tests cover the
/// happy path indirectly; this file pins the explicit contract:
///
/// 1. `acquire()` hands back exactly the instances the factory minted
///    (no extras, no aliases).
/// 2. After a release cycle, the pool returns the same set of
///    instances (LIFO reuse, no leakage).
/// 3. A waiter parked on `acquire()` is resumed with a specific
///    instance — never a "race for it" permit.
///
/// The release-on-foreign-instance branch hits `assertionFailure` in
/// debug builds, which would crash the test process. We deliberately
/// do NOT exercise it here; that path is covered by code review +
/// the inline doc, and asserting a crash would require a separate
/// process. Future work: lift it to a thrown error if observability
/// matters more than the early-failure signal.
final class EmbedderPoolTests: XCTestCase {

    /// Identity-only embedder. Each instance gets a unique tag from a
    /// monotonic counter so tests can verify "the same instances came
    /// back" by comparing tags.
    private actor TagEmbedder: Embedder {
        nonisolated let name: String
        nonisolated let dimension = 4
        nonisolated let tag: Int
        init(tag: Int) {
            self.tag = tag
            self.name = "tag-\(tag)"
        }
        func embedDocument(_ text: String) async throws -> [Float] {
            return Array(repeating: Float(tag), count: dimension)
        }
        func embedQuery(_ text: String) async throws -> [Float] {
            return Array(repeating: Float(tag), count: dimension)
        }
    }

    /// Thread-safe tag dispenser for the factory.
    private final class TagCounter: @unchecked Sendable {
        private var n = 0
        private let lock = NSLock()
        func next() -> Int {
            lock.lock(); defer { lock.unlock() }
            n += 1
            return n
        }
    }

    func testAcquireReturnsAllNDistinctInstances() async throws {
        let counter = TagCounter()
        let pool = EmbedderPool(factory: { TagEmbedder(tag: counter.next()) }, count: 3)
        var seen = Set<Int>()
        for _ in 0..<3 {
            let e = try await pool.acquire()
            guard let tagged = e as? TagEmbedder else {
                XCTFail("expected TagEmbedder, got \(type(of: e))")
                return
            }
            seen.insert(await tagged.tag)
        }
        XCTAssertEqual(seen.count, 3,
            "pool must hand back N distinct instances, got tags \(seen)")
    }

    func testReleaseRecyclesInstanceForNextAcquire() async throws {
        let counter = TagCounter()
        let pool = EmbedderPool(factory: { TagEmbedder(tag: counter.next()) }, count: 2)
        let a = try await pool.acquire()
        let b = try await pool.acquire()
        // Pool is now empty. Release `a`; next acquire must hand it
        // back (no waiter is parked, so the LIFO path runs).
        await pool.release(a)
        let c = try await pool.acquire()
        guard let aT = a as? TagEmbedder, let cT = c as? TagEmbedder else {
            XCTFail("type mismatch")
            return
        }
        let tagA = await aT.tag
        let tagC = await cT.tag
        XCTAssertEqual(tagA, tagC,
            "release-then-acquire should hand back the same instance (got tag \(tagA) then \(tagC))")
        // Drain to keep the test hygienic.
        await pool.release(b)
        await pool.release(c)
    }

    /// A parked waiter must be resumed with a specific instance the
    /// moment another holder releases — no race-window where a third
    /// caller could steal the slot.
    func testWaiterIsResumedWithReleasedInstance() async throws {
        let counter = TagCounter()
        let pool = EmbedderPool(factory: { TagEmbedder(tag: counter.next()) }, count: 1)
        let first = try await pool.acquire()
        guard let firstT = first as? TagEmbedder else {
            XCTFail("type mismatch")
            return
        }
        let firstTag = await firstT.tag

        // Park a waiter — pool has 0 free, so this suspends.
        async let waitedFor = pool.acquire()

        // Give the waiter a moment to actually enqueue. There is no
        // public hook for "is there a parked waiter yet?", so we
        // yield to let the Task scheduler advance the async let to
        // its suspension point. A tiny sleep is the pragmatic option.
        try? await Task.sleep(nanoseconds: 50_000_000)

        await pool.release(first)
        let resumed = try await waitedFor
        guard let resumedT = resumed as? TagEmbedder else {
            XCTFail("type mismatch")
            return
        }
        let resumedTag = await resumedT.tag
        XCTAssertEqual(firstTag, resumedTag,
            "waiter should be resumed with the same instance that was released; got \(resumedTag) vs released \(firstTag)")
        await pool.release(resumed)
    }

    /// Cancellation safety: a parked waiter must throw
    /// `CancellationError` when the awaiting task is cancelled, not
    /// hang forever. This is the property that lets a `withThrowingTaskGroup`
    /// cascade unwind cleanly when one sibling throws — without it,
    /// the pipeline would deadlock at `group.waitForAll()` (phase-2
    /// review B1).
    func testParkedWaiterThrowsCancellationErrorWhenCancelled() async throws {
        let counter = TagCounter()
        let pool = EmbedderPool(factory: { TagEmbedder(tag: counter.next()) }, count: 1)
        let held = try await pool.acquire()

        // Park a waiter on a Task we control so we can cancel it.
        let waiterTask = Task<Result<any Embedder, any Error>, Never> {
            do {
                let e = try await pool.acquire()
                return .success(e)
            } catch {
                return .failure(error)
            }
        }

        // Give the task time to park on the waiter list.
        try? await Task.sleep(nanoseconds: 50_000_000)

        waiterTask.cancel()
        let outcome = await waiterTask.value
        switch outcome {
        case .success:
            XCTFail("cancelled acquire should not have succeeded")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError,
                "expected CancellationError, got \(error)")
        }
        await pool.release(held)
    }

    func testNameAndDimensionMirrorFirstInstance() async {
        let counter = TagCounter()
        let pool = EmbedderPool(factory: { TagEmbedder(tag: counter.next()) }, count: 4)
        XCTAssertEqual(pool.name, "tag-1",
            "pool.name should expose the first instance's name")
        XCTAssertEqual(pool.dimension, 4,
            "pool.dimension should expose the first instance's dimension")
    }
}
