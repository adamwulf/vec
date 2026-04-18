import XCTest
import CSQLiteVec
@testable import VecKit

final class VectorDatabaseTests: XCTestCase {

    private var tempDir: URL!
    private var dbDir: URL!
    private var sourceDir: URL!
    private var embeddingService: NomicEmbedder!

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
        dbDir = tempDir.appendingPathComponent("db")
        sourceDir = tempDir.appendingPathComponent("source")
        try! FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        embeddingService = NomicEmbedder()
    }

    override func tearDown() {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    // MARK: - Helpers

    /// Embed a string using the real NomicEmbedder (document
    /// prefix, since these helpers build index entries). Fails the
    /// test if the embedding comes back empty.
    private func embed(_ text: String, file: StaticString = #file, line: UInt = #line) async throws -> [Float] {
        let vector = try await embeddingService.embedDocument(text)
        XCTAssertFalse(vector.isEmpty, "NomicEmbedder returned empty vector for: \(text)", file: file, line: line)
        return vector
    }

    /// Create an initialized VectorDatabase using dbDir and sourceDir.
    private func makeInitializedDB() async throws -> VectorDatabase {
        let db = VectorDatabase(databaseDirectory: dbDir, sourceDirectory: sourceDir)
        try await db.initialize()
        return db
    }

    // MARK: - 1. initialize() creates database dir and index.db

    func testInitializeCreatesDatabaseDirAndDatabase() async throws {
        let db = VectorDatabase(databaseDirectory: dbDir, sourceDirectory: sourceDir)
        try await db.initialize()

        let dbFile = dbDir.appendingPathComponent("index.db")

        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbDir.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue, "databaseDirectory should be a directory")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbFile.path), "index.db should exist")
    }

    // MARK: - 2. open() on non-existent DB throws databaseNotInitialized

    func testOpenOnNonExistentDBThrowsDatabaseNotInitialized() async {
        let db = VectorDatabase(databaseDirectory: dbDir, sourceDirectory: sourceDir)

        do {
            try await db.open()
            XCTFail("Expected VecError.databaseNotInitialized")
        } catch let error as VecError {
            if case .databaseNotInitialized = error {
                // Expected
            } else {
                XCTFail("Expected .databaseNotInitialized, got \(error)")
            }
        } catch {
            XCTFail("Expected VecError, got \(error)")
        }
    }

    // MARK: - 3. open() on an initialized DB succeeds

    func testOpenOnInitializedDBSucceeds() async throws {
        // Initialize first, then drop the reference so deinit closes the connection
        do {
            let db = VectorDatabase(databaseDirectory: dbDir, sourceDirectory: sourceDir)
            try await db.initialize()
        }

        // Now open with a fresh instance
        let db = VectorDatabase(databaseDirectory: dbDir, sourceDirectory: sourceDir)
        try await db.open()
    }

    // MARK: - 4. insert() returns a valid row ID (> 0)

    func testInsertReturnsValidRowID() async throws {
        let db = try await makeInitializedDB()
        let embedding = try await embed("The quick brown fox jumps over the lazy dog")

        let rowID = try await db.insert(
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

    func testInsertWithNilOptionalFields() async throws {
        let db = try await makeInitializedDB()
        let embedding = try await embed("Some test content for nil fields")

        let rowID = try await db.insert(
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

    func testSearchResultsOrderedByAscendingDistance() async throws {
        let db = try await makeInitializedDB()

        let texts = [
            "Swift programming language",
            "The weather is sunny today",
            "Cooking pasta with tomato sauce",
            "Database indexing strategies"
        ]

        for (i, text) in texts.enumerated() {
            let emb = try await embed(text)
            try await db.insert(
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

        let queryEmbedding = try await embed("Swift programming language")
        let results = try await db.search(embedding: queryEmbedding, limit: 4)

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

    func testSearchSimilarTextHasLowerDistance() async throws {
        let db = try await makeInitializedDB()

        let similarText = "Swift is a programming language for iOS and macOS development"
        let dissimilarText = "The recipe calls for two cups of flour and one egg"

        let similarEmb = try await embed(similarText)
        let dissimilarEmb = try await embed(dissimilarText)

        try await db.insert(
            filePath: "similar.swift",
            lineStart: nil,
            lineEnd: nil,
            chunkType: .whole,
            pageNumber: nil,
            fileModifiedAt: Date(),
            contentPreview: similarText,
            embedding: similarEmb
        )

        try await db.insert(
            filePath: "dissimilar.txt",
            lineStart: nil,
            lineEnd: nil,
            chunkType: .whole,
            pageNumber: nil,
            fileModifiedAt: Date(),
            contentPreview: dissimilarText,
            embedding: dissimilarEmb
        )

        let queryEmb = try await embed("Swift programming for Apple platforms")
        let results = try await db.search(embedding: queryEmb, limit: 2)

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].filePath, "similar.swift",
                       "The similar text should be the closest match")
        XCTAssertLessThan(results[0].distance, results[1].distance)
    }

    // MARK: - 8. search() on empty DB returns empty array

    func testSearchOnEmptyDBReturnsEmptyArray() async throws {
        let db = try await makeInitializedDB()
        let queryEmb = try await embed("test query")
        let results = try await db.search(embedding: queryEmb, limit: 10)

        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - 9. search() respects the limit parameter

    func testSearchRespectsLimitParameter() async throws {
        let db = try await makeInitializedDB()

        // Insert 5 entries
        let sentences = [
            "Alpha algorithm analysis",
            "Beta binary buffer",
            "Gamma graph generation",
            "Delta database design",
            "Epsilon error estimation"
        ]

        for (i, text) in sentences.enumerated() {
            let emb = try await embed(text)
            try await db.insert(
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

        let queryEmb = try await embed("algorithm design")

        let results2 = try await db.search(embedding: queryEmb, limit: 2)
        XCTAssertEqual(results2.count, 2)

        let results3 = try await db.search(embedding: queryEmb, limit: 3)
        XCTAssertEqual(results3.count, 3)

        let results5 = try await db.search(embedding: queryEmb, limit: 5)
        XCTAssertEqual(results5.count, 5)
    }

    // MARK: - 10. search() result fields map correctly

    func testSearchResultFieldsMapCorrectly() async throws {
        let db = try await makeInitializedDB()
        let text = "Function to calculate fibonacci numbers"
        let emb = try await embed(text)

        try await db.insert(
            filePath: "src/math/fibonacci.swift",
            lineStart: 42,
            lineEnd: 58,
            chunkType: .chunk,
            pageNumber: nil,
            fileModifiedAt: Date(),
            contentPreview: text,
            embedding: emb
        )

        let results = try await db.search(embedding: emb, limit: 1)
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

    func testSearchResultFieldsWithPDFPage() async throws {
        let db = try await makeInitializedDB()
        let text = "Introduction to machine learning concepts"
        let emb = try await embed(text)

        try await db.insert(
            filePath: "docs/ml-guide.pdf",
            lineStart: nil,
            lineEnd: nil,
            chunkType: .pdfPage,
            pageNumber: 3,
            fileModifiedAt: Date(),
            contentPreview: text,
            embedding: emb
        )

        let results = try await db.search(embedding: emb, limit: 1)
        XCTAssertEqual(results.count, 1)

        let result = results[0]
        XCTAssertEqual(result.filePath, "docs/ml-guide.pdf")
        XCTAssertNil(result.lineStart)
        XCTAssertNil(result.lineEnd)
        XCTAssertEqual(result.chunkType, .pdfPage)
        XCTAssertEqual(result.pageNumber, 3)
        XCTAssertEqual(result.contentPreview, text)
    }

    // MARK: - 11. allIndexedFiles() returns correct paths and modification dates

    func testAllIndexedFilesReturnsCorrectPathsAndDates() async throws {
        let db = try await makeInitializedDB()

        let earlyDate = Date(timeIntervalSince1970: 1000000)
        let lateDate = Date(timeIntervalSince1970: 2000000)

        let emb1 = try await embed("First chunk of the readme file")
        let emb2 = try await embed("Second chunk of the readme file")
        let emb3 = try await embed("Main swift source file content")

        // Two entries for the same file with different dates
        try await db.insert(
            filePath: "README.md",
            lineStart: 1,
            lineEnd: 50,
            chunkType: .chunk,
            pageNumber: nil,
            fileModifiedAt: earlyDate,
            contentPreview: "First chunk",
            embedding: emb1
        )

        try await db.insert(
            filePath: "README.md",
            lineStart: 51,
            lineEnd: 100,
            chunkType: .chunk,
            pageNumber: nil,
            fileModifiedAt: lateDate,
            contentPreview: "Second chunk",
            embedding: emb2
        )

        try await db.insert(
            filePath: "main.swift",
            lineStart: nil,
            lineEnd: nil,
            chunkType: .whole,
            pageNumber: nil,
            fileModifiedAt: earlyDate,
            contentPreview: "Main swift file",
            embedding: emb3
        )

        // Mark files as fully indexed (as update-index would after all chunks succeed)
        try await db.markFileIndexed(path: "README.md", modifiedAt: lateDate)
        try await db.markFileIndexed(path: "main.swift", modifiedAt: earlyDate)

        let files = try await db.allIndexedFiles()

        XCTAssertEqual(files.count, 2)
        XCTAssertNotNil(files["README.md"])
        XCTAssertNotNil(files["main.swift"])

        // README.md should have the date passed to markFileIndexed
        XCTAssertEqual(files["README.md"]!.timeIntervalSince1970, lateDate.timeIntervalSince1970, accuracy: 1.0)
        XCTAssertEqual(files["main.swift"]!.timeIntervalSince1970, earlyDate.timeIntervalSince1970, accuracy: 1.0)
    }

    // MARK: - 12. allIndexedFiles() on empty DB returns empty dict

    func testAllIndexedFilesOnEmptyDBReturnsEmptyDict() async throws {
        let db = try await makeInitializedDB()
        let files = try await db.allIndexedFiles()
        XCTAssertTrue(files.isEmpty)
    }

    // MARK: - 13. removeEntries(forPath:) removes entries, returns correct count

    func testRemoveEntriesRemovesAndReturnsCorrectCount() async throws {
        let db = try await makeInitializedDB()

        let modDate = Date()
        let emb1 = try await embed("First chunk for removal test")
        let emb2 = try await embed("Second chunk for removal test")

        try await db.insert(
            filePath: "toremove.swift",
            lineStart: 1,
            lineEnd: 50,
            chunkType: .chunk,
            pageNumber: nil,
            fileModifiedAt: modDate,
            contentPreview: "First chunk",
            embedding: emb1
        )

        try await db.insert(
            filePath: "toremove.swift",
            lineStart: 51,
            lineEnd: 100,
            chunkType: .chunk,
            pageNumber: nil,
            fileModifiedAt: modDate,
            contentPreview: "Second chunk",
            embedding: emb2
        )

        try await db.markFileIndexed(path: "toremove.swift", modifiedAt: modDate)

        let removed = try await db.removeEntries(forPath: "toremove.swift")
        XCTAssertEqual(removed, 2)

        // Verify they're gone from allIndexedFiles (completion record removed too)
        let files = try await db.allIndexedFiles()
        XCTAssertNil(files["toremove.swift"])
    }

    // MARK: - 14. removeEntries(forPath:) for non-existent path returns 0

    func testRemoveEntriesForNonExistentPathReturnsZero() async throws {
        let db = try await makeInitializedDB()
        let removed = try await db.removeEntries(forPath: "nonexistent.swift")
        XCTAssertEqual(removed, 0)
    }

    // MARK: - 15. Multiple files: insert two, remove one, verify the other remains

    func testMultipleFilesInsertTwoRemoveOneOtherRemains() async throws {
        let db = try await makeInitializedDB()

        let modDate = Date()
        let emb1 = try await embed("Content of file alpha for multi-file test")
        let emb2 = try await embed("Content of file beta for multi-file test")

        try await db.insert(
            filePath: "alpha.swift",
            lineStart: nil,
            lineEnd: nil,
            chunkType: .whole,
            pageNumber: nil,
            fileModifiedAt: modDate,
            contentPreview: "Alpha content",
            embedding: emb1
        )
        try await db.markFileIndexed(path: "alpha.swift", modifiedAt: modDate)

        try await db.insert(
            filePath: "beta.swift",
            lineStart: nil,
            lineEnd: nil,
            chunkType: .whole,
            pageNumber: nil,
            fileModifiedAt: modDate,
            contentPreview: "Beta content",
            embedding: emb2
        )
        try await db.markFileIndexed(path: "beta.swift", modifiedAt: modDate)

        // Remove alpha
        let removed = try await db.removeEntries(forPath: "alpha.swift")
        XCTAssertEqual(removed, 1)

        // Beta should still be there
        let files = try await db.allIndexedFiles()
        XCTAssertEqual(files.count, 1)
        XCTAssertNotNil(files["beta.swift"])
        XCTAssertNil(files["alpha.swift"])

        // Beta should still be searchable
        let results = try await db.search(embedding: emb2, limit: 10)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].filePath, "beta.swift")
    }

    // MARK: - Partial indexing: chunks without completion record are not considered indexed

    func testPartiallyIndexedFileNotReturnedByAllIndexedFiles() async throws {
        let db = try await makeInitializedDB()

        let modDate = Date()
        let emb1 = try await embed("First chunk of a partially indexed file")
        let emb2 = try await embed("Second chunk of a partially indexed file")

        // Insert chunks but do NOT call markFileIndexed — simulates interruption
        try await db.insert(
            filePath: "partial.swift",
            lineStart: 1,
            lineEnd: 50,
            chunkType: .chunk,
            pageNumber: nil,
            fileModifiedAt: modDate,
            contentPreview: "First chunk",
            embedding: emb1
        )

        try await db.insert(
            filePath: "partial.swift",
            lineStart: 51,
            lineEnd: 100,
            chunkType: .chunk,
            pageNumber: nil,
            fileModifiedAt: modDate,
            contentPreview: "Second chunk",
            embedding: emb2
        )

        // allIndexedFiles should NOT include partial.swift
        let files = try await db.allIndexedFiles()
        XCTAssertNil(files["partial.swift"],
                     "File with chunks but no completion record should not appear in allIndexedFiles")

        // The chunks still exist in the database (they just aren't tracked as complete)
        let count = try await db.totalChunkCount()
        XCTAssertEqual(count, 2)
    }

    func testUnmarkFileIndexedRemovesCompletionRecord() async throws {
        let db = try await makeInitializedDB()

        let modDate = Date()
        let emb = try await embed("Content for unmark test")

        try await db.insert(
            filePath: "test.swift",
            lineStart: nil,
            lineEnd: nil,
            chunkType: .whole,
            pageNumber: nil,
            fileModifiedAt: modDate,
            contentPreview: "Test content",
            embedding: emb
        )
        try await db.markFileIndexed(path: "test.swift", modifiedAt: modDate)

        // Verify it's indexed
        var files = try await db.allIndexedFiles()
        XCTAssertNotNil(files["test.swift"])

        // Unmark it
        try await db.unmarkFileIndexed(path: "test.swift")

        // Should no longer appear in allIndexedFiles
        files = try await db.allIndexedFiles()
        XCTAssertNil(files["test.swift"],
                     "File should not appear in allIndexedFiles after unmarkFileIndexed")

        // But chunks should still exist
        let count = try await db.totalChunkCount()
        XCTAssertEqual(count, 1)
    }

    // MARK: - 16. totalChunkCount() returns correct totals

    func testTotalChunkCountOnEmptyDB() async throws {
        let db = try await makeInitializedDB()
        let count = try await db.totalChunkCount()
        XCTAssertEqual(count, 0)
    }

    func testTotalChunkCountWithMultipleFilesAndChunks() async throws {
        let db = try await makeInitializedDB()

        let emb1 = try await embed("First chunk of the readme file")
        let emb2 = try await embed("Second chunk of the readme file")
        let emb3 = try await embed("Main swift source file content")

        // Two chunks for one file
        try await db.insert(
            filePath: "README.md",
            lineStart: 1,
            lineEnd: 50,
            chunkType: .chunk,
            pageNumber: nil,
            fileModifiedAt: Date(),
            contentPreview: "First chunk",
            embedding: emb1
        )

        try await db.insert(
            filePath: "README.md",
            lineStart: 51,
            lineEnd: 100,
            chunkType: .chunk,
            pageNumber: nil,
            fileModifiedAt: Date(),
            contentPreview: "Second chunk",
            embedding: emb2
        )

        // One chunk for another file
        try await db.insert(
            filePath: "main.swift",
            lineStart: nil,
            lineEnd: nil,
            chunkType: .whole,
            pageNumber: nil,
            fileModifiedAt: Date(),
            contentPreview: "Main swift file",
            embedding: emb3
        )

        let count = try await db.totalChunkCount()
        XCTAssertEqual(count, 3)
    }

    // MARK: - 17. Search accuracy — full ranking order across diverse topics

    func testSearchFullRankingOrderDiverseTopics() async throws {
        let db = try await makeInitializedDB()

        // 8 documents spanning very different topics
        let docs: [(path: String, content: String)] = [
            ("cooking.txt", "This recipe explains how to bake a chocolate cake with cocoa powder, butter, eggs, and sugar in the oven"),
            ("astronomy.txt", "The Milky Way galaxy contains hundreds of billions of stars and planets orbiting around them in space"),
            ("programming.txt", "Swift programming language uses closures, generics, and protocols for building iOS and macOS applications"),
            ("sports.txt", "Basketball players dribble the ball down the court and shoot hoops during the championship game"),
            ("music.txt", "Playing guitar chords and piano melodies together creates beautiful jazz harmonies and rhythms"),
            ("medicine.txt", "Doctors prescribe antibiotics to treat bacterial infections and monitor patients for side effects"),
            ("history.txt", "The Roman Empire expanded across Europe with legions of soldiers conquering territories for centuries"),
            ("gardening.txt", "Growing tomatoes and peppers in the backyard garden requires sunlight, water, and rich soil"),
        ]

        for doc in docs {
            let emb = try await embed(doc.content)
            try await db.insert(
                filePath: doc.path,
                lineStart: nil,
                lineEnd: nil,
                chunkType: .whole,
                pageNumber: nil,
                fileModifiedAt: Date(),
                contentPreview: doc.content,
                embedding: emb
            )
        }

        // Query: baking — expect cooking #1
        let bakingEmb = try await embed("baking a chocolate dessert in the kitchen")
        let bakingResults = try await db.search(embedding: bakingEmb, limit: 8)
        XCTAssertEqual(bakingResults[0].filePath, "cooking.txt",
                       "Cooking doc should rank #1 for a baking query")

        // Query: outer space — expect astronomy #1
        let spaceEmb = try await embed("stars and galaxies in outer space")
        let spaceResults = try await db.search(embedding: spaceEmb, limit: 8)
        XCTAssertEqual(spaceResults[0].filePath, "astronomy.txt",
                       "Astronomy doc should rank #1 for a space query")

        // Query: iOS development — expect programming #1
        let devEmb = try await embed("building apps for iOS with Swift")
        let devResults = try await db.search(embedding: devEmb, limit: 8)
        XCTAssertEqual(devResults[0].filePath, "programming.txt",
                       "Programming doc should rank #1 for an iOS dev query")

        // Query: basketball — expect sports #1
        let sportsEmb = try await embed("shooting hoops in a basketball game")
        let sportsResults = try await db.search(embedding: sportsEmb, limit: 8)
        XCTAssertEqual(sportsResults[0].filePath, "sports.txt",
                       "Sports doc should rank #1 for a basketball query")

        // Query: jazz — expect music #1
        let jazzEmb = try await embed("jazz piano and guitar melodies")
        let jazzResults = try await db.search(embedding: jazzEmb, limit: 8)
        XCTAssertEqual(jazzResults[0].filePath, "music.txt",
                       "Music doc should rank #1 for a jazz query")

        // Query: treating infections — expect medicine #1
        let medEmb = try await embed("treating bacterial infections with medicine")
        let medResults = try await db.search(embedding: medEmb, limit: 8)
        XCTAssertEqual(medResults[0].filePath, "medicine.txt",
                       "Medicine doc should rank #1 for an infections query")

        // Query: Roman Empire — expect history #1
        let histEmb = try await embed("the ancient Roman Empire and its soldiers")
        let histResults = try await db.search(embedding: histEmb, limit: 8)
        XCTAssertEqual(histResults[0].filePath, "history.txt",
                       "History doc should rank #1 for a Roman Empire query")

        // Query: growing vegetables — expect gardening #1
        let gardenEmb = try await embed("growing vegetables in the garden with sunlight")
        let gardenResults = try await db.search(embedding: gardenEmb, limit: 8)
        XCTAssertEqual(gardenResults[0].filePath, "gardening.txt",
                       "Gardening doc should rank #1 for a vegetables query")
    }

    // MARK: - 18. Search accuracy — ranking across related professional domains

    func testSearchRankingAcrossRelatedProfessionalDomains() async throws {
        let db = try await makeInitializedDB()

        // Four professional domains that share a "technical" flavor but are distinct
        let docs: [(path: String, content: String)] = [
            ("veterinary.txt", "Veterinarians treat sick dogs and cats at animal hospitals by prescribing medicine and performing surgery"),
            ("dentistry.txt", "Dentists fill cavities, perform root canals, and clean teeth to maintain oral health and prevent gum disease"),
            ("aviation.txt", "Pilots navigate airplanes through turbulence and communicate with air traffic control towers during flights"),
            ("cooking.txt", "Baking sourdough bread requires flour, water, salt, and a natural yeast starter culture"),
        ]

        for doc in docs {
            let emb = try await embed(doc.content)
            try await db.insert(
                filePath: doc.path,
                lineStart: nil,
                lineEnd: nil,
                chunkType: .whole,
                pageNumber: nil,
                fileModifiedAt: Date(),
                contentPreview: doc.content,
                embedding: emb
            )
        }

        // Query about pet health — veterinary should rank #1
        let petEmb = try await embed("treating sick pets at the animal clinic")
        let petResults = try await db.search(embedding: petEmb, limit: 4)
        XCTAssertEqual(petResults[0].filePath, "veterinary.txt",
                       "Veterinary doc should rank #1 for a pet health query")

        // Query about teeth — dentistry should rank #1
        let teethEmb = try await embed("filling cavities and cleaning teeth at the dental office")
        let teethResults = try await db.search(embedding: teethEmb, limit: 4)
        XCTAssertEqual(teethResults[0].filePath, "dentistry.txt",
                       "Dentistry doc should rank #1 for a teeth query")

        // Query about flying — aviation should rank #1
        let flyEmb = try await embed("flying airplanes and communicating with control towers")
        let flyResults = try await db.search(embedding: flyEmb, limit: 4)
        XCTAssertEqual(flyResults[0].filePath, "aviation.txt",
                       "Aviation doc should rank #1 for a flying query")

        // Query about baking — cooking should rank #1
        let bakeEmb = try await embed("making bread with flour and yeast")
        let bakeResults = try await db.search(embedding: bakeEmb, limit: 4)
        XCTAssertEqual(bakeResults[0].filePath, "cooking.txt",
                       "Cooking doc should rank #1 for a baking query")
    }

    // MARK: - 19. Search accuracy — verify complete ranking order, not just top-1

    func testSearchVerifiesCompleteRankingOrder() async throws {
        let db = try await makeInitializedDB()

        // Documents with graduated relevance to "Italian pasta"
        // italian: directly about pasta → cooking: general kitchen/food → nutrition: food-adjacent → astronomy: unrelated
        let docs: [(path: String, content: String)] = [
            ("italian.txt", "Italian pasta recipes include spaghetti carbonara made with eggs, cheese, and pancetta in a creamy sauce"),
            ("cooking.txt", "Home cooking involves preparing meals in the kitchen using fresh ingredients, pots, and pans on the stove"),
            ("nutrition.txt", "A balanced diet includes proteins, carbohydrates, vitamins, and minerals for maintaining good health"),
            ("astronomy.txt", "Telescopes observe distant galaxies, nebulae, and black holes billions of light years from Earth"),
        ]

        for doc in docs {
            let emb = try await embed(doc.content)
            try await db.insert(
                filePath: doc.path,
                lineStart: nil,
                lineEnd: nil,
                chunkType: .whole,
                pageNumber: nil,
                fileModifiedAt: Date(),
                contentPreview: doc.content,
                embedding: emb
            )
        }

        let queryEmb = try await embed("making Italian pasta with eggs and cheese")
        let results = try await db.search(embedding: queryEmb, limit: 4)

        XCTAssertEqual(results.count, 4)

        // italian.txt should be #1 (directly about pasta recipes)
        XCTAssertEqual(results[0].filePath, "italian.txt",
                       "Italian doc should rank #1 — directly about pasta recipes")
        // cooking.txt should be #2 (general cooking, food-related)
        XCTAssertEqual(results[1].filePath, "cooking.txt",
                       "Cooking doc should rank #2 — general food preparation")
        // nutrition.txt should be #3 (food-adjacent but not cooking)
        XCTAssertEqual(results[2].filePath, "nutrition.txt",
                       "Nutrition doc should rank #3 — food-adjacent topic")
        // astronomy.txt should be #4 (completely unrelated)
        XCTAssertEqual(results[3].filePath, "astronomy.txt",
                       "Astronomy doc should rank last — completely unrelated to cooking")
    }

    // MARK: - 20. Search accuracy — larger corpus (12+ documents)

    func testSearchAccuracyWithLargerCorpus() async throws {
        let db = try await makeInitializedDB()

        let docs: [(path: String, content: String)] = [
            ("biology.txt", "Cells divide through mitosis and meiosis to create new organisms and repair damaged tissue"),
            ("chemistry.txt", "Chemical bonds form when atoms share or transfer electrons in covalent and ionic reactions"),
            ("physics.txt", "Gravity is a fundamental force that attracts objects with mass toward each other in the universe"),
            ("math.txt", "Calculus uses derivatives and integrals to analyze rates of change and areas under curves"),
            ("literature.txt", "Shakespeare wrote plays and sonnets exploring love, power, jealousy, and the human condition"),
            ("philosophy.txt", "Socrates used dialectic questioning to examine ethics, knowledge, and the nature of reality"),
            ("economics.txt", "Supply and demand curves determine market prices and quantities of goods traded in economies"),
            ("geography.txt", "Tectonic plates shift and collide creating mountains, earthquakes, and volcanic eruptions on Earth"),
            ("psychology.txt", "Cognitive behavioral therapy helps patients change negative thinking patterns and behaviors"),
            ("law.txt", "Constitutional law defines the structure of government and protects individual rights and freedoms"),
            ("architecture.txt", "Gothic cathedrals feature pointed arches, flying buttresses, and stained glass windows"),
            ("oceanography.txt", "Ocean currents circulate warm and cold water around the globe affecting weather and climate patterns"),
        ]

        for doc in docs {
            let emb = try await embed(doc.content)
            try await db.insert(
                filePath: doc.path,
                lineStart: nil,
                lineEnd: nil,
                chunkType: .whole,
                pageNumber: nil,
                fileModifiedAt: Date(),
                contentPreview: doc.content,
                embedding: emb
            )
        }

        // Query about atomic bonding — chemistry should be #1
        let chemEmb = try await embed("atoms bonding in chemical reactions with electrons")
        let chemResults = try await db.search(embedding: chemEmb, limit: 12)
        XCTAssertEqual(chemResults[0].filePath, "chemistry.txt",
                       "Chemistry doc should rank #1 for atomic bonding query")

        // Query about Shakespeare — literature should be #1
        let litEmb = try await embed("Shakespeare plays about love and tragedy")
        let litResults = try await db.search(embedding: litEmb, limit: 12)
        XCTAssertEqual(litResults[0].filePath, "literature.txt",
                       "Literature doc should rank #1 for Shakespeare query")

        // Query about market economics — economics should be #1
        let econEmb = try await embed("market prices set by supply and demand")
        let econResults = try await db.search(embedding: econEmb, limit: 12)
        XCTAssertEqual(econResults[0].filePath, "economics.txt",
                       "Economics doc should rank #1 for market prices query")

        // Query about ocean weather — oceanography should be #1
        let oceanEmb = try await embed("ocean currents affecting global weather and climate")
        let oceanResults = try await db.search(embedding: oceanEmb, limit: 12)
        XCTAssertEqual(oceanResults[0].filePath, "oceanography.txt",
                       "Oceanography doc should rank #1 for ocean weather query")

        // Query about therapy — psychology should be #1
        let psychEmb = try await embed("cognitive therapy for changing negative thoughts")
        let psychResults = try await db.search(embedding: psychEmb, limit: 12)
        XCTAssertEqual(psychResults[0].filePath, "psychology.txt",
                       "Psychology doc should rank #1 for therapy query")

        // Query about earthquakes — geography should be #1
        let geoEmb = try await embed("earthquakes and volcanic eruptions from tectonic plates")
        let geoResults = try await db.search(embedding: geoEmb, limit: 12)
        XCTAssertEqual(geoResults[0].filePath, "geography.txt",
                       "Geography doc should rank #1 for earthquake query")
    }

    // MARK: - 21. Search accuracy — same query returns consistent ranking

    func testSearchReturnsDeterministicRanking() async throws {
        let db = try await makeInitializedDB()

        let docs: [(path: String, content: String)] = [
            ("space.txt", "Astronauts travel to the International Space Station orbiting Earth to conduct experiments"),
            ("ocean.txt", "Deep sea divers explore coral reefs and underwater caves in tropical oceans"),
            ("desert.txt", "The Sahara desert stretches across North Africa with vast sand dunes and extreme heat"),
        ]

        for doc in docs {
            let emb = try await embed(doc.content)
            try await db.insert(
                filePath: doc.path,
                lineStart: nil,
                lineEnd: nil,
                chunkType: .whole,
                pageNumber: nil,
                fileModifiedAt: Date(),
                contentPreview: doc.content,
                embedding: emb
            )
        }

        let queryEmb = try await embed("exploring underwater coral reefs")

        // Run the same search 5 times and verify identical ordering
        var firstOrder: [String]?
        for i in 0..<5 {
            let results = try await db.search(embedding: queryEmb, limit: 3)
            let order = results.map(\.filePath)
            if let expected = firstOrder {
                XCTAssertEqual(order, expected,
                               "Search run \(i + 1) should return the same ranking as the first run")
            } else {
                firstOrder = order
                XCTAssertEqual(order[0], "ocean.txt",
                               "Ocean doc should rank #1 for coral reef query")
            }
        }
    }

    // MARK: - 22. open() on corrupted DB (missing chunks table) throws databaseCorrupted

    func testOpenOnCorruptedDBThrowsDatabaseCorrupted() async throws {
        // Initialize a valid database
        do {
            let db = VectorDatabase(databaseDirectory: dbDir, sourceDirectory: sourceDir)
            try await db.initialize()
        }

        // Corrupt it by dropping the chunks table via raw SQL
        let dbPath = dbDir.appendingPathComponent("index.db").path
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
        let db = VectorDatabase(databaseDirectory: dbDir, sourceDirectory: sourceDir)
        do {
            try await db.open()
            XCTFail("Expected VecError.databaseCorrupted")
        } catch let error as VecError {
            if case .databaseCorrupted(let detail) = error {
                XCTAssertTrue(detail.contains("chunks"),
                              "Error should mention missing 'chunks' table, got: \(detail)")
            } else {
                XCTFail("Expected .databaseCorrupted, got \(error)")
            }
        }
    }

}
