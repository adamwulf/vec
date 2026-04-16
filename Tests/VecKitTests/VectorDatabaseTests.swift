import XCTest
import CSQLiteVec
@testable import VecKit

final class VectorDatabaseTests: XCTestCase {

    private var tempDir: URL!
    private var dbDir: URL!
    private var sourceDir: URL!
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
        dbDir = tempDir.appendingPathComponent("db")
        sourceDir = tempDir.appendingPathComponent("source")
        try! FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
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

    /// Create an initialized VectorDatabase using dbDir and sourceDir.
    private func makeInitializedDB() throws -> VectorDatabase {
        let db = VectorDatabase(databaseDirectory: dbDir, sourceDirectory: sourceDir)
        try db.initialize()
        return db
    }

    // MARK: - 1. initialize() creates database dir and index.db

    func testInitializeCreatesDatabaseDirAndDatabase() throws {
        let db = VectorDatabase(databaseDirectory: dbDir, sourceDirectory: sourceDir)
        try db.initialize()

        let dbFile = dbDir.appendingPathComponent("index.db")

        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbDir.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue, "databaseDirectory should be a directory")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbFile.path), "index.db should exist")
    }

    // MARK: - 2. open() on non-existent DB throws databaseNotInitialized

    func testOpenOnNonExistentDBThrowsDatabaseNotInitialized() {
        let db = VectorDatabase(databaseDirectory: dbDir, sourceDirectory: sourceDir)

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
            let db = VectorDatabase(databaseDirectory: dbDir, sourceDirectory: sourceDir)
            try db.initialize()
        }

        // Now open with a fresh instance
        let db = VectorDatabase(databaseDirectory: dbDir, sourceDirectory: sourceDir)
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

    // MARK: - 16. totalChunkCount() returns correct totals

    func testTotalChunkCountOnEmptyDB() throws {
        let db = try makeInitializedDB()
        let count = try db.totalChunkCount()
        XCTAssertEqual(count, 0)
    }

    func testTotalChunkCountWithMultipleFilesAndChunks() throws {
        let db = try makeInitializedDB()

        let emb1 = try embed("First chunk of the readme file")
        let emb2 = try embed("Second chunk of the readme file")
        let emb3 = try embed("Main swift source file content")

        // Two chunks for one file
        try db.insert(
            filePath: "README.md",
            lineStart: 1,
            lineEnd: 50,
            chunkType: .chunk,
            pageNumber: nil,
            fileModifiedAt: Date(),
            contentPreview: "First chunk",
            embedding: emb1
        )

        try db.insert(
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
        try db.insert(
            filePath: "main.swift",
            lineStart: nil,
            lineEnd: nil,
            chunkType: .whole,
            pageNumber: nil,
            fileModifiedAt: Date(),
            contentPreview: "Main swift file",
            embedding: emb3
        )

        let count = try db.totalChunkCount()
        XCTAssertEqual(count, 3)
    }

    // MARK: - 17. Search accuracy — full ranking order across diverse topics

    func testSearchFullRankingOrderDiverseTopics() throws {
        let db = try makeInitializedDB()

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
            let emb = try embed(doc.content)
            try db.insert(
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
        let bakingEmb = try embed("baking a chocolate dessert in the kitchen")
        let bakingResults = try db.search(embedding: bakingEmb, limit: 8)
        XCTAssertEqual(bakingResults[0].filePath, "cooking.txt",
                       "Cooking doc should rank #1 for a baking query")

        // Query: outer space — expect astronomy #1
        let spaceEmb = try embed("stars and galaxies in outer space")
        let spaceResults = try db.search(embedding: spaceEmb, limit: 8)
        XCTAssertEqual(spaceResults[0].filePath, "astronomy.txt",
                       "Astronomy doc should rank #1 for a space query")

        // Query: iOS development — expect programming #1
        let devEmb = try embed("building apps for iOS with Swift")
        let devResults = try db.search(embedding: devEmb, limit: 8)
        XCTAssertEqual(devResults[0].filePath, "programming.txt",
                       "Programming doc should rank #1 for an iOS dev query")

        // Query: basketball — expect sports #1
        let sportsEmb = try embed("shooting hoops in a basketball game")
        let sportsResults = try db.search(embedding: sportsEmb, limit: 8)
        XCTAssertEqual(sportsResults[0].filePath, "sports.txt",
                       "Sports doc should rank #1 for a basketball query")

        // Query: jazz — expect music #1
        let jazzEmb = try embed("jazz piano and guitar melodies")
        let jazzResults = try db.search(embedding: jazzEmb, limit: 8)
        XCTAssertEqual(jazzResults[0].filePath, "music.txt",
                       "Music doc should rank #1 for a jazz query")

        // Query: treating infections — expect medicine #1
        let medEmb = try embed("treating bacterial infections with medicine")
        let medResults = try db.search(embedding: medEmb, limit: 8)
        XCTAssertEqual(medResults[0].filePath, "medicine.txt",
                       "Medicine doc should rank #1 for an infections query")

        // Query: Roman Empire — expect history #1
        let histEmb = try embed("the ancient Roman Empire and its soldiers")
        let histResults = try db.search(embedding: histEmb, limit: 8)
        XCTAssertEqual(histResults[0].filePath, "history.txt",
                       "History doc should rank #1 for a Roman Empire query")

        // Query: growing vegetables — expect gardening #1
        let gardenEmb = try embed("growing vegetables in the garden with sunlight")
        let gardenResults = try db.search(embedding: gardenEmb, limit: 8)
        XCTAssertEqual(gardenResults[0].filePath, "gardening.txt",
                       "Gardening doc should rank #1 for a vegetables query")
    }

    // MARK: - 18. Search accuracy — ranking across related professional domains

    func testSearchRankingAcrossRelatedProfessionalDomains() throws {
        let db = try makeInitializedDB()

        // Four professional domains that share a "technical" flavor but are distinct
        let docs: [(path: String, content: String)] = [
            ("veterinary.txt", "Veterinarians treat sick dogs and cats at animal hospitals by prescribing medicine and performing surgery"),
            ("dentistry.txt", "Dentists fill cavities, perform root canals, and clean teeth to maintain oral health and prevent gum disease"),
            ("aviation.txt", "Pilots navigate airplanes through turbulence and communicate with air traffic control towers during flights"),
            ("cooking.txt", "Baking sourdough bread requires flour, water, salt, and a natural yeast starter culture"),
        ]

        for doc in docs {
            let emb = try embed(doc.content)
            try db.insert(
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
        let petEmb = try embed("treating sick pets at the animal clinic")
        let petResults = try db.search(embedding: petEmb, limit: 4)
        XCTAssertEqual(petResults[0].filePath, "veterinary.txt",
                       "Veterinary doc should rank #1 for a pet health query")

        // Query about teeth — dentistry should rank #1
        let teethEmb = try embed("filling cavities and cleaning teeth at the dental office")
        let teethResults = try db.search(embedding: teethEmb, limit: 4)
        XCTAssertEqual(teethResults[0].filePath, "dentistry.txt",
                       "Dentistry doc should rank #1 for a teeth query")

        // Query about flying — aviation should rank #1
        let flyEmb = try embed("flying airplanes and communicating with control towers")
        let flyResults = try db.search(embedding: flyEmb, limit: 4)
        XCTAssertEqual(flyResults[0].filePath, "aviation.txt",
                       "Aviation doc should rank #1 for a flying query")

        // Query about baking — cooking should rank #1
        let bakeEmb = try embed("making bread with flour and yeast")
        let bakeResults = try db.search(embedding: bakeEmb, limit: 4)
        XCTAssertEqual(bakeResults[0].filePath, "cooking.txt",
                       "Cooking doc should rank #1 for a baking query")
    }

    // MARK: - 19. Search accuracy — verify complete ranking order, not just top-1

    func testSearchVerifiesCompleteRankingOrder() throws {
        let db = try makeInitializedDB()

        // Documents with graduated relevance to "Italian pasta"
        // italian: directly about pasta → cooking: general kitchen/food → nutrition: food-adjacent → astronomy: unrelated
        let docs: [(path: String, content: String)] = [
            ("italian.txt", "Italian pasta recipes include spaghetti carbonara made with eggs, cheese, and pancetta in a creamy sauce"),
            ("cooking.txt", "Home cooking involves preparing meals in the kitchen using fresh ingredients, pots, and pans on the stove"),
            ("nutrition.txt", "A balanced diet includes proteins, carbohydrates, vitamins, and minerals for maintaining good health"),
            ("astronomy.txt", "Telescopes observe distant galaxies, nebulae, and black holes billions of light years from Earth"),
        ]

        for doc in docs {
            let emb = try embed(doc.content)
            try db.insert(
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

        let queryEmb = try embed("making Italian pasta with eggs and cheese")
        let results = try db.search(embedding: queryEmb, limit: 4)

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

    func testSearchAccuracyWithLargerCorpus() throws {
        let db = try makeInitializedDB()

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
            let emb = try embed(doc.content)
            try db.insert(
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
        let chemEmb = try embed("atoms bonding in chemical reactions with electrons")
        let chemResults = try db.search(embedding: chemEmb, limit: 12)
        XCTAssertEqual(chemResults[0].filePath, "chemistry.txt",
                       "Chemistry doc should rank #1 for atomic bonding query")

        // Query about Shakespeare — literature should be #1
        let litEmb = try embed("Shakespeare plays about love and tragedy")
        let litResults = try db.search(embedding: litEmb, limit: 12)
        XCTAssertEqual(litResults[0].filePath, "literature.txt",
                       "Literature doc should rank #1 for Shakespeare query")

        // Query about market economics — economics should be #1
        let econEmb = try embed("market prices set by supply and demand")
        let econResults = try db.search(embedding: econEmb, limit: 12)
        XCTAssertEqual(econResults[0].filePath, "economics.txt",
                       "Economics doc should rank #1 for market prices query")

        // Query about ocean weather — oceanography should be #1
        let oceanEmb = try embed("ocean currents affecting global weather and climate")
        let oceanResults = try db.search(embedding: oceanEmb, limit: 12)
        XCTAssertEqual(oceanResults[0].filePath, "oceanography.txt",
                       "Oceanography doc should rank #1 for ocean weather query")

        // Query about therapy — psychology should be #1
        let psychEmb = try embed("cognitive therapy for changing negative thoughts")
        let psychResults = try db.search(embedding: psychEmb, limit: 12)
        XCTAssertEqual(psychResults[0].filePath, "psychology.txt",
                       "Psychology doc should rank #1 for therapy query")

        // Query about earthquakes — geography should be #1
        let geoEmb = try embed("earthquakes and volcanic eruptions from tectonic plates")
        let geoResults = try db.search(embedding: geoEmb, limit: 12)
        XCTAssertEqual(geoResults[0].filePath, "geography.txt",
                       "Geography doc should rank #1 for earthquake query")
    }

    // MARK: - 21. Search accuracy — same query returns consistent ranking

    func testSearchReturnsDeterministicRanking() throws {
        let db = try makeInitializedDB()

        let docs: [(path: String, content: String)] = [
            ("space.txt", "Astronauts travel to the International Space Station orbiting Earth to conduct experiments"),
            ("ocean.txt", "Deep sea divers explore coral reefs and underwater caves in tropical oceans"),
            ("desert.txt", "The Sahara desert stretches across North Africa with vast sand dunes and extreme heat"),
        ]

        for doc in docs {
            let emb = try embed(doc.content)
            try db.insert(
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

        let queryEmb = try embed("exploring underwater coral reefs")

        // Run the same search 5 times and verify identical ordering
        var firstOrder: [String]?
        for i in 0..<5 {
            let results = try db.search(embedding: queryEmb, limit: 3)
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

    func testOpenOnCorruptedDBThrowsDatabaseCorrupted() throws {
        // Initialize a valid database
        do {
            let db = VectorDatabase(databaseDirectory: dbDir, sourceDirectory: sourceDir)
            try db.initialize()
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
