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
    ///   - dimension: The embedding vector dimension (default 512).
    public init(databaseDirectory: URL, sourceDirectory: URL, dimension: Int = 512) {
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
                distance: c.distance
            )
        }
    }

    // MARK: - Index Management

    /// Get all indexed file paths and their modification dates.
    public func allIndexedFiles() throws -> [String: Date] {
        let sql = "SELECT DISTINCT file_path, MAX(file_modified_at) FROM chunks GROUP BY file_path"

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

    /// Remove all entries for a given file path.
    @discardableResult
    public func removeEntries(forPath path: String) throws -> Int {
        try _removeEntries(forPath: path)
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
        let createTable = """
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

        let createIndex = "CREATE INDEX IF NOT EXISTS idx_chunks_file_path ON chunks(file_path);"

        try _execute("BEGIN TRANSACTION")
        do {
            try _execute(createTable)
            try _execute(createIndex)
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
