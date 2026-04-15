import Foundation
import CSQLiteVec
import vector

/// Wraps SQLite + sqlite-vector for storing and querying vector embeddings.
public class VectorDatabase {

    private let directory: URL
    private let dbPath: String
    private var db: OpaquePointer?

    /// The dimension of vectors stored in this database.
    public let dimension: Int

    public init(directory: URL, dimension: Int = 512) {
        self.directory = directory
        self.dbPath = directory
            .appendingPathComponent(".vec")
            .appendingPathComponent("index.db")
            .path
        self.dimension = dimension
    }

    // MARK: - Lifecycle

    /// Initialize a new database, creating the .vec directory and schema.
    public func initialize() throws {
        let vecDir = directory.appendingPathComponent(".vec")

        try FileManager.default.createDirectory(at: vecDir, withIntermediateDirectories: true)

        try openDatabase()
        try loadVectorExtension()
        try createSchema()
    }

    /// Open an existing database.
    public func open() throws {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw VecError.databaseNotInitialized
        }
        try openDatabase()
        try loadVectorExtension()
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
            VALUES (?, ?, ?, ?, ?, ?, ?, vector_as_f32(?))
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

        // Convert embedding to JSON array string for vector_as_f32()
        let jsonArray = "[" + embedding.map { String($0) }.joined(separator: ",") + "]"
        sqlite3_bind_text(stmt, 8, jsonArray, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw sqlError("Failed to insert chunk")
        }

        return sqlite3_last_insert_rowid(db)
    }

    // MARK: - Query

    /// Search for similar embeddings.
    public func search(embedding: [Float], limit: Int) throws -> [SearchResult] {
        let jsonArray = "[" + embedding.map { String($0) }.joined(separator: ",") + "]"

        let sql = """
            SELECT c.file_path, c.line_start, c.line_end, c.chunk_type, c.page_number, c.content_preview, v.distance
            FROM chunks AS c
            JOIN vector_full_scan('chunks', 'embedding', vector_as_f32(?), ?) AS v
            ON c.id = v.rowid
            ORDER BY v.distance ASC
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqlError("Failed to prepare search statement")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, jsonArray, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var results: [SearchResult] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let filePath = String(cString: sqlite3_column_text(stmt, 0))
            let lineStart = sqlite3_column_type(stmt, 1) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 1)) : nil
            let lineEnd = sqlite3_column_type(stmt, 2) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 2)) : nil
            let chunkTypeRaw = String(cString: sqlite3_column_text(stmt, 3))
            let pageNumber = sqlite3_column_type(stmt, 4) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 4)) : nil
            let contentPreview = sqlite3_column_type(stmt, 5) != SQLITE_NULL
                ? String(cString: sqlite3_column_text(stmt, 5))
                : nil
            let distance = sqlite3_column_double(stmt, 6)

            results.append(SearchResult(
                filePath: filePath,
                lineStart: lineStart,
                lineEnd: lineEnd,
                chunkType: ChunkType(rawValue: chunkTypeRaw) ?? .whole,
                pageNumber: pageNumber,
                contentPreview: contentPreview,
                distance: distance
            ))
        }

        return results
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

    // MARK: - Private

    private func openDatabase() throws {
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw sqlError("Failed to open database at \(dbPath)")
        }
    }

    private func loadVectorExtension() throws {
        // Enable extension loading
        sqlite3_enable_load_extension(db, 1)

        // Build a list of candidate paths for the sqlite-vector extension dylib.
        // The `vector` Swift package provides vector.path, but that assumes a .app bundle.
        // For a CLI tool built with SPM, the framework is placed alongside the executable.
        let executableDir = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
            .deletingLastPathComponent().path

        var possiblePaths = [
            // Framework alongside the executable (SPM places it here)
            executableDir + "/vector.framework/vector",
            // The vector package's suggested path (works for .app bundles)
            vector.path,
            // Homebrew or system-installed
            "/usr/local/lib/vector",
            "/opt/homebrew/lib/vector",
            // Bundled with the tool
            Bundle.main.bundlePath + "/vector",
        ]

        // @rpath resolution lets the dynamic linker find the framework
        // when running in test bundles or other contexts with rpath set
        possiblePaths.append("@rpath/vector.framework/vector")

        var loaded = false
        var lastError: String?

        for path in possiblePaths {
            var errMsg: UnsafeMutablePointer<CChar>?
            let result = sqlite3_load_extension(db, path, "sqlite3_vector_init", &errMsg)
            if result == SQLITE_OK {
                loaded = true
                break
            }
            if let errMsg = errMsg {
                lastError = String(cString: errMsg)
                sqlite3_free(errMsg)
            }
        }

        if !loaded {
            let hint = lastError ?? "Extension not found"
            throw VecError.sqliteError(
                "Failed to load sqlite-vector extension. \(hint)\n" +
                "Searched paths:\n" +
                possiblePaths.map { "  - \($0)" }.joined(separator: "\n")
            )
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

        let vectorInit = "SELECT vector_init('chunks', 'embedding', 'dimension=\(dimension),type=FLOAT32,distance=cosine');"

        try execute(createTable)
        try execute(createIndex)
        try execute(vectorInit)
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
}
