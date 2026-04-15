import XCTest
@testable import VecKit

final class VecKitTests: XCTestCase {

    func testChunkTypeRawValues() {
        XCTAssertEqual(ChunkType.whole.rawValue, "whole")
        XCTAssertEqual(ChunkType.chunk.rawValue, "chunk")
        XCTAssertEqual(ChunkType.pdfPage.rawValue, "pdf_page")
    }

    func testTextChunkCreation() {
        let chunk = TextChunk(text: "Hello world", type: .whole)
        XCTAssertEqual(chunk.text, "Hello world")
        XCTAssertEqual(chunk.type, .whole)
        XCTAssertNil(chunk.lineStart)
        XCTAssertNil(chunk.lineEnd)
        XCTAssertNil(chunk.pageNumber)
    }

    func testTextChunkWithLineRange() {
        let chunk = TextChunk(text: "Some text", type: .chunk, lineStart: 1, lineEnd: 50)
        XCTAssertEqual(chunk.lineStart, 1)
        XCTAssertEqual(chunk.lineEnd, 50)
    }
}
