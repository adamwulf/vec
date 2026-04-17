import XCTest
@testable import VecKit

final class IntegrationTests: XCTestCase {

    private var tempDir: URL!
    private var dbDir: URL!
    private var sourceDir: URL!
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
        // sourceDir is where files are created; dbDir is separate database storage
        sourceDir = tempDir.appendingPathComponent("source")
        try! FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        dbDir = tempDir.appendingPathComponent("db")
        embeddingService = EmbeddingService()
    }

    override func tearDown() {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    // MARK: - Helpers

    /// Embed a query string using the real EmbeddingService. Fails
    /// the test if embedding returns an empty vector.
    private func embed(_ text: String, file: StaticString = #file, line: UInt = #line) async throws -> [Float] {
        let vector = try await embeddingService.embedQuery(text)
        XCTAssertFalse(vector.isEmpty, "EmbeddingService returned empty vector for: \(text)", file: file, line: line)
        return vector
    }

    /// Create a text file in the source directory and return its URL.
    @discardableResult
    private func createFile(at relativePath: String, content: String) -> URL {
        let url = sourceDir.appendingPathComponent(relativePath)
        let parent = url.deletingLastPathComponent()
        try! FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try! content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Create an initialized VectorDatabase using dbDir and sourceDir.
    private func makeInitializedDB() async throws -> VectorDatabase {
        let db = VectorDatabase(databaseDirectory: dbDir, sourceDirectory: sourceDir)
        try await db.initialize()
        return db
    }

    /// Index a single file: extract chunks, embed, insert into the database,
    /// and mark as fully indexed. Replicates the core indexing logic from
    /// UpdateIndexCommand.
    private func indexFile(_ file: FileInfo, into db: VectorDatabase, extractor: TextExtractor) async throws {
        let chunks = try extractor.extract(from: file).chunks
        for chunk in chunks {
            let embedding = try await embeddingService.embedDocument(chunk.text)
            guard !embedding.isEmpty else { continue }
            try await db.insert(
                filePath: file.relativePath,
                lineStart: chunk.lineStart,
                lineEnd: chunk.lineEnd,
                chunkType: chunk.type,
                pageNumber: chunk.pageNumber,
                fileModifiedAt: file.modificationDate,
                contentPreview: String(chunk.text.prefix(200)),
                embedding: embedding
            )
        }
        try await db.markFileIndexed(path: file.relativePath, modifiedAt: file.modificationDate)
    }

    // MARK: - 1. Scan + Extract + Embed + Store + Search

    func testFullPipelineScanExtractEmbedStoreSearch() async throws {
        // Create files with distinct content
        createFile(at: "cooking.txt", content: "This recipe explains how to bake a chocolate cake with cocoa powder and sugar")
        createFile(at: "programming.swift", content: "func quickSort(_ array: [Int]) -> [Int] { return array.sorted() }")
        createFile(at: "astronomy.md", content: "The Milky Way galaxy contains billions of stars and planets orbiting them")

        // Scan
        let scanner = FileScanner(directory: sourceDir)
        let files = try scanner.scan()
        XCTAssertEqual(files.count, 3, "Should find all 3 files")

        // Extract + Embed + Store
        let db = try await makeInitializedDB()
        let extractor = TextExtractor()

        for file in files {
            try await indexFile(file, into: db, extractor: extractor)
        }

        // Search for cooking-related content
        let cookingQuery = try await embed("baking a cake with chocolate")
        let cookingResults = try await db.search(embedding: cookingQuery, limit: 3)
        XCTAssertEqual(cookingResults.count, 3)
        XCTAssertEqual(cookingResults[0].filePath, "cooking.txt",
                       "Cooking file should be the top result for a baking query")

        // Search for programming-related content
        let programmingQuery = try await embed("sorting algorithm implementation")
        let programmingResults = try await db.search(embedding: programmingQuery, limit: 3)
        XCTAssertEqual(programmingResults.count, 3)
        XCTAssertEqual(programmingResults[0].filePath, "programming.swift",
                       "Programming file should be the top result for an algorithm query")

        // Search for astronomy-related content
        let astronomyQuery = try await embed("stars and galaxies in space")
        let astronomyResults = try await db.search(embedding: astronomyQuery, limit: 3)
        XCTAssertEqual(astronomyResults.count, 3)
        XCTAssertEqual(astronomyResults[0].filePath, "astronomy.md",
                       "Astronomy file should be the top result for a space query")
    }

    // MARK: - 2. Update flow — modified file

    func testUpdateFlowModifiedFile() async throws {
        // Create initial file
        createFile(at: "notes.txt", content: "The ocean is vast and full of marine creatures like dolphins and whales")

        let scanner = FileScanner(directory: sourceDir)
        let db = try await makeInitializedDB()
        let extractor = TextExtractor()

        // Initial indexing
        let initialFiles = try scanner.scan()
        XCTAssertEqual(initialFiles.count, 1)
        for file in initialFiles {
            try await indexFile(file, into: db, extractor: extractor)
        }

        // Verify initial content is searchable
        let oceanQuery = try await embed("marine life in the sea")
        let initialResults = try await db.search(embedding: oceanQuery, limit: 1)
        XCTAssertEqual(initialResults.count, 1)
        XCTAssertEqual(initialResults[0].filePath, "notes.txt")

        // Modify the file with completely different content
        // Sleep briefly to ensure the mtime changes
        try await Task.sleep(nanoseconds: 1_000_000_000)
        createFile(at: "notes.txt", content: "Quantum computing uses qubits and superposition to solve complex problems")

        // Simulate update-index logic: compare allIndexedFiles dates, re-index stale entries
        let updatedFiles = try scanner.scan()
        let indexedFiles = try await db.allIndexedFiles()

        for file in updatedFiles {
            if let existingModDate = indexedFiles[file.relativePath] {
                if file.modificationDate > existingModDate {
                    try await db.removeEntries(forPath: file.relativePath)
                    try await indexFile(file, into: db, extractor: extractor)
                }
            }
        }

        // Search for new content — should find it
        let quantumQuery = try await embed("quantum computing qubits")
        let newResults = try await db.search(embedding: quantumQuery, limit: 1)
        XCTAssertEqual(newResults.count, 1)
        XCTAssertEqual(newResults[0].filePath, "notes.txt")
        XCTAssertTrue(newResults[0].contentPreview?.contains("Quantum") == true,
                      "Content preview should reflect the updated file")

        // Search for old content — should still return notes.txt but with updated content
        let oldContentResults = try await db.search(embedding: oceanQuery, limit: 1)
        XCTAssertEqual(oldContentResults.count, 1)
        XCTAssertFalse(oldContentResults[0].contentPreview?.contains("ocean") == true,
                       "Old content should no longer appear in previews")
    }

    // MARK: - 3. Update flow — deleted file

    func testUpdateFlowDeletedFile() async throws {
        // Create two files
        createFile(at: "keep.txt", content: "Mathematics involves numbers equations and proofs for theorems")
        createFile(at: "delete_me.txt", content: "Gardening tips for growing tomatoes peppers and herbs in the backyard")

        let scanner = FileScanner(directory: sourceDir)
        let db = try await makeInitializedDB()
        let extractor = TextExtractor()

        // Index both files
        let files = try scanner.scan()
        XCTAssertEqual(files.count, 2)
        for file in files {
            try await indexFile(file, into: db, extractor: extractor)
        }

        // Verify both are searchable
        let indexedBefore = try await db.allIndexedFiles()
        XCTAssertEqual(indexedBefore.count, 2)

        // Delete one file from disk
        let deleteURL = sourceDir.appendingPathComponent("delete_me.txt")
        try FileManager.default.removeItem(at: deleteURL)

        // Simulate update-index: find paths in DB not on disk, remove them
        let currentFiles = try scanner.scan()
        let currentPaths = Set(currentFiles.map(\.relativePath))
        let indexedFiles = try await db.allIndexedFiles()

        for indexedPath in indexedFiles.keys {
            if !currentPaths.contains(indexedPath) {
                try await db.removeEntries(forPath: indexedPath)
            }
        }

        // Verify the deleted file's entries are gone
        let indexedAfter = try await db.allIndexedFiles()
        XCTAssertEqual(indexedAfter.count, 1)
        XCTAssertNotNil(indexedAfter["keep.txt"])
        XCTAssertNil(indexedAfter["delete_me.txt"])

        // Search for gardening content — should only return keep.txt
        let gardenQuery = try await embed("growing vegetables in a garden")
        let results = try await db.search(embedding: gardenQuery, limit: 5)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].filePath, "keep.txt")

        // Search for math content — should find keep.txt
        let mathQuery = try await embed("mathematical equations and proofs")
        let mathResults = try await db.search(embedding: mathQuery, limit: 5)
        XCTAssertEqual(mathResults.count, 1)
        XCTAssertEqual(mathResults[0].filePath, "keep.txt")
    }

    // MARK: - 4. Update flow — new file added

    func testUpdateFlowNewFileAdded() async throws {
        // Start with one file
        createFile(at: "original.txt", content: "The history of ancient Rome includes senators gladiators and emperors")

        let scanner = FileScanner(directory: sourceDir)
        let db = try await makeInitializedDB()
        let extractor = TextExtractor()

        // Index the original file
        let initialFiles = try scanner.scan()
        XCTAssertEqual(initialFiles.count, 1)
        for file in initialFiles {
            try await indexFile(file, into: db, extractor: extractor)
        }

        let indexedBefore = try await db.allIndexedFiles()
        XCTAssertEqual(indexedBefore.count, 1)

        // Add a new file
        createFile(at: "added.txt", content: "Machine learning neural networks train on large datasets to recognize patterns")

        // Simulate update-index: find files on disk not in DB, index them
        let currentFiles = try scanner.scan()
        XCTAssertEqual(currentFiles.count, 2)
        let indexedFiles = try await db.allIndexedFiles()

        for file in currentFiles {
            if indexedFiles[file.relativePath] == nil {
                try await indexFile(file, into: db, extractor: extractor)
            }
        }

        // Verify both files are now indexed
        let indexedAfter = try await db.allIndexedFiles()
        XCTAssertEqual(indexedAfter.count, 2)
        XCTAssertNotNil(indexedAfter["original.txt"])
        XCTAssertNotNil(indexedAfter["added.txt"])

        // Search for machine learning content — new file should rank first
        let mlQuery = try await embed("deep learning and neural network training")
        let mlResults = try await db.search(embedding: mlQuery, limit: 2)
        XCTAssertEqual(mlResults.count, 2)
        XCTAssertEqual(mlResults[0].filePath, "added.txt",
                       "The newly added ML file should be the top result for an ML query")

        // Search for history content — original file should rank first
        let historyQuery = try await embed("ancient Roman history and empire")
        let historyResults = try await db.search(embedding: historyQuery, limit: 2)
        XCTAssertEqual(historyResults.count, 2)
        XCTAssertEqual(historyResults[0].filePath, "original.txt",
                       "The original history file should be the top result for a history query")
    }

    // MARK: - 5. Insert then search (single file via fileInfo)

    func testInsertThenSearchUsingSingleFileInfo() async throws {
        // Create a file and use FileScanner.fileInfo() to get its info
        let fileURL = createFile(at: "physics.swift", content: "func calculateGravity(mass: Double, distance: Double) -> Double { return mass / (distance * distance) }")

        let fileInfo = try FileScanner.fileInfo(for: fileURL, relativeTo: sourceDir)
        XCTAssertEqual(fileInfo.relativePath, "physics.swift")
        XCTAssertEqual(fileInfo.fileExtension, "swift")

        // Extract, embed, and insert
        let db = try await makeInitializedDB()
        let extractor = TextExtractor()
        try await indexFile(fileInfo, into: db, extractor: extractor)

        // Verify the file is indexed
        let indexedFiles = try await db.allIndexedFiles()
        XCTAssertEqual(indexedFiles.count, 1)
        XCTAssertNotNil(indexedFiles["physics.swift"])

        // Search for physics-related content
        let query = try await embed("gravitational force calculation")
        let results = try await db.search(embedding: query, limit: 5)
        XCTAssertGreaterThan(results.count, 0)
        XCTAssertEqual(results[0].filePath, "physics.swift")
    }

    // MARK: - 6. Remove then search

    func testRemoveThenSearchVerifiesContentGone() async throws {
        // Create and index multiple files
        createFile(at: "music.txt", content: "Playing guitar chords and piano melodies creates beautiful harmonies")
        createFile(at: "sports.txt", content: "Basketball players dribble and shoot hoops on the court during the game")
        createFile(at: "science.txt", content: "Chemical reactions involve molecules bonding and breaking apart in solutions")

        let scanner = FileScanner(directory: sourceDir)
        let db = try await makeInitializedDB()
        let extractor = TextExtractor()

        let files = try scanner.scan()
        XCTAssertEqual(files.count, 3)
        for file in files {
            try await indexFile(file, into: db, extractor: extractor)
        }

        // Verify all three are searchable
        let allFiles = try await db.allIndexedFiles()
        XCTAssertEqual(allFiles.count, 3)

        // Remove music.txt entries
        let removed = try await db.removeEntries(forPath: "music.txt")
        XCTAssertGreaterThan(removed, 0)

        // Verify music.txt is gone from the index
        let remainingFiles = try await db.allIndexedFiles()
        XCTAssertEqual(remainingFiles.count, 2)
        XCTAssertNil(remainingFiles["music.txt"])
        XCTAssertNotNil(remainingFiles["sports.txt"])
        XCTAssertNotNil(remainingFiles["science.txt"])

        // Search for music content — should NOT return music.txt
        let musicQuery = try await embed("guitar and piano music")
        let musicResults = try await db.search(embedding: musicQuery, limit: 5)
        for result in musicResults {
            XCTAssertNotEqual(result.filePath, "music.txt",
                             "Removed file should not appear in search results")
        }

        // The remaining files should still be searchable
        let sportsQuery = try await embed("basketball game on the court")
        let sportsResults = try await db.search(embedding: sportsQuery, limit: 2)
        XCTAssertEqual(sportsResults.count, 2)
        XCTAssertEqual(sportsResults[0].filePath, "sports.txt",
                       "Sports file should still be the top result for a sports query")
    }
}
