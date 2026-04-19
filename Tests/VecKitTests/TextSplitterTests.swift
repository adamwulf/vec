import XCTest
@testable import VecKit

/// Unit tests for `TextSplitter` implementations. Kept separate from
/// `TextExtractor` tests so splitters can be exercised without file I/O.
final class RecursiveCharacterSplitterTests: XCTestCase {

    // MARK: - Smoke

    func testEmptyTextProducesNoChunks() {
        let splitter = RecursiveCharacterSplitter(chunkSize: 1200, chunkOverlap: 240)
        XCTAssertEqual(splitter.split("").count, 0)
        XCTAssertEqual(splitter.split("   \n\n\t  ").count, 0)
    }

    func testTextUnderChunkSizeProducesNoChunks() {
        // Callers emit a whole-doc chunk when the text fits — the splitter
        // should not duplicate that work.
        let splitter = RecursiveCharacterSplitter(chunkSize: 100, chunkOverlap: 10)
        XCTAssertEqual(splitter.split("short text").count, 0)
    }

    // MARK: - Paragraph / sentence separator priority

    func testSplitsOnParagraphBreaksFirst() {
        let splitter = RecursiveCharacterSplitter(chunkSize: 100, chunkOverlap: 0)
        let paragraph = String(repeating: "word ", count: 30)
        let text = paragraph + "\n\n" + paragraph + "\n\n" + paragraph
        let chunks = splitter.split(text)
        XCTAssertGreaterThanOrEqual(chunks.count, 2)
        // Each chunk respects the size budget (with a small tolerance for
        // single oversize paragraphs — none here).
        for c in chunks {
            XCTAssertLessThanOrEqual(c.text.count, 200)
        }
    }

    func testFallsBackToSentenceBoundariesWhenNoParagraphs() {
        // Long run-on line with only `. ` separators — should still split
        // cleanly rather than mid-word.
        let splitter = RecursiveCharacterSplitter(chunkSize: 200, chunkOverlap: 20)
        let unit = "This is one sentence in the line. "
        let text = String(repeating: unit, count: 40)
        let chunks = splitter.split(text)
        XCTAssertGreaterThan(chunks.count, 1)
        for c in chunks {
            XCTAssertFalse(c.text.isEmpty)
        }
    }

    // MARK: - At-least-one-line invariant

    func testOversizeSingleAtomicLineIsEmittedWhole() {
        // A single 3000-char word with no spaces, no periods. Without a "" fallback
        // separator, the splitter has nothing to split on and must emit it whole.
        let splitter = RecursiveCharacterSplitter(chunkSize: 2000, chunkOverlap: 100)
        let oversize = String(repeating: "x", count: 3000)
        let chunks = splitter.split(oversize)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first?.text.count, 3000)
    }

    // MARK: - Overlap behavior

    func testOverlapProducesCharacterOverlapBetweenAdjacentChunks() {
        let splitter = RecursiveCharacterSplitter(chunkSize: 200, chunkOverlap: 50)
        let sentence = "The quick brown fox jumps over the lazy dog. "
        let text = String(repeating: sentence, count: 40)
        let chunks = splitter.split(text)
        guard chunks.count >= 2 else {
            XCTFail("Expected multiple chunks for overlap test, got \(chunks.count)")
            return
        }
        // The tail of chunk N should appear as a prefix of chunk N+1 for
        // at least some suffix length — this is the overlap guarantee.
        let first = chunks[0].text
        let second = chunks[1].text
        let tailLen = min(30, first.count)
        let tail = String(first.suffix(tailLen))
        XCTAssertTrue(second.contains(tail) || tail.contains(second.prefix(tailLen)),
                      "Expected overlap between consecutive chunks")
    }

    // MARK: - Line number metadata

    func testLineNumbersAreMonotonicAndOneBased() {
        let splitter = RecursiveCharacterSplitter(chunkSize: 300, chunkOverlap: 0)
        let block = String(repeating: "content line.\n", count: 20)
        let text = block + "\n" + block + "\n" + block
        let chunks = splitter.split(text)
        XCTAssertGreaterThan(chunks.count, 0)
        var lastEnd = 0
        for c in chunks {
            guard let s = c.lineStart, let e = c.lineEnd else {
                XCTFail("Every recursive chunk should have lineStart/lineEnd")
                continue
            }
            XCTAssertGreaterThanOrEqual(s, 1, "Line numbers are 1-based")
            XCTAssertGreaterThanOrEqual(e, s, "lineEnd >= lineStart")
            XCTAssertGreaterThanOrEqual(s, lastEnd - 100, "Lines roughly monotonic (overlap allowed)")
            lastEnd = e
        }
    }

    // MARK: - Chunk type

    func testAllProducedChunksAreTypeChunk() {
        let splitter = RecursiveCharacterSplitter(chunkSize: 100, chunkOverlap: 0)
        let text = String(repeating: "paragraph text. ", count: 50) + "\n\n" +
                   String(repeating: "another block. ", count: 50)
        let chunks = splitter.split(text)
        XCTAssertGreaterThan(chunks.count, 0)
        for c in chunks {
            XCTAssertEqual(c.type, .chunk)
        }
    }
}

final class LineBasedSplitterTests: XCTestCase {

    func testFileUnderChunkSizeProducesNoChunks() {
        let splitter = LineBasedSplitter(chunkSize: 30, overlapSize: 8)
        XCTAssertEqual(splitter.split("one\ntwo\nthree").count, 0)
    }

    func testProducesOverlappingChunks() {
        let splitter = LineBasedSplitter(chunkSize: 10, overlapSize: 3)
        let lines = (1...30).map { "line \($0)" }.joined(separator: "\n")
        let chunks = splitter.split(lines)
        XCTAssertGreaterThan(chunks.count, 1)
        // Consecutive chunks should share some lines (overlap).
        for i in 0..<(chunks.count - 1) {
            guard let aEnd = chunks[i].lineEnd, let bStart = chunks[i + 1].lineStart else {
                XCTFail("Expected line numbers on line-based chunks")
                continue
            }
            XCTAssertLessThan(bStart, aEnd, "Consecutive chunks should overlap")
        }
    }

    func testHeadingBoundaryIsPreferredNearTargetEnd() {
        let splitter = LineBasedSplitter(chunkSize: 30, overlapSize: 8)
        // Construct 40 lines with a heading 5 lines before the target end (30).
        var lines: [String] = []
        for i in 1...25 { lines.append("line \(i)") }
        lines.append("# Heading at line 26")
        for i in 27...40 { lines.append("line \(i)") }
        let text = lines.joined(separator: "\n")
        let chunks = splitter.split(text)
        XCTAssertGreaterThan(chunks.count, 0)
        // First chunk should end at or before the heading line.
        XCTAssertLessThanOrEqual(chunks[0].lineEnd ?? Int.max, 26)
    }
}
