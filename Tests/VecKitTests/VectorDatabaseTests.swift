import XCTest
import CSQLiteVec
@testable import VecKit

final class VectorDatabaseTests: XCTestCase {

    private var tempDir: URL!
    private var embeddingService: EmbeddingService!

    override func setUp() {
        super.setUp()
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("VecDBTests-\(UUID().uuidString)")
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

    // MARK: - 1. initialize() creates .vec/ dir and index.db

    func testInitializeCreatesVecDirAndDatabase() throws {
        let db = VectorDatabase(directory: tempDir)
        try db.initialize()

        let vecDir = tempDir.appendingPathComponent(".vec")
        let dbFile = vecDir.appendingPathComponent("index.db")

        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: vecDir.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue, ".vec should be a directory")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbFile.path), "index.db should exist")
    }

    // MARK: - 2. open() on non-existent DB throws databaseNotInitialized

    func testOpenOnNonExistentDBThrowsDatabaseNotInitialized() {
        let db = VectorDatabase(directory: tempDir)

        XCTAssertThrowsError(try db.open()) { error in
            guard let vecError = error as? VecError else {
                XCTFail("Expected VecError, got \(error)")
                return
            }
            if case .databaseNotInitialized = vecError {
                // Expected
            } else {
                XCTFail("Expected .databaseNotInitialized, got \(vecError)")
            }
        }
    }

    // MARK: - 3. open() on an initialized DB succeeds

    func testOpenOnInitializedDBSucceeds() throws {
        // Initialize first, then drop the reference so deinit closes the connection
        do {
            let db = VectorDatabase(directory: tempDir)
            try db.initialize()
        }

        // Now open with a fresh instance
        let db = VectorDatabase(directory: tempDir)
        XCTAssertNoThrow(try db.open())
    }

    // MARK: - 4. insert() returns a valid row ID (> 0)

    func testInsertReturnsValidRowID() throws {
        let db = try makeInitializedDB()
        let embedding = try embed("The quick brown fox jumps over the lazy dog")

        let rowID = try db.insert(
            filePath: "test.swift",
            lineStart: 1,
            lineEnd: 10,
            chunkType: .whole,
            pageNumber: nil,
            fileModifiedAt: Date(),
            contentPreview: "The quick brown fox",
            embedding: embedding
        )

        XCTAssertGreaterThan(rowID, 0)
    }

    // MARK: - 5. insert() with nil optional fields

    func testInsertWithNilOptionalFields() throws {
        let db = try makeInitializedDB()
        let embedding = try embed("Some test content for nil fields")

        let rowID = try db.insert(
            filePath: "document.pdf",
            lineStart: nil,
            lineEnd: nil,
            chunkType: .pdfPage,
            pageNumber: nil,
            fileModifiedAt: Date(),
            contentPreview: "Some test content",
            embedding: embedding
        )

        XCTAssertGreaterThan(rowID, 0)
    }

    // MARK: - 6. search() returns results ordered by ascending distance

    func testSearchResultsOrderedByAscendingDistance() throws {
        let db = try makeInitializedDB()

        let texts = [
            "Swift programming language",
            "The weather is sunny today",
            "Cooking pasta with tomato sauce",
            "Database indexing strategies"
        ]

        for (i, text) in texts.enumerated() {
            let emb = try embed(text)
            try db.insert(
                filePath: "file\(i).txt",
                lineStart: nil,
                lineEnd: nil,
                chunkType: .whole,
                pageNumber: nil,
                fileModifiedAt: Date(),
                contentPreview: text,
                embedding: emb
            )
        }

        let queryEmbedding = try embed("Swift programming language")
        let results = try db.search(embedding: queryEmbedding, limit: 4)

        XCTAssertEqual(results.count, 4)

        // Verify distances are in ascending order
        for i in 1..<results.count {
            XCTAssertLessThanOrEqual(
                results[i - 1].distance, results[i].distance,
                "Results should be ordered by ascending distance"
            )
        }
    }

    // MARK: - 7. search() — similar text has lower distance than dissimilar text

    func testSearchSimilarTextHasLowerDistance() throws {
        let db = try makeInitializedDB()

        let similarText = "Swift is a programming language for iOS and macOS development"
        let dissimilarText = "The recipe calls for two cups of flour and one egg"

        let similarEmb = try embed(similarText)
        let dissimilarEmb = try embed(dissimilarText)

        try db.insert(
            filePath: "similar.swift",
            lineStart: nil,
            lineEnd: nil,
            chunkType: .whole,
            pageNumber: nil,
            fileModifiedAt: Date(),
            contentPreview: similarText,
            embedding: similarEmb
        )

        try db.insert(
            filePath: "dissimilar.txt",
            lineStart: nil,
            lineEnd: nil,
            chunkType: .whole,
            pageNumber: nil,
            fileModifiedAt: Date(),
            contentPreview: dissimilarText,
            embedding: dissimilarEmb
        )

        let queryEmb = try embed("Swift programming for Apple platforms")
        let results = try db.search(embedding: queryEmb, limit: 2)

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].filePath, "similar.swift",
                       "The similar text should be the closest match")
        XCTAssertLessThan(results[0].distance, results[1].distance)
    }

    // MARK: - 8. search() on empty DB returns empty array

    func testSearchOnEmptyDBReturnsEmptyArray() throws {
        let db = try makeInitializedDB()
        let queryEmb = try embed("test query")
        let results = try db.search(embedding: queryEmb, limit: 10)

        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - 9. search() respects the limit parameter

    func testSearchRespectsLimitParameter() throws {
        let db = try makeInitializedDB()

        // Insert 5 entries
        let sentences = [
            "Alpha algorithm analysis",
            "Beta binary buffer",
            "Gamma graph generation",
            "Delta database design",
            "Epsilon error estimation"
        ]

        for (i, text) in sentences.enumerated() {
            let emb = try embed(text)
            try db.insert(
                filePath: "file\(i).txt",
                lineStart: nil,
                lineEnd: nil,
                chunkType: .whole,
                pageNumber: nil,
                fileModifiedAt: Date(),
                contentPreview: text,
                embedding: emb
            )
        }

        let queryEmb = try embed("algorithm design")

        let results2 = try db.search(embedding: queryEmb, limit: 2)
        XCTAssertEqual(results2.count, 2)

        let results3 = try db.search(embedding: queryEmb, limit: 3)
        XCTAssertEqual(results3.count, 3)

        let results5 = try db.search(embedding: queryEmb, limit: 5)
        XCTAssertEqual(results5.count, 5)
    }

    // MARK: - 10. search() result fields map correctly

    func testSearchResultFieldsMapCorrectly() throws {
        let db = try makeInitializedDB()
        let text = "Function to calculate fibonacci numbers"
        let emb = try embed(text)

        try db.insert(
            filePath: "src/math/fibonacci.swift",
            lineStart: 42,
            lineEnd: 58,
            chunkType: .chunk,
            pageNumber: nil,
            fileModifiedAt: Date(),
            contentPreview: text,
            embedding: emb
        )

        let results = try db.search(embedding: emb, limit: 1)
        XCTAssertEqual(results.count, 1)

        let result = results[0]
        XCTAssertEqual(result.filePath, "src/math/fibonacci.swift")
        XCTAssertEqual(result.lineStart, 42)
        XCTAssertEqual(result.lineEnd, 58)
        XCTAssertEqual(result.chunkType, .chunk)
        XCTAssertNil(result.pageNumber)
        XCTAssertEqual(result.contentPreview, text)
        XCTAssertGreaterThanOrEqual(result.distance, 0)
    }

    func testSearchResultFieldsWithPDFPage() throws {
        let db = try makeInitializedDB()
        let text = "Introduction to machine learning concepts"
        let emb = try embed(text)

        try db.insert(
            filePath: "docs/ml-guide.pdf",
            lineStart: nil,
            lineEnd: nil,
            chunkType: .pdfPage,
            pageNumber: 3,
            fileModifiedAt: Date(),
            contentPreview: text,
            embedding: emb
        )

        let results = try db.search(embedding: emb, limit: 1)
        XCTAssertEqual(results.count, 1)

        let result = results[0]
        XCTAssertEqual(result.filePath, "docs/ml-guide.pdf")
        XCTAssertNil(result.lineStart)
        XCTAssertNil(result.lineEnd)
        XCTAssertEqual(result.chunkType, .pdfPage)
        XCTAssertEqual(result.pageNumber, 3)
        XCTAssertEqual(result.contentPreview, text)
    }

    // MARK: - 11. allIndexedFiles() returns correct paths and max modification dates

    func testAllIndexedFilesReturnsCorrectPathsAndDates() throws {
        let db = try makeInitializedDB()

        let earlyDate = Date(timeIntervalSince1970: 1000000)
        let lateDate = Date(timeIntervalSince1970: 2000000)

        let emb1 = try embed("First chunk of the readme file")
        let emb2 = try embed("Second chunk of the readme file")
        let emb3 = try embed("Main swift source file content")

        // Two entries for the same file with different dates
        try db.insert(
            filePath: "README.md",
            lineStart: 1,
            lineEnd: 50,
            chunkType: .chunk,
            pageNumber: nil,
            fileModifiedAt: earlyDate,
            contentPreview: "First chunk",
            embedding: emb1
        )

        try db.insert(
            filePath: "README.md",
            lineStart: 51,
            lineEnd: 100,
            chunkType: .chunk,
            pageNumber: nil,
            fileModifiedAt: lateDate,
            contentPreview: "Second chunk",
            embedding: emb2
        )

        try db.insert(
            filePath: "main.swift",
            lineStart: nil,
            lineEnd: nil,
            chunkType: .whole,
            pageNumber: nil,
            fileModifiedAt: earlyDate,
            contentPreview: "Main swift file",
            embedding: emb3
        )

        let files = try db.allIndexedFiles()

        XCTAssertEqual(files.count, 2)
        XCTAssertNotNil(files["README.md"])
        XCTAssertNotNil(files["main.swift"])

        // README.md should have the later date (MAX)
        XCTAssertEqual(files["README.md"]!.timeIntervalSince1970, lateDate.timeIntervalSince1970, accuracy: 1.0)
        XCTAssertEqual(files["main.swift"]!.timeIntervalSince1970, earlyDate.timeIntervalSince1970, accuracy: 1.0)
    }

    // MARK: - 12. allIndexedFiles() on empty DB returns empty dict

    func testAllIndexedFilesOnEmptyDBReturnsEmptyDict() throws {
        let db = try makeInitializedDB()
        let files = try db.allIndexedFiles()
        XCTAssertTrue(files.isEmpty)
    }

    // MARK: - 13. removeEntries(forPath:) removes entries, returns correct count

    func testRemoveEntriesRemovesAndReturnsCorrectCount() throws {
        let db = try makeInitializedDB()

        let emb1 = try embed("First chunk for removal test")
        let emb2 = try embed("Second chunk for removal test")

        try db.insert(
            filePath: "toremove.swift",
            lineStart: 1,
            lineEnd: 50,
            chunkType: .chunk,
            pageNumber: nil,
            fileModifiedAt: Date(),
            contentPreview: "First chunk",
            embedding: emb1
        )

        try db.insert(
            filePath: "toremove.swift",
            lineStart: 51,
            lineEnd: 100,
            chunkType: .chunk,
            pageNumber: nil,
            fileModifiedAt: Date(),
            contentPreview: "Second chunk",
            embedding: emb2
        )

        let removed = try db.removeEntries(forPath: "toremove.swift")
        XCTAssertEqual(removed, 2)

        // Verify they're gone
        let files = try db.allIndexedFiles()
        XCTAssertNil(files["toremove.swift"])
    }

    // MARK: - 14. removeEntries(forPath:) for non-existent path returns 0

    func testRemoveEntriesForNonExistentPathReturnsZero() throws {
        let db = try makeInitializedDB()
        let removed = try db.removeEntries(forPath: "nonexistent.swift")
        XCTAssertEqual(removed, 0)
    }

    // MARK: - 15. Multiple files: insert two, remove one, verify the other remains

    func testMultipleFilesInsertTwoRemoveOneOtherRemains() throws {
        let db = try makeInitializedDB()

        let emb1 = try embed("Content of file alpha for multi-file test")
        let emb2 = try embed("Content of file beta for multi-file test")

        try db.insert(
            filePath: "alpha.swift",
            lineStart: nil,
            lineEnd: nil,
            chunkType: .whole,
            pageNumber: nil,
            fileModifiedAt: Date(),
            contentPreview: "Alpha content",
            embedding: emb1
        )

        try db.insert(
            filePath: "beta.swift",
            lineStart: nil,
            lineEnd: nil,
            chunkType: .whole,
            pageNumber: nil,
            fileModifiedAt: Date(),
            contentPreview: "Beta content",
            embedding: emb2
        )

        // Remove alpha
        let removed = try db.removeEntries(forPath: "alpha.swift")
        XCTAssertEqual(removed, 1)

        // Beta should still be there
        let files = try db.allIndexedFiles()
        XCTAssertEqual(files.count, 1)
        XCTAssertNotNil(files["beta.swift"])
        XCTAssertNil(files["alpha.swift"])

        // Beta should still be searchable
        let results = try db.search(embedding: emb2, limit: 10)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].filePath, "beta.swift")
    }

    // MARK: - 16. open() on corrupted DB (missing chunks table) throws databaseCorrupted

    func testOpenOnCorruptedDBThrowsDatabaseCorrupted() throws {
        // Initialize a valid database
        do {
            let db = VectorDatabase(directory: tempDir)
            try db.initialize()
        }

        // Corrupt it by dropping the chunks table via raw SQL
        let dbPath = tempDir.appendingPathComponent(".vec")
            .appendingPathComponent("index.db").path
        var rawDB: OpaquePointer?
        guard sqlite3_open(dbPath, &rawDB) == SQLITE_OK else {
            XCTFail("Failed to open raw database")
            return
        }
        defer { sqlite3_close(rawDB) }

        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(rawDB, "DROP TABLE IF EXISTS chunks", nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            XCTFail("Failed to drop chunks table: \(msg)")
            return
        }
        sqlite3_close(rawDB)
        rawDB = nil

        // Now open() should detect the missing table
        let db = VectorDatabase(directory: tempDir)
        XCTAssertThrowsError(try db.open()) { error in
            guard let vecError = error as? VecError else {
                XCTFail("Expected VecError, got \(error)")
                return
            }
            if case .databaseCorrupted(let detail) = vecError {
                XCTAssertTrue(detail.contains("chunks"),
                              "Error should mention missing 'chunks' table, got: \(detail)")
            } else {
                XCTFail("Expected .databaseCorrupted, got \(vecError)")
            }
        }
    }

}
