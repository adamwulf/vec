import Foundation
import CSQLiteVec
import Accelerate

/// A record to insert into the chunks table, used by batch operations.
public struct ChunkRecord: Sendable {
    public let filePath: String
    public let lineStart: Int?
    public let lineEnd: Int?
    public let chunkType: ChunkType
    public let pageNumber: Int?
    public let fileModifiedAt: Date
    public let contentPreview: String
    public let embedding: [Float]

    public init(
        filePath: String,
        lineStart: Int?,
        lineEnd: Int?,
        chunkType: ChunkType,
        pageNumber: Int?,
        fileModifiedAt: Date,
        contentPreview: String,
        embedding: [Float]
    ) {
        self.filePath = filePath
        self.lineStart = lineStart
        self.lineEnd = lineEnd
        self.chunkType = chunkType
        self.pageNumber = pageNumber
        self.fileModifiedAt = fileModifiedAt
        self.contentPreview = contentPreview
        self.embedding = embedding
    }
}

/// Wraps SQLite for storing and querying vector embeddings using pure-Swift
/// cosine-distance search. No external dynamic library required.
public actor VectorDatabase {

    /// The directory containing the database files (e.g. `~/.vec/<db-name>/`).
    public let databaseDirectory: URL

    /// The source directory being indexed.
    public let sourceDirectory: URL

    private let dbPath: String
    private var db: OpaquePointer?

    /// The dimension of vectors stored in this database.
    public let dimension: Int

    /// Primary initializer for centralized storage.
    ///
    /// - Parameters:
    ///   - databaseDirectory: The directory containing `index.db` (e.g. `~/.vec/<db-name>/`).
    ///   - sourceDirectory: The directory being indexed.
    ///   - dimension: The embedding vector dimension (default 768).
    public init(databaseDirectory: URL, sourceDirectory: URL, dimension: Int = 768) {
        self.databaseDirectory = databaseDirectory
        self.sourceDirectory = sourceDirectory
        self.dbPath = databaseDirectory
            .appendingPathComponent("index.db")
            .path
        self.dimension = dimension
    }

    // MARK: - Lifecycle

    /// Initialize a new database, creating the database directory and schema.
    public func initialize() throws {
        try FileManager.default.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)

        try openDatabase()
        try createSchema()
    }

    /// Open an existing database.
    public func open() throws {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw VecError.databaseNotInitialized
        }
        try openDatabase()
        try verifySchema()
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    // MARK: - Insert

    /// Insert a single chunk embedding into the database.
    @discardableResult
    public func insert(
        filePath: String,
        lineStart: Int?,
        lineEnd: Int?,
        chunkType: ChunkType,
        pageNumber: Int?,
        fileModifiedAt: Date,
        contentPreview: String,
        embedding: [Float]
    ) throws -> Int64 {
        try _insert(
            filePath: filePath,
            lineStart: lineStart,
            lineEnd: lineEnd,
            chunkType: chunkType,
            pageNumber: pageNumber,
            fileModifiedAt: fileModifiedAt,
            contentPreview: contentPreview,
            embedding: embedding
        )
    }

    /// Insert multiple chunk records in a single transaction.
    /// One actor hop, one fsync — 10-100x faster than individual inserts for bulk writes.
    public func insertBatch(_ records: [ChunkRecord]) throws {
        guard !records.isEmpty else { return }

        try _execute("BEGIN TRANSACTION")
        do {
            for record in records {
                try _insert(
                    filePath: record.filePath,
                    lineStart: record.lineStart,
                    lineEnd: record.lineEnd,
                    chunkType: record.chunkType,
                    pageNumber: record.pageNumber,
                    fileModifiedAt: record.fileModifiedAt,
                    contentPreview: record.contentPreview,
                    embedding: record.embedding
                )
            }
            try _execute("COMMIT")
        } catch {
            try? _execute("ROLLBACK")
            throw error
        }
    }

    /// Atomically replace all entries for a file path: delete existing entries then
    /// insert new records, all within a single transaction.
    public func replaceEntries(forPath path: String, with records: [ChunkRecord]) throws {
        try _execute("BEGIN TRANSACTION")
        do {
            try _removeEntries(forPath: path)
            for record in records {
                try _insert(
                    filePath: record.filePath,
                    lineStart: record.lineStart,
                    lineEnd: record.lineEnd,
                    chunkType: record.chunkType,
                    pageNumber: record.pageNumber,
                    fileModifiedAt: record.fileModifiedAt,
                    contentPreview: record.contentPreview,
                    embedding: record.embedding
                )
            }
            try _execute("COMMIT")
        } catch {
            try? _execute("ROLLBACK")
            throw error
        }
    }

    // MARK: - Query

    /// Search for similar embeddings.
    public func search(embedding: [Float], limit: Int) throws -> [SearchResult] {
        // Load all embeddings and compute cosine distance in Swift.
        let sql = """
            SELECT id, file_path, line_start, line_end, chunk_type, page_number, content_preview, embedding
            FROM chunks
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqlError("Failed to prepare search statement")
        }
        defer { sqlite3_finalize(stmt) }

        struct Candidate {
            let id: Int64
            let filePath: String
            let lineStart: Int?
            let lineEnd: Int?
            let chunkType: ChunkType
            let pageNumber: Int?
            let contentPreview: String?
            let distance: Double
        }

        var candidates: [Candidate] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let filePath = String(cString: sqlite3_column_text(stmt, 1))
            let lineStart = sqlite3_column_type(stmt, 2) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 2)) : nil
            let lineEnd = sqlite3_column_type(stmt, 3) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 3)) : nil
            let chunkTypeRaw = String(cString: sqlite3_column_text(stmt, 4))
            let pageNumber = sqlite3_column_type(stmt, 5) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 5)) : nil
            let contentPreview = sqlite3_column_type(stmt, 6) != SQLITE_NULL
                ? String(cString: sqlite3_column_text(stmt, 6))
                : nil

            // Read embedding blob
            guard let blobPtr = sqlite3_column_blob(stmt, 7) else { continue }
            let blobSize = Int(sqlite3_column_bytes(stmt, 7))
            let floatCount = blobSize / MemoryLayout<Float>.size
            let storedEmbedding = Array(UnsafeBufferPointer(
                start: blobPtr.assumingMemoryBound(to: Float.self),
                count: floatCount
            ))

            let distance = cosineDistance(embedding, storedEmbedding)

            candidates.append(Candidate(
                id: id,
                filePath: filePath,
                lineStart: lineStart,
                lineEnd: lineEnd,
                chunkType: ChunkType(rawValue: chunkTypeRaw) ?? .whole,
                pageNumber: pageNumber,
                contentPreview: contentPreview,
                distance: distance
            ))
        }

        // Sort by distance ascending (lower = more similar) and take top `limit`
        candidates.sort { $0.distance < $1.distance }
        let topCandidates = candidates.prefix(limit)

        return topCandidates.map { c in
            SearchResult(
                filePath: c.filePath,
                lineStart: c.lineStart,
                lineEnd: c.lineEnd,
                chunkType: c.chunkType,
                pageNumber: c.pageNumber,
                contentPreview: c.contentPreview,
                distance: c.distance,
                chunkId: c.id
            )
        }
    }

    // MARK: - Index Management

    /// Get all fully-indexed file paths and their modification dates.
    ///
    /// Only files with a completion record in `indexed_files` are returned.
    /// Files whose indexing was interrupted (partial chunks but no completion
    /// record) are excluded so they will be re-indexed on the next run.
    public func allIndexedFiles() throws -> [String: Date] {
        let sql = "SELECT file_path, file_modified_at FROM indexed_files"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqlError("Failed to query indexed files")
        }
        defer { sqlite3_finalize(stmt) }

        var files: [String: Date] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let path = String(cString: sqlite3_column_text(stmt, 0))
            let timestamp = sqlite3_column_double(stmt, 1)
            files[path] = Date(timeIntervalSince1970: timestamp)
        }

        return files
    }

    /// Metadata for an indexed file, as returned by `indexedFileMetadata`.
    public struct IndexedFileMetadata: Sendable {
        public let modifiedAt: Date
        /// Lines for text files, pages for PDFs, nil for images / unknown.
        public let linePageCount: Int?
    }

    /// Fetch modified-date and line/page-count metadata for the given file
    /// paths. Paths absent from the database simply don't appear in the result.
    public func indexedFileMetadata(paths: [String]) throws -> [String: IndexedFileMetadata] {
        guard !paths.isEmpty else { return [:] }

        let placeholders = Array(repeating: "?", count: paths.count).joined(separator: ",")
        let sql = "SELECT file_path, file_modified_at, line_page_count FROM indexed_files WHERE file_path IN (\(placeholders))"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqlError("Failed to query indexed-file metadata")
        }
        defer { sqlite3_finalize(stmt) }

        for (i, path) in paths.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), path, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }

        var result: [String: IndexedFileMetadata] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let path = String(cString: sqlite3_column_text(stmt, 0))
            let timestamp = sqlite3_column_double(stmt, 1)
            let count: Int? = sqlite3_column_type(stmt, 2) == SQLITE_NULL
                ? nil
                : Int(sqlite3_column_int64(stmt, 2))
            result[path] = IndexedFileMetadata(
                modifiedAt: Date(timeIntervalSince1970: timestamp),
                linePageCount: count
            )
        }

        return result
    }

    /// Mark a file as fully indexed by inserting a completion record.
    ///
    /// This should only be called after all chunks for the file have been
    /// successfully written. The record is used by `allIndexedFiles()` to
    /// determine whether a file needs re-indexing. `linePageCount` stores
    /// lines (text), pages (PDF), or nil (images / unknown).
    public func markFileIndexed(path: String, modifiedAt: Date, linePageCount: Int? = nil) throws {
        let sql = """
            INSERT OR REPLACE INTO indexed_files (file_path, file_modified_at, line_page_count)
            VALUES (?, ?, ?)
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqlError("Failed to prepare mark-indexed statement")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, path, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_double(stmt, 2, modifiedAt.timeIntervalSince1970)
        if let linePageCount {
            sqlite3_bind_int64(stmt, 3, Int64(linePageCount))
        } else {
            sqlite3_bind_null(stmt, 3)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw sqlError("Failed to mark file as indexed")
        }
    }

    /// Remove the completion record for a file path.
    ///
    /// Call this before re-indexing a file so that if the process is
    /// interrupted, the file will be re-indexed on the next run.
    public func unmarkFileIndexed(path: String) throws {
        let sql = "DELETE FROM indexed_files WHERE file_path = ?"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqlError("Failed to prepare unmark-indexed statement")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, path, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw sqlError("Failed to unmark file as indexed")
        }
    }

    /// Remove all entries for a given file path, including chunks and the
    /// completion record in `indexed_files`.
    @discardableResult
    public func removeEntries(forPath path: String) throws -> Int {
        let removed = try _removeEntries(forPath: path)
        try unmarkFileIndexed(path: path)
        return removed
    }

    // MARK: - Counts

    /// Returns the total number of chunk rows in the database.
    public func totalChunkCount() throws -> Int {
        let sql = "SELECT COUNT(*) FROM chunks"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqlError("Failed to count chunks")
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw sqlError("Failed to retrieve chunk count")
        }

        return Int(sqlite3_column_int64(stmt, 0))
    }

    // MARK: - Chunk lookup

    /// Fetch a single chunk by its 1-based position within a file, ordered by
    /// insertion (`id ASC`). Returns nil if no chunk exists at that index.
    ///
    /// Chunk indices are stable for a given indexed state: the extractor
    /// produces chunks deterministically from file content, so an unchanged
    /// file re-indexed will yield the same ordering.
    public func fetchChunk(filePath: String, index: Int) throws -> SearchResult? {
        guard index >= 1 else { return nil }

        let sql = """
            SELECT file_path, line_start, line_end, chunk_type, page_number, content_preview
            FROM chunks
            WHERE file_path = ?
            ORDER BY id ASC
            LIMIT 1 OFFSET ?
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqlError("Failed to prepare fetch-chunk statement")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, filePath, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int(stmt, 2, Int32(index - 1))

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return nil
        }

        let path = String(cString: sqlite3_column_text(stmt, 0))
        let lineStart = sqlite3_column_type(stmt, 1) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 1)) : nil
        let lineEnd = sqlite3_column_type(stmt, 2) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 2)) : nil
        let chunkTypeRaw = String(cString: sqlite3_column_text(stmt, 3))
        let pageNumber = sqlite3_column_type(stmt, 4) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 4)) : nil
        let contentPreview = sqlite3_column_type(stmt, 5) != SQLITE_NULL
            ? String(cString: sqlite3_column_text(stmt, 5))
            : nil

        return SearchResult(
            filePath: path,
            lineStart: lineStart,
            lineEnd: lineEnd,
            chunkType: ChunkType(rawValue: chunkTypeRaw) ?? .whole,
            pageNumber: pageNumber,
            contentPreview: contentPreview,
            distance: 0
        )
    }

    /// Return a map from chunk row `id` to its 1-based position within a
    /// file, ordered by insertion (`id ASC`). Empty map if no chunks exist.
    public func chunkOrdinals(filePath: String) throws -> [Int64: Int] {
        let sql = "SELECT id FROM chunks WHERE file_path = ? ORDER BY id ASC"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqlError("Failed to prepare chunk-ordinals statement")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, filePath, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var result: [Int64: Int] = [:]
        var position = 1
        while sqlite3_step(stmt) == SQLITE_ROW {
            result[sqlite3_column_int64(stmt, 0)] = position
            position += 1
        }
        return result
    }

    /// Count chunks for a given file path.
    public func chunkCount(filePath: String) throws -> Int {
        let sql = "SELECT COUNT(*) FROM chunks WHERE file_path = ?"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqlError("Failed to prepare chunk-count statement")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, filePath, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw sqlError("Failed to retrieve chunk count for file")
        }

        return Int(sqlite3_column_int64(stmt, 0))
    }

    // MARK: - Private (non-actor-boundary helpers for use within transactions)

    /// Insert a single row — called internally, does not cross the actor boundary.
    @discardableResult
    private func _insert(
        filePath: String,
        lineStart: Int?,
        lineEnd: Int?,
        chunkType: ChunkType,
        pageNumber: Int?,
        fileModifiedAt: Date,
        contentPreview: String,
        embedding: [Float]
    ) throws -> Int64 {
        let sql = """
            INSERT INTO chunks (file_path, line_start, line_end, chunk_type, page_number, file_modified_at, content_preview, embedding)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqlError("Failed to prepare insert statement")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, filePath, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        bindOptionalInt(stmt, index: 2, value: lineStart)
        bindOptionalInt(stmt, index: 3, value: lineEnd)
        sqlite3_bind_text(stmt, 4, chunkType.rawValue, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        bindOptionalInt(stmt, index: 5, value: pageNumber)
        sqlite3_bind_double(stmt, 6, fileModifiedAt.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 7, contentPreview, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        // Store embedding as raw Float32 bytes
        let data = embedding.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
        let bindResult = data.withUnsafeBytes { rawBuffer in
            sqlite3_bind_blob(stmt, 8, rawBuffer.baseAddress, Int32(rawBuffer.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard bindResult == SQLITE_OK else {
            throw sqlError("Failed to bind embedding blob")
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw sqlError("Failed to insert chunk")
        }

        return sqlite3_last_insert_rowid(db)
    }

    /// Delete entries for a path — called internally, does not cross the actor boundary.
    @discardableResult
    private func _removeEntries(forPath path: String) throws -> Int {
        let sql = "DELETE FROM chunks WHERE file_path = ?"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqlError("Failed to prepare delete statement")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, path, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw sqlError("Failed to delete entries")
        }

        return Int(sqlite3_changes(db))
    }

    /// Execute raw SQL — called internally, does not cross the actor boundary.
    private func _execute(_ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errMsg) == SQLITE_OK else {
            let message: String
            if let errMsg = errMsg {
                message = String(cString: errMsg)
                sqlite3_free(errMsg)
            } else {
                message = "Unknown error"
            }
            throw VecError.sqliteError(message)
        }
    }

    private func openDatabase() throws {
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw sqlError("Failed to open database at \(dbPath)")
        }
    }

    private func createSchema() throws {
        let createChunksTable = """
            CREATE TABLE IF NOT EXISTS chunks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                file_path TEXT NOT NULL,
                line_start INTEGER,
                line_end INTEGER,
                chunk_type TEXT NOT NULL,
                page_number INTEGER,
                file_modified_at REAL NOT NULL,
                content_preview TEXT,
                embedding BLOB NOT NULL
            );
            """

        let createChunksIndex = "CREATE INDEX IF NOT EXISTS idx_chunks_file_path ON chunks(file_path);"

        let createIndexedFilesTable = """
            CREATE TABLE IF NOT EXISTS indexed_files (
                file_path TEXT PRIMARY KEY NOT NULL,
                file_modified_at REAL NOT NULL,
                line_page_count INTEGER
            );
            """

        try _execute("BEGIN TRANSACTION")
        do {
            try _execute(createChunksTable)
            try _execute(createChunksIndex)
            try _execute(createIndexedFilesTable)
            try _execute("COMMIT")
        } catch {
            try? _execute("ROLLBACK")
            throw error
        }
    }

    private func verifySchema() throws {
        let sql = "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'chunks'"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqlError("Failed to verify schema")
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw sqlError("Failed to query sqlite_master")
        }

        if sqlite3_column_int(stmt, 0) == 0 {
            throw VecError.databaseCorrupted("Missing required table: chunks")
        }

        // Migrate: add indexed_files table if missing (pre-existing databases)
        try migrateIfNeeded()
    }

    private func migrateIfNeeded() throws {
        // Single-user tool: schema changes require re-indexing. No migrations.
    }

    private func bindOptionalInt(_ stmt: OpaquePointer?, index: Int32, value: Int?) {
        if let value = value {
            sqlite3_bind_int(stmt, index, Int32(value))
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func sqlError(_ context: String) -> VecError {
        let message: String
        if let db = db, let errMsg = sqlite3_errmsg(db) {
            message = "\(context): \(String(cString: errMsg))"
        } else {
            message = context
        }
        return VecError.sqliteError(message)
    }

    /// Compute cosine distance between two vectors using SIMD-accelerated vDSP.
    /// Returns 0.0 for identical vectors, up to 2.0 for opposite vectors.
    private func cosineDistance(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count else { return 1.0 }
        let count = a.count
        guard count > 0 else { return 1.0 }
        let n = vDSP_Length(count)

        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, n)
        vDSP_dotpr(a, 1, a, 1, &normA, n)
        vDSP_dotpr(b, 1, b, 1, &normB, n)

        let denom = sqrt(normA) * sqrt(normB)
        guard denom > 0 else { return 1.0 }
        return 1.0 - Double(dot / denom)
    }
}
