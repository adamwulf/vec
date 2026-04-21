import XCTest
@testable import VecKit

/// Concurrency canary for the Apple-backed `NLContextualEmbedder` actor.
///
/// The indexing pipeline fans out embed calls across a `TaskGroup`, so
/// many tasks hit a single shared `NLContextualEmbedder` at once.
/// `NLContextualEmbedder` is an `actor`, which serializes calls, but
/// this test exercises that path end-to-end to confirm the underlying
/// `NLContextualEmbedding` asset-load + embed path survives it without
/// crashes or length drift.
///
/// Fires 20 concurrent `embedDocument` calls against one shared
/// `NLContextualEmbedder` and asserts every return value is a 512-dim
/// vector.
final class NLContextualEmbedderConcurrencyTests: XCTestCase {

    private static let taskCount = 20
    private static let expectedDimension = 512

    func test20ConcurrentEmbedDocumentCallsAllReturn512Dims() async throws {
        let service = NLContextualEmbedder()

        let lengths: [Int] = try await withThrowingTaskGroup(of: Int.self) { group in
            for i in 0..<Self.taskCount {
                group.addTask {
                    let vector = try await service.embedDocument("warmup test \(i)")
                    return vector.count
                }
            }
            var collected: [Int] = []
            for try await count in group {
                collected.append(count)
            }
            return collected
        }

        XCTAssertEqual(lengths.count, Self.taskCount,
                       "All tasks should complete")
        for length in lengths {
            XCTAssertEqual(length, Self.expectedDimension,
                           "Every embed call should return a \(Self.expectedDimension)-dim vector")
        }
    }
}
