import XCTest
@testable import VecKit

/// Concurrency canary for the `NLEmbedder` actor, mirroring
/// `NomicEmbedderConcurrencyTests`.
///
/// `NLEmbedding.sentenceEmbedding` is documented as not thread-safe,
/// so `NLEmbedder` serializes calls via actor isolation. This test
/// fans out 20 concurrent `embedDocument` calls against a single
/// shared `NLEmbedder` and confirms every result is a 512-dim vector
/// with no crashes or length drift.
final class NLEmbedderConcurrencyTests: XCTestCase {

    private static let taskCount = 20
    private static let expectedDimension = 512

    func test20ConcurrentEmbedDocumentCallsAllReturn512Dims() async throws {
        let service = NLEmbedder()

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
