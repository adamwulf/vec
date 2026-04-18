import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import VecKit

final class VecKitTests: XCTestCase {

    func testChunkTypeRawValues() {
        XCTAssertEqual(ChunkType.whole.rawValue, "whole")
        XCTAssertEqual(ChunkType.chunk.rawValue, "chunk")
        XCTAssertEqual(ChunkType.pdfPage.rawValue, "pdf_page")
        XCTAssertEqual(ChunkType.image.rawValue, "image")
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

// MARK: - NomicEmbedder Tests

final class NomicEmbedderTests: XCTestCase {

    func testEmbedDocumentReturnsArrayOfDimension768() async throws {
        let service = NomicEmbedder()
        let result = try await service.embedDocument("hello world")
        XCTAssertEqual(result.count, 768)
    }

    func testEmbedQueryReturnsArrayOfDimension768() async throws {
        let service = NomicEmbedder()
        let result = try await service.embedQuery("hello world")
        XCTAssertEqual(result.count, 768)
    }

    func testEmbedEmptyStringReturnsEmpty() async throws {
        let service = NomicEmbedder()
        let result = try await service.embedDocument("")
        XCTAssertEqual(result.count, 0)
    }

    func testEmbedWhitespaceOnlyReturnsEmpty() async throws {
        let service = NomicEmbedder()
        let r1 = try await service.embedDocument("   ")
        XCTAssertEqual(r1.count, 0)
        let r2 = try await service.embedDocument("\t\t")
        XCTAssertEqual(r2.count, 0)
        let r3 = try await service.embedDocument("\n\n")
        XCTAssertEqual(r3.count, 0)
        let r4 = try await service.embedDocument("  \n\t  ")
        XCTAssertEqual(r4.count, 0)
    }

    func testEmbedVeryLongTextDoesNotCrashAndReturns768() async throws {
        let service = NomicEmbedder()
        let longText = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 5000)
        XCTAssertGreaterThan(longText.count, NomicEmbedder.maxInputCharacters)
        let result = try await service.embedDocument(longText)
        XCTAssertEqual(result.count, 768)
    }

    func testDimensionIs768() {
        XCTAssertEqual(NomicEmbedder().dimension, 768)
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
        let chunks = try extractor.extract(from: file).chunks

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

    func testSmallFileProducesOnlyWholeChunk() throws {
        // A file with fewer lines than the default chunk size (30) should only have a .whole chunk
        let content = "Line 1\nLine 2\nLine 3"
        let file = createFile(name: "small.md", content: content)
        let extractor = TextExtractor()
        let chunks = try extractor.extract(from: file).chunks

        // Should have exactly one .whole chunk
        let wholeChunks = chunks.filter { $0.type == .whole }
        XCTAssertEqual(wholeChunks.count, 1)

        // No line chunks since it fits in one chunk
        let lineChunks = chunks.filter { $0.type == .chunk }
        XCTAssertEqual(lineChunks.count, 0)
    }

    func testTxtFileAlsoProducesChunks() throws {
        let content = generateMarkdownLines(120) // All text files now get chunked
        let file = createFile(name: "data.txt", content: content)
        let extractor = TextExtractor()
        let chunks = try extractor.extract(from: file).chunks

        let wholeChunks = chunks.filter { $0.type == .whole }
        XCTAssertEqual(wholeChunks.count, 1)

        // .txt files should now also produce line chunks
        let lineChunks = chunks.filter { $0.type == .chunk }
        XCTAssertGreaterThan(lineChunks.count, 0)
    }

    func testEmptyFileProducesNoChunks() throws {
        let file = createFile(name: "empty.md", content: "")
        let extractor = TextExtractor()
        let chunks = try extractor.extract(from: file).chunks
        XCTAssertEqual(chunks.count, 0)
    }

    func testWhitespaceOnlyFileProducesNoChunks() throws {
        let file = createFile(name: "whitespace.md", content: "   \n\n  \t  \n")
        let extractor = TextExtractor()
        let chunks = try extractor.extract(from: file).chunks
        XCTAssertEqual(chunks.count, 0)
    }

    func testMarkdownWithOnlyHeadingsProducesChunks() throws {
        // A markdown file with headings and no body text should still produce chunks
        let content = """
        # Introduction
        ## Background
        ### Details
        ## Summary
        """
        let file = createFile(name: "headings_only.md", content: content)
        let extractor = TextExtractor()
        let chunks = try extractor.extract(from: file).chunks

        // Should produce at least a whole-document chunk
        let wholeChunks = chunks.filter { $0.type == .whole }
        XCTAssertEqual(wholeChunks.count, 1)
        XCTAssertFalse(wholeChunks[0].text.isEmpty)
    }

    func testMarkdownWhereEveryLineIsAHeading() throws {
        // Generate enough heading lines that the file exceeds the default
        // `RecursiveCharacterSplitter` chunk size of 2000 chars.
        // Target: > 2000 chars (to trigger chunking) but under the
        // embedder's input cap (so the whole-doc chunk is not suppressed).
        var lines: [String] = []
        for i in 1...100 {
            lines.append("# Heading line number \(i) with some descriptive content")
        }
        let content = lines.joined(separator: "\n")
        let file = createFile(name: "all_headings.md", content: content)
        let extractor = TextExtractor()
        let chunks = try extractor.extract(from: file).chunks

        let wholeChunks = chunks.filter { $0.type == .whole }
        XCTAssertEqual(wholeChunks.count, 1)

        let lineChunks = chunks.filter { $0.type == .chunk }
        XCTAssertGreaterThan(lineChunks.count, 0)

        for chunk in lineChunks {
            XCTAssertNotNil(chunk.lineStart)
            XCTAssertNotNil(chunk.lineEnd)
            XCTAssertGreaterThanOrEqual(chunk.lineEnd!, chunk.lineStart!)
        }
    }

    func testVeryLongSingleLineProducesWholeAndSentenceChunks() throws {
        // A single very long line with no newlines, but with sentence
        // boundaries ("`. `"). The default `RecursiveCharacterSplitter`
        // should emit a whole-doc chunk plus sentence-boundary sub-chunks.
        // Length kept under NomicEmbedder.maxInputCharacters so the
        // whole-chunk guard does not suppress the .whole chunk.
        let unit = "This is a very long sentence without any newlines. "
        let repeatCount = max(1, (NomicEmbedder.maxInputCharacters / unit.count) - 10)
        let longLine = String(repeating: unit, count: repeatCount)
        let file = createFile(name: "long_line.md", content: longLine)
        let extractor = TextExtractor()
        let chunks = try extractor.extract(from: file).chunks

        let wholeChunks = chunks.filter { $0.type == .whole }
        XCTAssertEqual(wholeChunks.count, 1)

        let lineChunks = chunks.filter { $0.type == .chunk }
        XCTAssertGreaterThan(lineChunks.count, 1,
                             "Oversize single line should split on sentence boundaries")
        // Each sub-chunk should be reasonably sized — no mid-word splits.
        for chunk in lineChunks {
            XCTAssertLessThanOrEqual(chunk.text.count,
                                     RecursiveCharacterSplitter.defaultChunkSize + unit.count,
                                     "Chunk should not grossly exceed chunkSize")
        }
    }

    func testLineBasedSplitterLongSingleLineProducesNoChunks() throws {
        // Legacy LineBasedSplitter preserved behavior: a 1-line file under
        // the configured line-count threshold produces no line chunks.
        let longLine = String(repeating: "word ", count: 500)
        let file = createFile(name: "long_line.md", content: longLine)
        let extractor = TextExtractor(splitter: LineBasedSplitter())
        let chunks = try extractor.extract(from: file).chunks

        let lineChunks = chunks.filter { $0.type == .chunk }
        XCTAssertEqual(lineChunks.count, 0)
    }

    func testBinaryFileReturnsEmptyArray() throws {
        // Create a binary file with null bytes — extract() should return empty
        let url = tempDir.appendingPathComponent("binary.bin")
        var data = Data("some content".utf8)
        data.append(contentsOf: [0x00, 0x00, 0xFF, 0xFE])
        data.append(Data("more binary".utf8))
        try! data.write(to: url)
        let modDate = try! url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        let file = FileInfo(
            relativePath: "binary.bin",
            url: url,
            modificationDate: modDate,
            fileExtension: "bin"
        )
        let extractor = TextExtractor()
        let chunks = try extractor.extract(from: file).chunks
        // Binary file cannot be read as UTF-8, so extract() should return empty
        XCTAssertEqual(chunks.count, 0)
    }

    // MARK: - PDF Extraction Tests

    private func pdfFixtureURL() -> URL {
        Bundle.module.url(forResource: "MobyDick", withExtension: "pdf", subdirectory: "Fixtures")!
    }

    private func pdfFileInfo() -> FileInfo {
        let url = pdfFixtureURL()
        let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        return FileInfo(relativePath: "MobyDick.pdf", url: url, modificationDate: modDate, fileExtension: "pdf")
    }

    func testPDFExtractionProducesPageChunks() throws {
        let file = pdfFileInfo()
        let extractor = TextExtractor()
        let chunks = try extractor.extract(from: file).chunks

        // Should have at least one chunk
        XCTAssertGreaterThan(chunks.count, 0)

        // Page chunks should be present
        let pageChunks = chunks.filter { $0.type == .pdfPage }
        XCTAssertGreaterThan(pageChunks.count, 0)

        // A whole-document chunk is only produced when the combined page text
        // fits within NomicEmbedder.maxInputCharacters. The Moby Dick
        // fixture exceeds that limit, so no `.whole` chunk should be emitted.
        let totalText = pageChunks.map(\.text).joined(separator: "\n")
        if totalText.count <= NomicEmbedder.maxInputCharacters {
            XCTAssertEqual(chunks[0].type, .whole)
            XCTAssertNil(chunks[0].pageNumber)
            XCTAssertFalse(chunks[0].text.isEmpty)
        } else {
            XCTAssertFalse(chunks.contains { $0.type == .whole })
        }
    }

    func testPDFPageChunksHaveCorrectPageNumbers() throws {
        let file = pdfFileInfo()
        let extractor = TextExtractor()
        let chunks = try extractor.extract(from: file).chunks

        let pageChunks = chunks.filter { $0.type == .pdfPage }

        // All page chunks should have 1-based page numbers
        for chunk in pageChunks {
            XCTAssertNotNil(chunk.pageNumber)
            XCTAssertGreaterThan(chunk.pageNumber!, 0, "Page numbers should be 1-based")
        }

        // Page numbers should be sequential (no gaps for pages with text)
        let pageNumbers = pageChunks.compactMap(\.pageNumber)
        XCTAssertEqual(pageNumbers, pageNumbers.sorted(), "Page numbers should be in order")

        // First page should be page 1
        XCTAssertEqual(pageNumbers.first, 1)
    }

    func testPDFPageChunksHaveNoLineRanges() throws {
        let file = pdfFileInfo()
        let extractor = TextExtractor()
        let chunks = try extractor.extract(from: file).chunks

        let pageChunks = chunks.filter { $0.type == .pdfPage }

        // PDF page chunks should not have line ranges
        for chunk in pageChunks {
            XCTAssertNil(chunk.lineStart)
            XCTAssertNil(chunk.lineEnd)
        }
    }

    func testPDFWholeChunkOnlyEmittedWhenTextFitsInEmbeddingLimit() throws {
        let file = pdfFileInfo()
        let extractor = TextExtractor()
        let chunks = try extractor.extract(from: file).chunks

        let pageChunks = chunks.filter { $0.type == .pdfPage }
        let totalText = pageChunks.map(\.text).joined(separator: "\n")

        if totalText.count <= NomicEmbedder.maxInputCharacters {
            // Small-enough PDF: whole chunk should be present and contain page text
            let wholeChunk = chunks.first { $0.type == .whole }
            XCTAssertNotNil(wholeChunk)
            let text = wholeChunk!.text
            XCTAssertTrue(text.contains("MOBY") || text.contains("Moby") || text.contains("whale") || text.contains("Whale"),
                           "Whole-document chunk should contain Moby Dick content")
        } else {
            // Oversize PDF: whole chunk must be suppressed to avoid embedding
            // only a truncated prefix and pretending it's the whole document.
            XCTAssertFalse(chunks.contains { $0.type == .whole },
                           "Whole chunk should not be produced for PDFs exceeding the embedding limit")
        }
    }

    func testPDFPageChunksContainNonEmptyText() throws {
        let file = pdfFileInfo()
        let extractor = TextExtractor()
        let chunks = try extractor.extract(from: file).chunks

        let pageChunks = chunks.filter { $0.type == .pdfPage }

        for chunk in pageChunks {
            let trimmed = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertFalse(trimmed.isEmpty, "Page \(chunk.pageNumber ?? 0) should have non-empty text")
        }
    }

    func testImageExtractionDoesNotCrashAndReturnsImageChunks() throws {
        // Create a simple PNG image programmatically with text drawn into it
        let imageURL = tempDir.appendingPathComponent("test_ocr.png")

        let width = 400
        let height = 100
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            XCTFail("Could not create CGContext")
            return
        }

        // Fill white background
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Draw "Hello World" text in black
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        let text = "Hello World" as CFString
        let font = CTFontCreateWithName("Helvetica" as CFString, 36, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        ]
        let attrString = NSAttributedString(string: text as String, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attrString)
        context.textPosition = CGPoint(x: 20, y: 30)
        CTLineDraw(line, context)

        guard let cgImage = context.makeImage() else {
            XCTFail("Could not create CGImage")
            return
        }

        // Write as PNG
        guard let destination = CGImageDestinationCreateWithURL(
            imageURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            XCTFail("Could not create image destination")
            return
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        CGImageDestinationFinalize(destination)

        let modDate = try imageURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        let file = FileInfo(
            relativePath: "test_ocr.png",
            url: imageURL,
            modificationDate: modDate,
            fileExtension: "png"
        )

        let extractor = TextExtractor()
        let chunks = try extractor.extract(from: file).chunks

        // Vision OCR may or may not recognize text from programmatic images,
        // so we just verify the code path doesn't crash and returns valid results
        for chunk in chunks {
            XCTAssertEqual(chunk.type, .image)
            XCTAssertFalse(chunk.text.isEmpty)
        }
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

    func testScanSkipsBinaryFilesWithNoExtension() throws {
        createTextFile(at: "Makefile", content: "all:\n\techo hello")

        // Create a binary file with no extension
        var binaryData = Data("ELF binary".utf8)
        binaryData.append(contentsOf: [0x00, 0x00, 0x7F, 0x45, 0x4C, 0x46])
        createFile(at: "mybinary", content: binaryData)

        let scanner = FileScanner(directory: tempDir)
        let files = try scanner.scan()
        let relativePaths = files.map { $0.relativePath }

        XCTAssertTrue(relativePaths.contains("Makefile"),
                       "Text file with no extension should be included, got: \(relativePaths)")
        XCTAssertFalse(relativePaths.contains("mybinary"),
                        "Binary file with no extension should be excluded")
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

    func testScanSkipsHiddenFilesByDefault() throws {
        createTextFile(at: "visible.swift", content: "import Foundation")
        createTextFile(at: ".hidden_config", content: "secret=123")
        createTextFile(at: ".hidden_dir/file.txt", content: "inside hidden dir")

        let scanner = FileScanner(directory: tempDir)
        let files = try scanner.scan()
        let relativePaths = files.map { $0.relativePath }

        XCTAssertTrue(relativePaths.contains("visible.swift"))
        XCTAssertFalse(relativePaths.contains(".hidden_config"))
        XCTAssertFalse(relativePaths.contains(where: { $0.hasPrefix(".hidden_dir") }))
    }

    func testScanIncludesHiddenFilesWhenEnabled() throws {
        createTextFile(at: "visible.swift", content: "import Foundation")
        createTextFile(at: ".hidden_config", content: "secret=123")
        createTextFile(at: ".hidden_dir/file.txt", content: "inside hidden dir")

        let scanner = FileScanner(directory: tempDir, includeHiddenFiles: true)
        let files = try scanner.scan()
        let relativePaths = files.map { $0.relativePath }

        XCTAssertTrue(relativePaths.contains("visible.swift"))
        XCTAssertTrue(relativePaths.contains(".hidden_config"), "Expected .hidden_config, got: \(relativePaths)")
        XCTAssertTrue(relativePaths.contains(where: { $0.hasPrefix(".hidden_dir") }),
                       "Expected files in .hidden_dir, got: \(relativePaths)")
    }

    func testScanStillSkipsGitDirWhenHiddenEnabled() throws {
        createTextFile(at: "main.swift", content: "print(\"hello\")")
        createTextFile(at: ".git/config", content: "[core]\n\tbare = false")
        createTextFile(at: ".hidden_file.txt", content: "hidden but allowed")

        let scanner = FileScanner(directory: tempDir, includeHiddenFiles: true)
        let files = try scanner.scan()
        let relativePaths = files.map { $0.relativePath }

        XCTAssertTrue(relativePaths.contains("main.swift"))
        XCTAssertTrue(relativePaths.contains(".hidden_file.txt"), "Expected .hidden_file.txt, got: \(relativePaths)")
        XCTAssertFalse(relativePaths.contains(where: { $0.hasPrefix(".git") }),
                        ".git directory should still be skipped")
    }

    func testScanRespectsGitignore() throws {
        // Initialize a git repo in the temp dir
        let gitInit = Process()
        gitInit.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        gitInit.arguments = ["init"]
        gitInit.currentDirectoryURL = tempDir
        try gitInit.run()
        gitInit.waitUntilExit()
        guard gitInit.terminationStatus == 0 else {
            XCTFail("git init failed")
            return
        }

        // Create a .gitignore
        createTextFile(at: ".gitignore", content: "build/\n*.log\n")

        // Create files — some should be ignored
        createTextFile(at: "main.swift", content: "import Foundation")
        createTextFile(at: "build/output.swift", content: "generated code")
        createTextFile(at: "debug.log", content: "log output")
        createTextFile(at: "readme.md", content: "# Hello")

        let scanner = FileScanner(directory: tempDir, includeHiddenFiles: true)
        let files = try scanner.scan()
        let relativePaths = files.map { $0.relativePath }

        XCTAssertTrue(relativePaths.contains("main.swift"), "Expected main.swift, got: \(relativePaths)")
        XCTAssertTrue(relativePaths.contains("readme.md"), "Expected readme.md, got: \(relativePaths)")
        XCTAssertFalse(relativePaths.contains(where: { $0.hasPrefix("build/") }),
                        "build/ should be gitignored")
        XCTAssertFalse(relativePaths.contains("debug.log"),
                        "*.log should be gitignored")
    }

    func testScanWorksWithoutGitRepo() throws {
        // No git init — this is just a regular directory
        createTextFile(at: "main.swift", content: "import Foundation")
        createTextFile(at: "notes.txt", content: "some notes")

        let scanner = FileScanner(directory: tempDir)
        let files = try scanner.scan()
        let relativePaths = files.map { $0.relativePath }

        XCTAssertTrue(relativePaths.contains("main.swift"), "Expected main.swift, got: \(relativePaths)")
        XCTAssertTrue(relativePaths.contains("notes.txt"), "Expected notes.txt, got: \(relativePaths)")
    }

    // MARK: - .vecignore Tests

    func testVecignoreWildcardExcludesMatchingFiles() throws {
        createTextFile(at: "main.swift", content: "import Foundation")
        createTextFile(at: "debug.log", content: "log output")
        createTextFile(at: "subdir/other.log", content: "nested log")
        createTextFile(at: "readme.md", content: "# Hello")
        createTextFile(at: ".vecignore", content: "*.log\n")

        let scanner = FileScanner(directory: tempDir, respectsGitignore: false, includeHiddenFiles: true)
        let files = try scanner.scan()
        let relativePaths = files.map { $0.relativePath }

        XCTAssertTrue(relativePaths.contains("main.swift"), "Expected main.swift, got: \(relativePaths)")
        XCTAssertTrue(relativePaths.contains("readme.md"), "Expected readme.md, got: \(relativePaths)")
        XCTAssertFalse(relativePaths.contains("debug.log"),
                        "*.log should be vecignored")
        XCTAssertFalse(relativePaths.contains("subdir/other.log"),
                        "*.log should also match nested files")
    }

    func testVecignoreDirectoryPatternExcludesContents() throws {
        createTextFile(at: "main.swift", content: "import Foundation")
        createTextFile(at: "generated/output.swift", content: "generated code")
        createTextFile(at: "generated/nested/deep.swift", content: "deep generated")
        createTextFile(at: "readme.md", content: "# Hello")
        createTextFile(at: ".vecignore", content: "generated/\n")

        let scanner = FileScanner(directory: tempDir, respectsGitignore: false, includeHiddenFiles: true)
        let files = try scanner.scan()
        let relativePaths = files.map { $0.relativePath }

        XCTAssertTrue(relativePaths.contains("main.swift"), "Expected main.swift, got: \(relativePaths)")
        XCTAssertTrue(relativePaths.contains("readme.md"), "Expected readme.md, got: \(relativePaths)")
        XCTAssertFalse(relativePaths.contains(where: { $0.hasPrefix("generated/") }),
                        "generated/ directory should be vecignored")
    }

    func testNoVecignoreFileWorksNormally() throws {
        createTextFile(at: "main.swift", content: "import Foundation")
        createTextFile(at: "debug.log", content: "log output")
        createTextFile(at: "readme.md", content: "# Hello")
        // No .vecignore file

        let scanner = FileScanner(directory: tempDir, respectsGitignore: false)
        let files = try scanner.scan()
        let relativePaths = files.map { $0.relativePath }

        XCTAssertTrue(relativePaths.contains("main.swift"), "Expected main.swift, got: \(relativePaths)")
        XCTAssertTrue(relativePaths.contains("debug.log"), "Expected debug.log without .vecignore, got: \(relativePaths)")
        XCTAssertTrue(relativePaths.contains("readme.md"), "Expected readme.md, got: \(relativePaths)")
    }

    func testScanCanDisableGitignoreFiltering() throws {
        // Initialize a git repo
        let gitInit = Process()
        gitInit.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        gitInit.arguments = ["init"]
        gitInit.currentDirectoryURL = tempDir
        try gitInit.run()
        gitInit.waitUntilExit()

        createTextFile(at: ".gitignore", content: "*.log\n")
        createTextFile(at: "main.swift", content: "import Foundation")
        createTextFile(at: "debug.log", content: "log output")

        let scanner = FileScanner(directory: tempDir, respectsGitignore: false, includeHiddenFiles: true)
        let files = try scanner.scan()
        let relativePaths = files.map { $0.relativePath }

        XCTAssertTrue(relativePaths.contains("main.swift"))
        XCTAssertTrue(relativePaths.contains("debug.log"),
                       "debug.log should be included when gitignore is disabled, got: \(relativePaths)")
    }

    func testScanFindsFilesWithSpacesInNames() throws {
        createTextFile(at: "my file.txt", content: "content with spaces")
        createTextFile(at: "sub dir/another file.md", content: "# Nested")
        createTextFile(at: "normal.swift", content: "import Foundation")

        let scanner = FileScanner(directory: tempDir)
        let files = try scanner.scan()
        let relativePaths = files.map { $0.relativePath }

        XCTAssertTrue(relativePaths.contains("my file.txt"),
                       "Expected 'my file.txt', got: \(relativePaths)")
        XCTAssertTrue(relativePaths.contains("sub dir/another file.md"),
                       "Expected 'sub dir/another file.md', got: \(relativePaths)")
        XCTAssertTrue(relativePaths.contains("normal.swift"))
    }

    func testScanFindsFilesWithUnicodeInNames() throws {
        createTextFile(at: "café.txt", content: "coffee notes")
        createTextFile(at: "日本語.md", content: "# Japanese")
        createTextFile(at: "émojis 🎉.txt", content: "celebration")

        let scanner = FileScanner(directory: tempDir)
        let files = try scanner.scan()
        let relativePaths = files.map { $0.relativePath }

        XCTAssertTrue(relativePaths.contains("café.txt"),
                       "Expected 'café.txt', got: \(relativePaths)")
        XCTAssertTrue(relativePaths.contains("日本語.md"),
                       "Expected '日本語.md', got: \(relativePaths)")
        XCTAssertTrue(relativePaths.contains("émojis 🎉.txt"),
                       "Expected 'émojis 🎉.txt', got: \(relativePaths)")
    }

    func testScanEmptyDirectoryReturnsEmptyArray() throws {
        // tempDir is already empty — scan should return empty without errors
        let scanner = FileScanner(directory: tempDir)
        let files = try scanner.scan()
        XCTAssertEqual(files.count, 0)
    }

    func testVecignoreRootRelativePatternMatchesOnlyAtRoot() throws {
        createTextFile(at: "specific-file.txt", content: "root level file")
        createTextFile(at: "subdir/specific-file.txt", content: "nested file")
        createTextFile(at: "readme.md", content: "# Hello")
        createTextFile(at: ".vecignore", content: "/specific-file.txt\n")

        let scanner = FileScanner(directory: tempDir, respectsGitignore: false, includeHiddenFiles: true)
        let files = try scanner.scan()
        let relativePaths = files.map { $0.relativePath }

        XCTAssertTrue(relativePaths.contains("readme.md"), "Expected readme.md, got: \(relativePaths)")
        XCTAssertFalse(relativePaths.contains("specific-file.txt"),
                        "/specific-file.txt should exclude root-level match")
        XCTAssertTrue(relativePaths.contains("subdir/specific-file.txt"),
                       "Root-relative pattern should NOT match nested file, got: \(relativePaths)")
    }

    func testVecignoreCommentLinesAreIgnored() throws {
        createTextFile(at: "main.swift", content: "import Foundation")
        createTextFile(at: "debug.log", content: "log output")
        createTextFile(at: "readme.md", content: "# Hello")
        // The comment line should be ignored; only *.log is an active pattern
        createTextFile(at: ".vecignore", content: "# This is a comment\n*.log\n# Another comment\n")

        let scanner = FileScanner(directory: tempDir, respectsGitignore: false, includeHiddenFiles: true)
        let files = try scanner.scan()
        let relativePaths = files.map { $0.relativePath }

        XCTAssertTrue(relativePaths.contains("main.swift"), "Expected main.swift, got: \(relativePaths)")
        XCTAssertTrue(relativePaths.contains("readme.md"), "Expected readme.md, got: \(relativePaths)")
        XCTAssertFalse(relativePaths.contains("debug.log"),
                        "*.log should still be vecignored despite comment lines")
    }

    func testVecignoreBlankLinesAreIgnored() throws {
        createTextFile(at: "main.swift", content: "import Foundation")
        createTextFile(at: "debug.log", content: "log output")
        createTextFile(at: "readme.md", content: "# Hello")
        // Blank lines between patterns should be ignored
        createTextFile(at: ".vecignore", content: "\n\n*.log\n\n\n")

        let scanner = FileScanner(directory: tempDir, respectsGitignore: false, includeHiddenFiles: true)
        let files = try scanner.scan()
        let relativePaths = files.map { $0.relativePath }

        XCTAssertTrue(relativePaths.contains("main.swift"), "Expected main.swift, got: \(relativePaths)")
        XCTAssertTrue(relativePaths.contains("readme.md"), "Expected readme.md, got: \(relativePaths)")
        XCTAssertFalse(relativePaths.contains("debug.log"),
                        "*.log should still be vecignored despite blank lines")
    }

    func testScanFindsImageFiles() throws {
        createTextFile(at: "readme.md", content: "# Hello")

        // Create a minimal valid PNG file (1x1 pixel)
        let pngHeader: [UInt8] = [
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR chunk
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, // 1x1
            0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, // 8-bit RGB
            0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, // IDAT chunk
            0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
            0x00, 0x00, 0x02, 0x00, 0x01, 0xE2, 0x21, 0xBC,
            0x33, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, // IEND chunk
            0x44, 0xAE, 0x42, 0x60, 0x82
        ]
        createFile(at: "photo.png", content: Data(pngHeader))

        let scanner = FileScanner(directory: tempDir)
        let files = try scanner.scan()
        let relativePaths = files.map { $0.relativePath }

        XCTAssertTrue(relativePaths.contains("readme.md"), "Expected readme.md, got: \(relativePaths)")
        XCTAssertTrue(relativePaths.contains("photo.png"), "Expected photo.png to be picked up as image, got: \(relativePaths)")
    }
}

// MARK: - PathUtilities Tests

final class PathUtilitiesTests: XCTestCase {

    func testNormalRelativePath() {
        let result = PathUtilities.relativePath(of: "/foo/bar/baz/file.txt", in: "/foo/bar")
        XCTAssertEqual(result, "baz/file.txt")
    }

    func testTrailingSlashOnDirectory() {
        let result = PathUtilities.relativePath(of: "/foo/bar/baz.txt", in: "/foo/bar/")
        XCTAssertEqual(result, "baz.txt")
    }

    func testFileDirectlyInDirectory() {
        let result = PathUtilities.relativePath(of: "/foo/bar/file.txt", in: "/foo/bar")
        XCTAssertEqual(result, "file.txt")
    }

    func testBothHaveTrailingSlashes() {
        let result = PathUtilities.relativePath(of: "/foo/bar/sub/file.txt", in: "/foo/bar/")
        XCTAssertEqual(result, "sub/file.txt")
    }

    func testDirectoryWithDotDot() {
        // /foo/bar/../bar standardizes to /foo/bar
        let result = PathUtilities.relativePath(of: "/foo/bar/baz/file.txt", in: "/foo/bar/../bar")
        XCTAssertEqual(result, "baz/file.txt")
    }

    func testFileOutsideDirectory() {
        let result = PathUtilities.relativePath(of: "/other/path/file.txt", in: "/foo/bar")
        XCTAssertEqual(result, "file.txt")
    }

    func testSamePathReturnsEmpty() {
        let result = PathUtilities.relativePath(of: "/foo/bar", in: "/foo/bar")
        XCTAssertEqual(result, "")
    }

    func testRootDirectory() {
        let result = PathUtilities.relativePath(of: "/file.txt", in: "/")
        XCTAssertEqual(result, "file.txt")
    }

    func testDeeplyNestedPath() {
        let result = PathUtilities.relativePath(of: "/a/b/c/d/e/f.txt", in: "/a/b")
        XCTAssertEqual(result, "c/d/e/f.txt")
    }

    func testDirectoryNamePrefixCollision() {
        // /foo/bar should NOT match /foo/barbell — the "/" append prevents this
        let result = PathUtilities.relativePath(of: "/foo/barbell/file.txt", in: "/foo/bar")
        XCTAssertEqual(result, "file.txt") // fallback to lastPathComponent, not "bell/file.txt"
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
        let chunks = try extractor.extract(from: file).chunks
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
        let chunks = try extractor.extract(from: file).chunks
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
        let chunks = try extractor.extract(from: file).chunks
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
