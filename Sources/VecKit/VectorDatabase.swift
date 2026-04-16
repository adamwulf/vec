import Foundation
import CSQLiteVec

/// Wraps SQLite for storing and querying vector embeddings using pure-Swift
/// cosine-distance search. No external dynamic library required.
public class VectorDatabase {

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

    /// Insert a chunk embedding into the database.
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
        _ = data.withUnsafeBytes { rawBuffer in
            sqlite3_bind_blob(stmt, 8, rawBuffer.baseAddress, Int32(rawBuffer.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw sqlError("Failed to insert chunk")
        }

        return sqlite3_last_insert_rowid(db)
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

    // MARK: - Private

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

        try execute("BEGIN TRANSACTION")
        do {
            try execute(createTable)
            try execute(createIndex)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
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

    /// Compute cosine distance between two vectors.
    /// Returns 0.0 for identical vectors, up to 2.0 for opposite vectors.
    private func cosineDistance(_ a: [Float], _ b: [Float]) -> Double {
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        let count = min(a.count, b.count)
        for i in 0..<count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrt(normA) * sqrt(normB)
        guard denom > 0 else { return 1.0 }
        let similarity = Double(dot / denom)
        return 1.0 - similarity
    }
}
