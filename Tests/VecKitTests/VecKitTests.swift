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

// MARK: - EmbeddingService Tests

final class EmbeddingServiceTests: XCTestCase {

    func testEmbedHelloWorldReturnsNonNilArrayOfDimension512() {
        let service = EmbeddingService()
        let result = service.embed("hello world")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.count, 512)
    }

    func testEmbedEmptyStringReturnsNil() {
        let service = EmbeddingService()
        let result = service.embed("")
        XCTAssertNil(result)
    }

    func testEmbedWhitespaceOnlyReturnsNil() {
        let service = EmbeddingService()
        XCTAssertNil(service.embed("   "))
        XCTAssertNil(service.embed("\t\t"))
        XCTAssertNil(service.embed("\n\n"))
        XCTAssertNil(service.embed("  \n\t  "))
    }

    func testDimensionIs512() {
        let service = EmbeddingService()
        XCTAssertEqual(service.dimension, 512)
    }
}

// MARK: - TextExtractor Tests

final class TextExtractorTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VecKitTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    // Helper to create a file and return a FileInfo
    private func createFile(name: String, content: String) -> FileInfo {
        let url = tempDir.appendingPathComponent(name)
        try! content.write(to: url, atomically: true, encoding: .utf8)
        let modDate = try! url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        return FileInfo(
            relativePath: name,
            url: url,
            modificationDate: modDate,
            fileExtension: url.pathExtension.lowercased()
        )
    }

    // Helper to generate markdown content with a specified number of lines
    private func generateMarkdownLines(_ count: Int) -> String {
        var lines: [String] = ["# Test Document"]
        for i in 2...count {
            if i % 20 == 0 {
                lines.append("## Section \(i / 20)")
            } else {
                lines.append("Line \(i): Some content here for testing purposes.")
            }
        }
        return lines.joined(separator: "\n")
    }

    func testMarkdownLargeFileProducesWholeAndChunks() throws {
        let content = generateMarkdownLines(120)
        let file = createFile(name: "large.md", content: content)
        let extractor = TextExtractor()
        let chunks = try extractor.extract(from: file)

        // Should have a .whole chunk
        let wholeChunks = chunks.filter { $0.type == .whole }
        XCTAssertEqual(wholeChunks.count, 1)

        // Should have multiple .chunk chunks
        let lineChunks = chunks.filter { $0.type == .chunk }
        XCTAssertGreaterThan(lineChunks.count, 1)

        // All line chunks should have valid lineStart/lineEnd
        for chunk in lineChunks {
            XCTAssertNotNil(chunk.lineStart)
            XCTAssertNotNil(chunk.lineEnd)
            XCTAssertGreaterThan(chunk.lineStart!, 0, "lineStart should be 1-based")
            XCTAssertGreaterThanOrEqual(chunk.lineEnd!, chunk.lineStart!)
        }
    }

    func testMarkdownSmallFileProducesOnlyWholeChunk() throws {
        let content = generateMarkdownLines(30)
        let file = createFile(name: "small.md", content: content)
        let extractor = TextExtractor()
        let chunks = try extractor.extract(from: file)

        // Should have exactly one .whole chunk
        let wholeChunks = chunks.filter { $0.type == .whole }
        XCTAssertEqual(wholeChunks.count, 1)

        // No line chunks since it fits in one chunk
        let lineChunks = chunks.filter { $0.type == .chunk }
        XCTAssertEqual(lineChunks.count, 0)
    }

    func testTxtFileProducesOnlyWholeChunk() throws {
        let content = generateMarkdownLines(120) // Even with many lines, .txt doesn't chunk
        let file = createFile(name: "data.txt", content: content)
        let extractor = TextExtractor()
        let chunks = try extractor.extract(from: file)

        let wholeChunks = chunks.filter { $0.type == .whole }
        XCTAssertEqual(wholeChunks.count, 1)

        let lineChunks = chunks.filter { $0.type == .chunk }
        XCTAssertEqual(lineChunks.count, 0)
    }

    func testEmptyFileProducesNoChunks() throws {
        let file = createFile(name: "empty.md", content: "")
        let extractor = TextExtractor()
        let chunks = try extractor.extract(from: file)
        XCTAssertEqual(chunks.count, 0)
    }

    func testWhitespaceOnlyFileProducesNoChunks() throws {
        let file = createFile(name: "whitespace.md", content: "   \n\n  \t  \n")
        let extractor = TextExtractor()
        let chunks = try extractor.extract(from: file)
        XCTAssertEqual(chunks.count, 0)
    }
}

