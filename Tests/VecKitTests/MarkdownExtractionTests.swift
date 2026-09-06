import XCTest
@testable import VecKit

final class MarkdownExtractionTests: XCTestCase {
    private func extract(_ source: String, extension ext: String = "md",
                         mode: TextExtractionMode = .markdownV1,
                         chunkSize: Int = 120) throws -> ExtractionResult {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("document.\(ext)")
        try source.write(to: url, atomically: true, encoding: .utf8)
        return try TextExtractor(
            splitter: RecursiveCharacterSplitter(chunkSize: chunkSize, chunkOverlap: 0),
            textExtraction: mode
        ).extract(from: FileScanner.fileInfo(for: url, relativeTo: root))
    }

    func testNormalizationPrecedesChunkingAndRetainsSourceLineCount() throws {
        let source = "[hello](https://example.com/\(String(repeating: "x", count: 300)))\nworld\n"
        let normalized = try extract(source)
        let raw = try extract(source, mode: .raw)
        XCTAssertEqual(normalized.linePageCount, 2)
        XCTAssertEqual(normalized.chunks.count, 1, "Clean text fits in the whole-document chunk")
        XCTAssertEqual(normalized.chunks.first?.type, .whole)
        XCTAssertTrue(normalized.chunks[0].text.contains("hello"))
        XCTAssertFalse(normalized.chunks[0].text.contains("https://"))
        XCTAssertGreaterThan(raw.chunks.count, 1)
    }

    func testModeDoesNotChangeOtherTextFormats() throws {
        let source = "[literal source](https://example.com)\nlet value = 42"
        for ext in ["txt", "swift", "json"] {
            let result = try extract(source, extension: ext)
            XCTAssertEqual(result.chunks.first?.text, source)
        }
        let rawMarkdown = try extract(source, mode: .raw)
        XCTAssertEqual(rawMarkdown.chunks.first?.text, source)
    }

    func testMarkdownExtensionIsRecognized() throws {
        let result = try extract("[label](https://example.com)", extension: "markdown")
        XCTAssertEqual(result.chunks.first?.text, "label")
    }

    func testNormalizedPassagesPointToOriginalSourceLines() throws {
        // Unique line labels expose offsets that drift after stripping long URLs.
        for newline in ["\n", "\r\n"] {
            let lines = (1...12).map { number in
                "[cue\(number)](https://example.com/\(String(repeating: "path/", count: 15))) sentence number \(number) has useful content."
            }
            let result = try extract(lines.joined(separator: newline), chunkSize: 115)
            XCTAssertEqual(result.linePageCount, lines.count)
            let passages = result.chunks.filter { $0.type == .chunk }
            XCTAssertGreaterThan(passages.count, 1)
            var seen = Set<Int>()
            for passage in passages {
                let start = try XCTUnwrap(passage.lineStart)
                let end = try XCTUnwrap(passage.lineEnd)
                XCTAssertTrue((1...lines.count).contains(start))
                XCTAssertTrue((start...lines.count).contains(end))
                for number in 1...12 where passage.text.contains("cue\(number) ") {
                    XCTAssertTrue((start...end).contains(number), "Wrong source range for cue\(number): \(start)-\(end)")
                    seen.insert(number)
                }
            }
            XCTAssertEqual(seen, Set(1...12))
        }
    }
}
