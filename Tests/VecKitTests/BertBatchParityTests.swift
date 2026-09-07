import CoreML
import XCTest
@testable import VecKit

final class BertBatchParityTests: XCTestCase {
    func testGTEParityWithAndWithoutPadding() async throws {
        try await assertParity { GTEBaseEmbedder(computePolicy: $0) }
    }

    func testMxbaiParityWithAndWithoutPadding() async throws {
        try await assertParity { MxbaiEmbedLargeEmbedder(computePolicy: $0) }
    }

    func testE5ParityAcrossCharacterLimit() async throws {
        try await assertParity { E5BaseEmbedder(computePolicy: $0) }
    }

    /// In addition to the existing transcript fixture, isolate the no-padding
    /// case: an all-ones mask must not change the public single/batch result.
    /// Then exercise padding, reversed row order, duplicates, empty slots,
    /// and a document exceeding the character cap, on auto and CPU policies.
    private func assertParity(
        makeEmbedder: (MLComputePolicy?) -> any Embedder
    ) async throws {
        let short = "The trademark deal closed at 1.5 million."
        let long = String(repeating: "A longer passage about computers and weather. ", count: 50)
        for policy: MLComputePolicy? in [nil, .cpuOnly] {
            let embedder = makeEmbedder(policy)
            let singleShort = try await embedder.embedDocument(short)
            let singleLong = try await embedder.embedDocument(long)
            let singleton = try await embedder.embedDocuments([short])
            XCTAssertEqual(singleton.count, 1)
            assertSameVector(singleShort, singleton[0], "\(embedder.name) singleton")

            let batch = try await embedder.embedDocuments([short, "", long, " \n", short])
            XCTAssertEqual(batch.count, 5)
            XCTAssertTrue(batch[1].isEmpty)
            XCTAssertTrue(batch[3].isEmpty)
            assertSameVector(singleShort, batch[0], "\(embedder.name) padded short")
            assertSameVector(singleLong, batch[2], "\(embedder.name) long past character limit")
            assertSameVector(singleShort, batch[4], "\(embedder.name) duplicate at final slot")

            let reversed = try await embedder.embedDocuments([long, short])
            XCTAssertEqual(reversed.count, 2)
            assertSameVector(singleLong, reversed[0], "\(embedder.name) reversed long")
            assertSameVector(singleShort, reversed[1], "\(embedder.name) reversed short")
        }
    }

    func testE5PrefixFitsWithinCharacterBudget() {
        for prefix in ["passage: ", "query: "] {
            let contentBudget = E5BaseEmbedder.maxInputCharacters - prefix.count
            for count in [contentBudget - 1, contentBudget, contentBudget + 1, 2_000, 2_100] {
                // Multi-scalar graphemes keep this a character budget test,
                // rather than accidentally pinning byte or UTF-16 counts.
                let text = String(repeating: "👩🏽‍💻", count: count)
                let inputs = E5BaseEmbedder.normalizeInputs([" \n" + text + " \n", "", " \n"], prefix: prefix)
                let expected = String((prefix + text).prefix(E5BaseEmbedder.maxInputCharacters))
                XCTAssertEqual(inputs.liveInputs, [expected])
                XCTAssertEqual(inputs.slots, [expected, nil, nil])
                XCTAssertLessThanOrEqual(expected.count, E5BaseEmbedder.maxInputCharacters)
            }
        }
    }

    func testMxbaiQueryRetainsPrefixAndEmptyInputBehavior() async throws {
        let embedder = MxbaiEmbedLargeEmbedder()
        let text = "The trademark deal closed at 1.5 million."
        let query = try await embedder.embedQuery(" \n" + text + " \n")
        let expected = try await embedder.embedDocument("Represent this sentence for searching relevant passages: " + text)
        assertSameVector(query, expected, "Mxbai query prefix")
        let empty = try await embedder.embedQuery(" \n")
        XCTAssertTrue(empty.isEmpty)
    }

    private func assertSameVector(
        _ expected: [Float], _ actual: [Float], _ context: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertFalse(expected.isEmpty, context, file: file, line: line)
        XCTAssertEqual(actual.count, expected.count, context, file: file, line: line)
        guard !expected.isEmpty, actual.count == expected.count else { return }
        var dot = 0.0, normA = 0.0, normB = 0.0
        for (a, b) in zip(expected, actual) {
            dot += Double(a) * Double(b)
            normA += Double(a) * Double(a)
            normB += Double(b) * Double(b)
        }
        let cosine = dot / (normA.squareRoot() * normB.squareRoot())
        XCTAssertGreaterThanOrEqual(cosine, 0.9999, context, file: file, line: line)
    }
}