// MARK: - FileScanner Tests

final class FileScannerTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("VecKitScanTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        // Use C realpath to resolve /var -> /private/var, which is needed because
        // FileManager.enumerator returns paths under /private/var on macOS.
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        tempDir = realpath(raw.path, &buf) != nil
            ? URL(fileURLWithPath: String(cString: buf), isDirectory: true)
            : raw
    }

    override func tearDown() {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    private func createFile(at relativePath: String, content: Data) {
        let url = tempDir.appendingPathComponent(relativePath)
        let parent = url.deletingLastPathComponent()
        try! FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try! content.write(to: url)
    }

    private func createTextFile(at relativePath: String, content: String) {
        createFile(at: relativePath, content: content.data(using: .utf8)!)
    }

    func testScanFindsTextFilesAndSkipsGitDirectory() throws {
        createTextFile(at: "readme.md", content: "# Hello")
        createTextFile(at: "main.swift", content: "print(\"hello\")")
        createTextFile(at: "notes.txt", content: "some notes")

        // Create a .git directory with a file inside.
        // FileScanner uses skipsHiddenFiles which skips .git automatically.
        let gitDir = tempDir.appendingPathComponent(".git")
        try! FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        createTextFile(at: ".git/config", content: "[core]\n\tbare = false")

        let scanner = FileScanner(directory: tempDir)
        let files = try scanner.scan()

        let relativePaths = files.map { $0.relativePath }

        XCTAssertTrue(relativePaths.contains("readme.md"), "Expected readme.md, got: \(relativePaths)")
        XCTAssertTrue(relativePaths.contains("main.swift"), "Expected main.swift, got: \(relativePaths)")
        XCTAssertTrue(relativePaths.contains("notes.txt"), "Expected notes.txt, got: \(relativePaths)")

        // .git directory contents should not appear
        XCTAssertFalse(relativePaths.contains(where: { $0.contains(".git") }))
    }

    func testScanSkipsBinaryFiles() throws {
        createTextFile(at: "hello.txt", content: "hello world")

        // Create a binary file with null bytes
        var binaryData = Data("some binary content".utf8)
        binaryData.append(contentsOf: [0x00, 0x00, 0x00])
        binaryData.append(Data("more content".utf8))
        createFile(at: "image.xyz", content: binaryData)

        let scanner = FileScanner(directory: tempDir)
        let files = try scanner.scan()
        let relativePaths = files.map { $0.relativePath }

        XCTAssertTrue(relativePaths.contains("hello.txt"), "Expected hello.txt, got: \(relativePaths)")
        // The binary file has an unknown extension and contains null bytes,
        // so isLikelyTextFile should return false and it should be skipped
        XCTAssertFalse(relativePaths.contains("image.xyz"))
    }

    func testFileInfoForRelativeTo() throws {
        createTextFile(at: "subdir/test.swift", content: "import Foundation")

        let fileURL = tempDir.appendingPathComponent("subdir/test.swift")
        let info = try FileScanner.fileInfo(for: fileURL, relativeTo: tempDir)

        XCTAssertEqual(info.relativePath, "subdir/test.swift")
        XCTAssertEqual(info.fileExtension, "swift")
        XCTAssertEqual(info.url, fileURL)
        XCTAssertNotNil(info.modificationDate)
    }

    func testScanSkipsNodeModules() throws {
        createTextFile(at: "app.js", content: "console.log('hi')")
        createTextFile(at: "node_modules/pkg/index.js", content: "module.exports = {}")

        let scanner = FileScanner(directory: tempDir)
        let files = try scanner.scan()
        let relativePaths = files.map { $0.relativePath }

        XCTAssertTrue(relativePaths.contains("app.js"), "Expected app.js, got: \(relativePaths)")
        XCTAssertFalse(relativePaths.contains(where: { $0.hasPrefix("node_modules") }))
    }
}

