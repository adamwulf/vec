import XCTest
@testable import VecKit

final class VTTExtractionTests: XCTestCase {
    private func extract(_ source: String, extension ext: String = "vtt",
                         mode: TextExtractionMode = .vttV1,
                         splitter: any TextSplitter = RecursiveCharacterSplitter(chunkSize: 120, chunkOverlap: 0)) throws -> ExtractionResult {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("captions.\(ext)")
        try source.write(to: url, atomically: true, encoding: .utf8)
        return try TextExtractor(splitter: splitter, textExtraction: mode)
            .extract(from: FileScanner.fileInfo(for: url, relativeTo: root))
    }

    func testNormalizationPrecedesChunkingAndPreservesRawLineCount() throws {
        let source = "WEBVTT\n\n\(String(repeating: "identifier", count: 30))\n00:00.000 --> 00:02.000 align:start\nHello\nworld\n"
        let result = try extract(source)
        XCTAssertEqual(result.linePageCount, 6)
        XCTAssertEqual(result.chunks.count, 1)
        XCTAssertEqual(result.chunks.first?.type, .whole)
        XCTAssertEqual(result.chunks.first?.text, "Hello world")
        XCTAssertNil(result.chunks.first?.lineStart)
        XCTAssertGreaterThan(try extract(source, mode: .raw).chunks.count, 1)
    }

    func testModesAndExtensionsAreIsolated() throws {
        let source = "WEBVTT\n\n00:00.000 --> 00:02.000\nHello"
        for mode in [TextExtractionMode.vttV1, .markdownV1VttV1] {
            for ext in ["vtt", "VTT"] {
                XCTAssertEqual(try extract(source, extension: ext, mode: mode).chunks.first?.text, "Hello")
            }
        }
        for mode in [TextExtractionMode.raw, .markdownV1] {
            XCTAssertEqual(try extract(source, mode: mode).chunks.first?.text, source)
        }
        for ext in ["txt", "md", "swift", "json", "srt"] {
            XCTAssertEqual(try extract(source, extension: ext).chunks.first?.text, source)
        }
        let markdown = "[label](https://example.com)"
        XCTAssertEqual(try extract(markdown, extension: "md").chunks.first?.text, markdown)
        XCTAssertEqual(try extract(markdown, extension: "md", mode: .markdownV1VttV1).chunks.first?.text, "label")
    }

    func testStructuralOnlyFilesHaveNoChunks() throws {
        let result = try extract("WEBVTT\n\nNOTE no speech\nmetadata\n")
        XCTAssertTrue(result.chunks.isEmpty)
        XCTAssertEqual(result.linePageCount, 4)
    }

    func testSplitPassagesMapBackToCueTimingAndPayloadLines() throws {
        for newline in ["\n", "\r\n", "\r"] {
            let sourceLines = ["WEBVTT", ""] + (0..<4).flatMap { index in
                ["id\(index)", "00:\(String(format: "%02d", index * 10)).000 --> 00:\(String(format: "%02d", index * 10 + 2)).000",
                 "<v Speaker\(index)>marker\(index) starts a passage with enough unique words to force splitting into smaller chunks.", ""]
            }
            let splitters: [any TextSplitter] = [
                RecursiveCharacterSplitter(chunkSize: 70, chunkOverlap: 15),
                LineBasedSplitter(chunkSize: 2, overlapSize: 1)
            ]
            for splitter in splitters {
                let result = try extract(sourceLines.joined(separator: newline), splitter: splitter)
                XCTAssertEqual(result.linePageCount, sourceLines.count - 1)
                let chunks = result.chunks.filter { $0.type == .chunk }
                XCTAssertGreaterThan(chunks.count, 1)
                for chunk in chunks {
                    let start = try XCTUnwrap(chunk.lineStart)
                    let end = try XCTUnwrap(chunk.lineEnd)
                    XCTAssertTrue(sourceLines[start - 1].contains("-->"))
                    XCTAssertTrue(sourceLines[end - 1].contains("passage"))
                    XCTAssertGreaterThanOrEqual(end, start)
                    for index in 0..<4 where chunk.text.contains("marker\(index)") {
                        XCTAssertLessThanOrEqual(start, 4 + index * 4)
                        XCTAssertGreaterThanOrEqual(end, 5 + index * 4)
                    }
                }
            }
        }
    }
}
