import XCTest
@testable import VecKit

final class IntegrationTests: XCTestCase {

    private var tempDir: URL!
    private var embeddingService: EmbeddingService!

    override func setUp() {
        super.setUp()
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("VecIntegrationTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        // Use C realpath to resolve /var -> /private/var on macOS
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        tempDir = realpath(raw.path, &buf) != nil
            ? URL(fileURLWithPath: String(cString: buf), isDirectory: true)
            : raw
        embeddingService = EmbeddingService()
    }

    override func tearDown() {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    // MARK: - Helpers

    /// Embed a string using the real EmbeddingService. Fails the test if embedding returns nil.
    private func embed(_ text: String, file: StaticString = #file, line: UInt = #line) throws -> [Float] {
        let vector = try XCTUnwrap(
            embeddingService.embed(text),
            "EmbeddingService returned nil for: \(text)",
            file: file, line: line
        )
        return vector
    }

    /// Create an initialized VectorDatabase in tempDir.
    private func makeInitializedDB() throws -> VectorDatabase {
        let db = VectorDatabase(directory: tempDir)
        try db.initialize()
        return db
    }

    /// Create a file on disk in tempDir.
    private func createTextFile(name: String, content: String) {
        let url = tempDir.appendingPathComponent(name)
        let parent = url.deletingLastPathComponent()
        try! FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try! content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Get FileInfo for a file in tempDir by relative path.
    private func getFileInfo(relativePath: String) throws -> FileInfo {
        let url = tempDir.appendingPathComponent(relativePath)
        return try FileScanner.fileInfo(for: url, relativeTo: tempDir)
    }

    // MARK: - Test 1: Scan + Extract + Embed + Store + Search

    func testFullPipelineScanExtractEmbedStoreSearch() throws {
        // Create a markdown file with enough content to produce multiple chunks
        var lines: [String] = [
            "# Swift Programming Guide",
            "",
            "Swift is a powerful and intuitive programming language for iOS, macOS, watchOS, and tvOS."
        ]
        // Add enough lines to exceed the default chunk size of 50
        for i in 1...60 {
            if i % 10 == 0 {
                lines.append("## Section \(i / 10)")
            } else {
                lines.append("Line \(i): Swift programming content for testing purposes.")
            }
        }
        let content = lines.joined(separator: "\n")
        createTextFile(name: "guide.md", content: content)

        // Initialize database
        let db = try makeInitializedDB()

        // Scan directory
        let scanner = FileScanner(directory: tempDir)
        let files = try scanner.scan()

        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].relativePath, "guide.md")

        // Extract chunks
        let extractor = TextExtractor()
        let chunks = try extractor.extract(from: files[0])

        XCTAssertGreaterThan(chunks.count, 1, "Should have both whole and line chunks")

        // Embed and store all chunks
        var insertedCount = 0
        for chunk in chunks {
            let embedding = try embed(chunk.text)
            try db.insert(
                filePath: files[0].relativePath,
                lineStart: chunk.lineStart,
                lineEnd: chunk.lineEnd,
                chunkType: chunk.type,
                pageNumber: chunk.pageNumber,
                fileModifiedAt: files[0].modificationDate,
                contentPreview: String(chunk.text.prefix(200)),
                embedding: embedding
            )
            insertedCount += 1
        }

        XCTAssertEqual(insertedCount, chunks.count)

        // Search for relevant content
        let queryEmbedding = try embed("Swift programming and functions")
        let results = try db.search(embedding: queryEmbedding, limit: 10)

        XCTAssertGreaterThan(results.count, 0, "Should find results matching the query")
        XCTAssertEqual(results[0].filePath, "guide.md")

        // Verify semantically similar content is found
        let hasSwiftContent = results.contains { $0.contentPreview?.contains("Swift") ?? false }
        XCTAssertTrue(hasSwiftContent, "Results should include Swift-related content")
    }

    // MARK: - Test 2: Update flow — modified file

    func testUpdateFlowModifiedFile() throws {
        // Create initial file
        let initialContent = """
        # Original Document

        This is the original content about databases and SQL.
        Databases store structured data efficiently.
        """
        createTextFile(name: "document.md", content: initialContent)

        // Initialize database and index the file
        let db = try makeInitializedDB()
        let scanner = FileScanner(directory: tempDir)
        let extractor = TextExtractor()

        var files = try scanner.scan()
        XCTAssertEqual(files.count, 1)

        var fileInfo = files[0]
        let chunks = try extractor.extract(from: fileInfo)
        let initialModDate = fileInfo.modificationDate

        for chunk in chunks {
            let embedding = try embed(chunk.text)
            try db.insert(
                filePath: fileInfo.relativePath,
                lineStart: chunk.lineStart,
                lineEnd: chunk.lineEnd,
                chunkType: chunk.type,
                pageNumber: chunk.pageNumber,
                fileModifiedAt: initialModDate,
                contentPreview: String(chunk.text.prefix(200)),
                embedding: embedding
            )
        }

        // Verify initial content is searchable
        let dbFiles = try db.allIndexedFiles()
        XCTAssertEqual(dbFiles.count, 1)

        let initialResults = try db.search(
            embedding: try embed("SQL databases"),
            limit: 10
        )
        XCTAssertGreaterThan(initialResults.count, 0)

        // Wait a bit to ensure time difference, then modify the file
        Thread.sleep(forTimeInterval: 0.1)

        let newContent = """
        # Updated Document

        This is new content about Swift programming and concurrency.
        Swift provides powerful async/await syntax for concurrent code.
        Concurrency is important for responsive applications.
        """
        createTextFile(name: "document.md", content: newContent)

        // Simulate update-index logic: compare modification dates and re-index
        files = try scanner.scan()
        fileInfo = files[0]

        if fileInfo.modificationDate > initialModDate {
            // File changed — remove old entries and re-index
            try db.removeEntries(forPath: fileInfo.relativePath)

            let newChunks = try extractor.extract(from: fileInfo)
            for chunk in newChunks {
                let embedding = try embed(chunk.text)
                try db.insert(
                    filePath: fileInfo.relativePath,
                    lineStart: chunk.lineStart,
                    lineEnd: chunk.lineEnd,
                    chunkType: chunk.type,
                    pageNumber: chunk.pageNumber,
                    fileModifiedAt: fileInfo.modificationDate,
                    contentPreview: String(chunk.text.prefix(200)),
                    embedding: embedding
                )
            }
        }

        // Verify new content is searchable and old content is gone
        let swiftResults = try db.search(
            embedding: try embed("Swift concurrency async await"),
            limit: 10
        )
        XCTAssertGreaterThan(swiftResults.count, 0, "Should find new Swift-related content")

        // Old content should not be found (or very low ranking)
        let sqlResults = try db.search(
            embedding: try embed("SQL databases"),
            limit: 10
        )
        // If old entries are completely gone, this should be empty or sparse
        // Since we re-indexed with new content, the old content references should be gone
        let hasOldContent = sqlResults.contains {
            $0.contentPreview?.contains("databases") ?? false
        }
        XCTAssertFalse(hasOldContent, "Old database content should be removed after update")
    }

    // MARK: - Test 3: Update flow — deleted file

    func testUpdateFlowDeletedFile() throws {
        // Create two files
        let file1Content = "# File One\n\nContent about Python and machine learning algorithms."
        let file2Content = "# File Two\n\nContent about JavaScript and web development frameworks."

        createTextFile(name: "file1.md", content: file1Content)
        createTextFile(name: "file2.md", content: file2Content)

        // Initialize database and index both files
        let db = try makeInitializedDB()
        let scanner = FileScanner(directory: tempDir)
        let extractor = TextExtractor()

        var files = try scanner.scan()
        XCTAssertEqual(files.count, 2)

        for fileInfo in files {
            let chunks = try extractor.extract(from: fileInfo)
            for chunk in chunks {
                let embedding = try embed(chunk.text)
                try db.insert(
                    filePath: fileInfo.relativePath,
                    lineStart: chunk.lineStart,
                    lineEnd: chunk.lineEnd,
                    chunkType: chunk.type,
                    pageNumber: chunk.pageNumber,
                    fileModifiedAt: fileInfo.modificationDate,
                    contentPreview: String(chunk.text.prefix(200)),
                    embedding: embedding
                )
            }
        }

        let indexedBefore = try db.allIndexedFiles()
        XCTAssertEqual(indexedBefore.count, 2)

        // Delete file1 from disk
        let file1URL = tempDir.appendingPathComponent("file1.md")
        try FileManager.default.removeItem(at: file1URL)

        // Simulate update-index logic: find paths in DB not on disk, remove them
        files = try scanner.scan()
        let currentPaths = Set(files.map(\.relativePath))
        let allIndexedPaths = try db.allIndexedFiles()

        for indexedPath in allIndexedPaths.keys {
            if !currentPaths.contains(indexedPath) {
                try db.removeEntries(forPath: indexedPath)
            }
        }

        // Verify file1 entries are gone but file2 entries remain
        let indexedAfter = try db.allIndexedFiles()
        XCTAssertEqual(indexedAfter.count, 1)
        XCTAssertNotNil(indexedAfter["file2.md"])
        XCTAssertNil(indexedAfter["file1.md"])

        // Verify file2 is still searchable
        let jsResults = try db.search(
            embedding: try embed("JavaScript web development"),
            limit: 10
        )
        XCTAssertGreaterThan(jsResults.count, 0)
        XCTAssertEqual(jsResults[0].filePath, "file2.md")

        // Verify file1 content is not searchable
        let pythonResults = try db.search(
            embedding: try embed("Python machine learning"),
            limit: 10
        )
        let hasPythonContent = pythonResults.contains { $0.filePath == "file1.md" }
        XCTAssertFalse(hasPythonContent, "Deleted file should not appear in results")
    }

    // MARK: - Test 4: Update flow — new file added

    func testUpdateFlowNewFileAdded() throws {
        // Create initial file
        let initialContent = "# Initial\n\nThis is the initial file about databases."
        createTextFile(name: "initial.md", content: initialContent)

        // Initialize database and index the initial file
        let db = try makeInitializedDB()
        let scanner = FileScanner(directory: tempDir)
        let extractor = TextExtractor()

        var files = try scanner.scan()
        XCTAssertEqual(files.count, 1)

        for fileInfo in files {
            let chunks = try extractor.extract(from: fileInfo)
            for chunk in chunks {
                let embedding = try embed(chunk.text)
                try db.insert(
                    filePath: fileInfo.relativePath,
                    lineStart: chunk.lineStart,
                    lineEnd: chunk.lineEnd,
                    chunkType: chunk.type,
                    pageNumber: chunk.pageNumber,
                    fileModifiedAt: fileInfo.modificationDate,
                    contentPreview: String(chunk.text.prefix(200)),
                    embedding: embedding
                )
            }
        }

        let indexedInitial = try db.allIndexedFiles()
        XCTAssertEqual(indexedInitial.count, 1)

        // Add a new file to disk
        let newContent = "# New File\n\nThis is a new file about Rust and systems programming."
        createTextFile(name: "new.md", content: newContent)

        // Simulate update-index logic: find files on disk not in DB, index them
        files = try scanner.scan()
        let indexedPaths = try db.allIndexedFiles()

        for fileInfo in files {
            if !indexedPaths.keys.contains(fileInfo.relativePath) {
                // New file
                let chunks = try extractor.extract(from: fileInfo)
                for chunk in chunks {
                    let embedding = try embed(chunk.text)
                    try db.insert(
                        filePath: fileInfo.relativePath,
                        lineStart: chunk.lineStart,
                        lineEnd: chunk.lineEnd,
                        chunkType: chunk.type,
                        pageNumber: chunk.pageNumber,
                        fileModifiedAt: fileInfo.modificationDate,
                        contentPreview: String(chunk.text.prefix(200)),
                        embedding: embedding
                    )
                }
            }
        }

        // Verify both files are now indexed
        let indexedAfter = try db.allIndexedFiles()
        XCTAssertEqual(indexedAfter.count, 2)
        XCTAssertNotNil(indexedAfter["initial.md"])
        XCTAssertNotNil(indexedAfter["new.md"])

        // Verify both files are searchable
        let initialResults = try db.search(
            embedding: try embed("databases"),
            limit: 10
        )
        XCTAssertGreaterThan(initialResults.count, 0)

        let rustResults = try db.search(
            embedding: try embed("Rust systems programming"),
            limit: 10
        )
        XCTAssertGreaterThan(rustResults.count, 0)
        XCTAssertEqual(rustResults[0].filePath, "new.md")
    }

    // MARK: - Test 5: Insert single file then search

    func testInsertSingleFileAndSearch() throws {
        // Create a single file
        let content = """
        # Go Language Guide

        Go is a statically typed, compiled programming language designed at Google.
        Go emphasizes simplicity and fast compilation.

        ## Concurrency with Goroutines

        Goroutines are lightweight threads managed by the Go runtime.
        They enable efficient concurrent programming without OS-level complexity.
        """
        createTextFile(name: "golang.md", content: content)

        // Initialize database
        let db = try makeInitializedDB()

        // Get file info using FileScanner.fileInfo()
        let fileURL = tempDir.appendingPathComponent("golang.md")
        let fileInfo = try FileScanner.fileInfo(for: fileURL, relativeTo: tempDir)

        // Extract chunks
        let extractor = TextExtractor()
        let chunks = try extractor.extract(from: fileInfo)

        // Insert all chunks
        for chunk in chunks {
            let embedding = try embed(chunk.text)
            try db.insert(
                filePath: fileInfo.relativePath,
                lineStart: chunk.lineStart,
                lineEnd: chunk.lineEnd,
                chunkType: chunk.type,
                pageNumber: chunk.pageNumber,
                fileModifiedAt: fileInfo.modificationDate,
                contentPreview: String(chunk.text.prefix(200)),
                embedding: embedding
            )
        }

        // Search for Go-related content
        let results = try db.search(
            embedding: try embed("concurrency goroutines"),
            limit: 5
        )

        XCTAssertGreaterThan(results.count, 0)
        XCTAssertEqual(results[0].filePath, "golang.md")
        let hasGoContent = results[0].contentPreview?.contains("Go") ?? false
        XCTAssertTrue(hasGoContent)
    }

    // MARK: - Test 6: Remove file entries and verify search

    func testRemoveFileEntriesAndSearch() throws {
        // Create multiple files
        let rubyContent = "# Ruby Language\n\nRuby is a dynamic, object-oriented programming language."
        let phpContent = "# PHP Language\n\nPHP is a server-side scripting language for web development."
        let cppContent = "# C++ Language\n\nC++ is a high-performance systems programming language."

        createTextFile(name: "ruby.md", content: rubyContent)
        createTextFile(name: "php.md", content: phpContent)
        createTextFile(name: "cpp.md", content: cppContent)

        // Initialize database and index all files
        let db = try makeInitializedDB()
        let scanner = FileScanner(directory: tempDir)
        let extractor = TextExtractor()

        let files = try scanner.scan()
        XCTAssertEqual(files.count, 3)

        for fileInfo in files {
            let chunks = try extractor.extract(from: fileInfo)
            for chunk in chunks {
                let embedding = try embed(chunk.text)
                try db.insert(
                    filePath: fileInfo.relativePath,
                    lineStart: chunk.lineStart,
                    lineEnd: chunk.lineEnd,
                    chunkType: chunk.type,
                    pageNumber: chunk.pageNumber,
                    fileModifiedAt: fileInfo.modificationDate,
                    contentPreview: String(chunk.text.prefix(200)),
                    embedding: embedding
                )
            }
        }

        let indexedBefore = try db.allIndexedFiles()
        XCTAssertEqual(indexedBefore.count, 3)

        // Remove PHP file entries
        let removed = try db.removeEntries(forPath: "php.md")
        XCTAssertGreaterThan(removed, 0)

        // Verify PHP file is no longer indexed
        let indexedAfter = try db.allIndexedFiles()
        XCTAssertEqual(indexedAfter.count, 2)
        XCTAssertNotNil(indexedAfter["ruby.md"])
        XCTAssertNil(indexedAfter["php.md"])
        XCTAssertNotNil(indexedAfter["cpp.md"])

        // Search for PHP content — should not find it
        let phpResults = try db.search(
            embedding: try embed("PHP web server"),
            limit: 10
        )
        let hasPhpFile = phpResults.contains { $0.filePath == "php.md" }
        XCTAssertFalse(hasPhpFile, "Removed file should not appear in results")

        // Search for Ruby content — should still find it
        let rubyResults = try db.search(
            embedding: try embed("Ruby dynamic object-oriented"),
            limit: 10
        )
        XCTAssertGreaterThan(rubyResults.count, 0)
        XCTAssertEqual(rubyResults[0].filePath, "ruby.md")
    }

    // MARK: - Test 7: Semantic search — similar content ranks better than dissimilar

    func testSemanticSearchSimilarityRanking() throws {
        // Create files with distinct semantic content
        let machinelearningContent = """
        # Machine Learning Fundamentals

        Machine learning is a subset of artificial intelligence that enables systems to learn from data.
        Neural networks are inspired by biological brains and consist of interconnected nodes.
        Deep learning uses many layers of neural networks for complex pattern recognition.
        """

        let cookingContent = """
        # Cooking Basics

        Cooking is the practice of preparing food using heat.
        Baking requires precision in measurements and timing.
        Seasoning and spices enhance the flavor of dishes.
        """

        createTextFile(name: "ml.md", content: machinelearningContent)
        createTextFile(name: "cooking.md", content: cookingContent)

        // Index both files
        let db = try makeInitializedDB()
        let scanner = FileScanner(directory: tempDir)
        let extractor = TextExtractor()

        for fileInfo in try scanner.scan() {
            let chunks = try extractor.extract(from: fileInfo)
            for chunk in chunks {
                let embedding = try embed(chunk.text)
                try db.insert(
                    filePath: fileInfo.relativePath,
                    lineStart: chunk.lineStart,
                    lineEnd: chunk.lineEnd,
                    chunkType: chunk.type,
                    pageNumber: chunk.pageNumber,
                    fileModifiedAt: fileInfo.modificationDate,
                    contentPreview: String(chunk.text.prefix(200)),
                    embedding: embedding
                )
            }
        }

        // Search for ML-related query
        let mlQuery = try embed("neural networks deep learning artificial intelligence")
        let mlResults = try db.search(embedding: mlQuery, limit: 10)

        XCTAssertGreaterThan(mlResults.count, 0)

        // ML file should be in results and should have lower distance (more similar) than cooking
        if mlResults.count >= 2 {
            let mlFileDistances = mlResults.filter { $0.filePath == "ml.md" }.map { $0.distance }
            let cookingFileDistances = mlResults.filter { $0.filePath == "cooking.md" }.map { $0.distance }

            if let mlDist = mlFileDistances.first, let cookingDist = cookingFileDistances.first {
                XCTAssertLessThan(
                    mlDist, cookingDist,
                    "ML content should rank higher (lower distance) for ML query"
                )
            }
        }

        // Search for cooking-related query
        let cookingQuery = try embed("baking seasoning cooking preparation")
        let cookingResults = try db.search(embedding: cookingQuery, limit: 10)

        XCTAssertGreaterThan(cookingResults.count, 0)

        // Cooking file should rank higher for cooking query
        if cookingResults.count >= 2 {
            let cookingFileDistances = cookingResults.filter { $0.filePath == "cooking.md" }.map { $0.distance }
            let mlFileDistances = cookingResults.filter { $0.filePath == "ml.md" }.map { $0.distance }

            if let cookingDist = cookingFileDistances.first, let mlDist = mlFileDistances.first {
                XCTAssertLessThan(
                    cookingDist, mlDist,
                    "Cooking content should rank higher (lower distance) for cooking query"
                )
            }
        }
    }

    // MARK: - Test 8: Multiple files with overlapping chunks

    func testMultipleFilesWithOverlappingChunks() throws {
        // Create a markdown file that will produce overlapping chunks
        let content = String(
            (1...100).map { "Line \($0): Content for overlapping chunk test." }.joined(separator: "\n")
        )
        createTextFile(name: "longfile.md", content: content)

        // Create another file
        let otherContent = "# Other File\n\nThis is a different file for testing."
        createTextFile(name: "other.md", content: otherContent)

        // Index both files
        let db = try makeInitializedDB()
        let scanner = FileScanner(directory: tempDir)
        let extractor = TextExtractor(chunkSize: 50, overlapSize: 10)

        for fileInfo in try scanner.scan() {
            let chunks = try extractor.extract(from: fileInfo)
            for chunk in chunks {
                let embedding = try embed(chunk.text)
                try db.insert(
                    filePath: fileInfo.relativePath,
                    lineStart: chunk.lineStart,
                    lineEnd: chunk.lineEnd,
                    chunkType: chunk.type,
                    pageNumber: chunk.pageNumber,
                    fileModifiedAt: fileInfo.modificationDate,
                    contentPreview: String(chunk.text.prefix(200)),
                    embedding: embedding
                )
            }
        }

        // Verify both files are searchable
        let results = try db.search(
            embedding: try embed("overlapping chunk test content"),
            limit: 10
        )

        XCTAssertGreaterThan(results.count, 0)

        // Verify we have entries from longfile
        let hasLongfileChunks = results.contains { $0.filePath == "longfile.md" }
        XCTAssertTrue(hasLongfileChunks)

        // Verify chunk structure (some entries should have lineStart/lineEnd)
        let chunkedEntries = results.filter { $0.lineStart != nil && $0.lineEnd != nil }
        XCTAssertGreaterThan(chunkedEntries.count, 0, "Should have line-based chunks")
    }
}
