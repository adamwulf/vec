import XCTest
@testable import VecKit

final class SearchResultCoalescerTests: XCTestCase {

    // MARK: - Helpers

    private func makeResult(filePath: String, distance: Double, lineStart: Int? = nil, lineEnd: Int? = nil) -> SearchResult {
        SearchResult(
            filePath: filePath,
            lineStart: lineStart,
            lineEnd: lineEnd,
            chunkType: .chunk,
            pageNumber: nil,
            contentPreview: nil,
            distance: distance
        )
    }

    // MARK: - Tests

    func testEmptyInputReturnsEmptyOutput() {
        let groups = SearchResultCoalescer.coalesce([], limit: 10)
        XCTAssertTrue(groups.isEmpty)
    }

    func testSingleResultReturnsSingleGroup() {
        let results = [makeResult(filePath: "a.swift", distance: 0.2)]
        let groups = SearchResultCoalescer.coalesce(results, limit: 10)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].filePath, "a.swift")
        XCTAssertEqual(groups[0].bestScore, 0.8, accuracy: 1e-9)
        XCTAssertEqual(groups[0].matches.count, 1)
    }

    func testMultipleResultsFromSameFileGetGrouped() {
        let results = [
            makeResult(filePath: "a.swift", distance: 0.3, lineStart: 1, lineEnd: 10),
            makeResult(filePath: "a.swift", distance: 0.1, lineStart: 20, lineEnd: 30),
            makeResult(filePath: "a.swift", distance: 0.5, lineStart: 40, lineEnd: 50)
        ]
        let groups = SearchResultCoalescer.coalesce(results, limit: 10)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].filePath, "a.swift")
        XCTAssertEqual(groups[0].matches.count, 3)
        // Best score should be 1.0 - 0.1 = 0.9
        XCTAssertEqual(groups[0].bestScore, 0.9, accuracy: 1e-9)
    }

    func testMatchesSortedByScoreDescending() {
        let results = [
            makeResult(filePath: "a.swift", distance: 0.5, lineStart: 1, lineEnd: 10),
            makeResult(filePath: "a.swift", distance: 0.1, lineStart: 20, lineEnd: 30),
            makeResult(filePath: "a.swift", distance: 0.3, lineStart: 40, lineEnd: 50)
        ]
        let groups = SearchResultCoalescer.coalesce(results, limit: 10)

        XCTAssertEqual(groups[0].matches.count, 3)
        // Matches should be sorted: distance 0.1, 0.3, 0.5 (best score first)
        XCTAssertEqual(groups[0].matches[0].distance, 0.1, accuracy: 1e-9)
        XCTAssertEqual(groups[0].matches[1].distance, 0.3, accuracy: 1e-9)
        XCTAssertEqual(groups[0].matches[2].distance, 0.5, accuracy: 1e-9)
    }

    func testGroupsSortedByBestScoreDescending() {
        let results = [
            makeResult(filePath: "c.swift", distance: 0.8),  // score 0.2
            makeResult(filePath: "a.swift", distance: 0.1),  // score 0.9
            makeResult(filePath: "b.swift", distance: 0.4)   // score 0.6
        ]
        let groups = SearchResultCoalescer.coalesce(results, limit: 10)

        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups[0].filePath, "a.swift")
        XCTAssertEqual(groups[1].filePath, "b.swift")
        XCTAssertEqual(groups[2].filePath, "c.swift")
    }

    func testLimitControlsMaxNumberOfGroups() {
        let results = [
            makeResult(filePath: "a.swift", distance: 0.1),
            makeResult(filePath: "b.swift", distance: 0.2),
            makeResult(filePath: "c.swift", distance: 0.3),
            makeResult(filePath: "d.swift", distance: 0.4),
            makeResult(filePath: "e.swift", distance: 0.5)
        ]
        let groups = SearchResultCoalescer.coalesce(results, limit: 3)

        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups[0].filePath, "a.swift")
        XCTAssertEqual(groups[1].filePath, "b.swift")
        XCTAssertEqual(groups[2].filePath, "c.swift")
    }

    func testLimitLargerThanGroupCountReturnsAllGroups() {
        let results = [
            makeResult(filePath: "a.swift", distance: 0.1),
            makeResult(filePath: "b.swift", distance: 0.2)
        ]
        let groups = SearchResultCoalescer.coalesce(results, limit: 100)

        XCTAssertEqual(groups.count, 2)
    }

    func testScoresClampedToNonNegative() {
        // Distance > 1.0 would produce a negative score without clamping
        let results = [makeResult(filePath: "a.swift", distance: 1.5)]
        let groups = SearchResultCoalescer.coalesce(results, limit: 10)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].bestScore, 0.0, accuracy: 1e-9)
    }

    func testMixedFilesGroupedAndSortedCorrectly() {
        let results = [
            makeResult(filePath: "views.swift", distance: 0.3, lineStart: 1, lineEnd: 20),
            makeResult(filePath: "models.swift", distance: 0.1, lineStart: 10, lineEnd: 30),
            makeResult(filePath: "views.swift", distance: 0.6, lineStart: 25, lineEnd: 40),
            makeResult(filePath: "models.swift", distance: 0.4, lineStart: 50, lineEnd: 60),
            makeResult(filePath: "tests.swift", distance: 0.2, lineStart: 1, lineEnd: 10)
        ]
        let groups = SearchResultCoalescer.coalesce(results, limit: 10)

        XCTAssertEqual(groups.count, 3)

        // models.swift has best score: 1.0 - 0.1 = 0.9
        XCTAssertEqual(groups[0].filePath, "models.swift")
        XCTAssertEqual(groups[0].bestScore, 0.9, accuracy: 1e-9)
        XCTAssertEqual(groups[0].matches.count, 2)

        // tests.swift has best score: 1.0 - 0.2 = 0.8
        XCTAssertEqual(groups[1].filePath, "tests.swift")
        XCTAssertEqual(groups[1].bestScore, 0.8, accuracy: 1e-9)
        XCTAssertEqual(groups[1].matches.count, 1)

        // views.swift has best score: 1.0 - 0.3 = 0.7
        XCTAssertEqual(groups[2].filePath, "views.swift")
        XCTAssertEqual(groups[2].bestScore, 0.7, accuracy: 1e-9)
        XCTAssertEqual(groups[2].matches.count, 2)
    }

    func testZeroDistanceProducesScoreOfOne() {
        let results = [makeResult(filePath: "perfect.swift", distance: 0.0)]
        let groups = SearchResultCoalescer.coalesce(results, limit: 10)

        XCTAssertEqual(groups[0].bestScore, 1.0, accuracy: 1e-9)
    }

    func testLimitOfZeroReturnsEmpty() {
        let results = [makeResult(filePath: "a.swift", distance: 0.1)]
        let groups = SearchResultCoalescer.coalesce(results, limit: 0)

        XCTAssertTrue(groups.isEmpty)
    }
}