// MARK: - ChunkingStrategy Edge Cases

final class ChunkingStrategyTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VecKitChunkTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    private func createFile(name: String, content: String) -> FileInfo {
        let url = tempDir.appendingPathComponent(name)
        try! content.write(to: url, atomically: true, encoding: .utf8)
        let modDate = try! url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        return FileInfo(
            relativePath: name,
            url: url,
            modificationDate: modDate,
            fileExtension: url.pathExtension.lowercased()
        )
    }

    func testOverlappingChunksSecondChunkStartsAtLine41() throws {
        // Generate exactly 100 lines of plain markdown (no headings except line 1)
        // to avoid heading-boundary adjustments
        var lines: [String] = []
        for i in 1...100 {
            lines.append("Line \(i): content for testing overlap behavior.")
        }
        let content = lines.joined(separator: "\n")
        let file = createFile(name: "overlap.md", content: content)

        // Use default chunkSize=50, overlapSize=10 => advance = 40
        let extractor = TextExtractor(chunkSize: 50, overlapSize: 10)
        let chunks = try extractor.extract(from: file)
        let lineChunks = chunks.filter { $0.type == .chunk }

        XCTAssertGreaterThanOrEqual(lineChunks.count, 2, "Should have at least 2 line chunks for 100 lines")

        // First chunk starts at line 1 (0-indexed start=0, 1-based lineStart=1)
        XCTAssertEqual(lineChunks[0].lineStart, 1)

        // With advance=40 (chunkSize 50 - overlap 10), second chunk starts at 0-indexed 40 => 1-based 41
        XCTAssertEqual(lineChunks[1].lineStart, 41)
    }

    func testHeadingBoundarySplitting() throws {
        // Create a markdown file where a heading appears near the chunk boundary.
        // Default chunkSize=50, so the first chunk tries to end at line 50 (0-indexed).
        // We put a heading at line 46 (0-indexed 45) which is within the search window
        // (searchStart = max(50-10, 0) = 40, so we search lines 50 down to 40).
        // The heading at 0-indexed 45 should cause the chunk to end at that line.
        var lines: [String] = []
        for i in 1...80 {
            if i == 46 {
                lines.append("# Heading at line 46")
            } else {
                lines.append("Line \(i): regular content without heading markers.")
            }
        }
        let content = lines.joined(separator: "\n")
        let file = createFile(name: "heading.md", content: content)

        let extractor = TextExtractor(chunkSize: 50, overlapSize: 10)
        let chunks = try extractor.extract(from: file)
        let lineChunks = chunks.filter { $0.type == .chunk }

        XCTAssertGreaterThanOrEqual(lineChunks.count, 1)

        // The first chunk should end at line 45 (0-indexed) because the heading at
        // 0-indexed 45 causes `end = i` where i=45, so lineEnd = 45
        // (lineEnd is set to `end` which is the exclusive upper bound used as the 1-based end)
        let firstChunk = lineChunks[0]
        XCTAssertEqual(firstChunk.lineStart, 1)
        // The chunk should end before the heading line (end = 45 in 0-indexed,
        // which means lineEnd = 45 in the code since lineEnd = end)
        XCTAssertEqual(firstChunk.lineEnd, 45,
                       "First chunk should end at heading boundary (line 45)")
    }

    func testCustomChunkAndOverlapSizes() throws {
        // Use a smaller chunk size to verify configurability
        var lines: [String] = []
        for i in 1...50 {
            lines.append("Line \(i): content.")
        }
        let content = lines.joined(separator: "\n")
        let file = createFile(name: "custom.md", content: content)

        let extractor = TextExtractor(chunkSize: 20, overlapSize: 5)
        let chunks = try extractor.extract(from: file)
        let lineChunks = chunks.filter { $0.type == .chunk }

        // 50 lines with chunkSize=20, advance=15
        // Chunks start at: 0, 15, 30, 45 (0-indexed)
        // That's at least 4 chunks
        XCTAssertGreaterThanOrEqual(lineChunks.count, 3)

        // First chunk starts at 1, second at 16 (1-based)
        XCTAssertEqual(lineChunks[0].lineStart, 1)
        XCTAssertEqual(lineChunks[1].lineStart, 16)
    }
}
