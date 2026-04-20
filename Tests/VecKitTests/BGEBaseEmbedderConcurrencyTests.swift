import XCTest
@testable import VecKit

/// Concurrency canary for the BGE-backed `BGEBaseEmbedder` actor.
///
/// The indexing pipeline fans out embed calls across a `TaskGroup`, so
/// many tasks hit a single shared `BGEBaseEmbedder` at once.
/// `BGEBaseEmbedder` is an `actor`, which serializes calls, but this
/// test exercises that path end-to-end to confirm the underlying
/// `swift-embeddings` MLTensor backend survives it without crashes or
/// length drift.
///
/// Fires 20 concurrent `embedDocument` calls against one shared
/// `BGEBaseEmbedder` and asserts every return value is a 768-dim
/// vector.
final class BGEBaseEmbedderConcurrencyTests: XCTestCase {

    private static let taskCount = 20
    private static let expectedDimension = 768

    func test20ConcurrentEmbedDocumentCallsAllReturn768Dims() async throws {
        let service = BGEBaseEmbedder()

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
