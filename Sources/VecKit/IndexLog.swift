import Foundation

/// One file that was indexed but lost some of its chunks to embed
/// failures. The file IS in the DB (with `totalChunks - failedChunks`
/// surviving records); this entry records the partial loss for audit.
/// Distinct from `skippedEmbedFailures` (the file landed in
/// `.skippedEmbedFailure` — every chunk failed and nothing was
/// indexed).
public struct PartialFailure: Codable, Sendable, Equatable {
    public let path: String
    public let failedChunks: Int
    public let totalChunks: Int

    public init(path: String, failedChunks: Int, totalChunks: Int) {
        self.path = path
        self.failedChunks = failedChunks
        self.totalChunks = totalChunks
    }
}

/// One record per `update-index` invocation. Encoded as a single line of
/// JSON in `~/.vec/<db>/index.log` (JSONL — append-friendly,
/// line-oriented, greppable).
///
/// `schemaVersion` is forward-compat insurance: future field changes can
/// branch on it without a forensic exercise. `timestamp` is encoded ISO-8601
/// (UTC, `Z`-suffix). `wallSeconds` is `Double` seconds (not milliseconds).
/// `skippedUnreadable` / `skippedEmbedFailures` carry the same
/// relative-to-source-dir strings the pipeline emits in
/// `IndexResult.skippedUnreadable(filePath:)` /
/// `.skippedEmbedFailure(filePath:)`.
/// `partialEmbedFailures` records files that DID land in the DB but
/// lost some of their chunks to embed failures (per-chunk partial
/// failure, distinct from the all-chunks-failed
/// `skippedEmbedFailures` case).
public struct IndexLogEntry: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let timestamp: Date
    public let embedder: String
    public let profile: String
    public let wallSeconds: Double
    public let filesScanned: Int
    public let added: Int
    public let updated: Int
    public let removed: Int
    public let unchanged: Int
    public let skippedUnreadable: [String]
    public let skippedEmbedFailures: [String]
    public let partialEmbedFailures: [PartialFailure]

    public init(
        schemaVersion: Int = 1,
        timestamp: Date,
        embedder: String,
        profile: String,
        wallSeconds: Double,
        filesScanned: Int,
        added: Int,
        updated: Int,
        removed: Int,
        unchanged: Int,
        skippedUnreadable: [String],
        skippedEmbedFailures: [String],
        partialEmbedFailures: [PartialFailure]
    ) {
        self.schemaVersion = schemaVersion
        self.timestamp = timestamp
        self.embedder = embedder
        self.profile = profile
        self.wallSeconds = wallSeconds
        self.filesScanned = filesScanned
        self.added = added
        self.updated = updated
        self.removed = removed
        self.unchanged = unchanged
        self.skippedUnreadable = skippedUnreadable
        self.skippedEmbedFailures = skippedEmbedFailures
        self.partialEmbedFailures = partialEmbedFailures
    }
}

/// Append-only JSONL log of `update-index` invocations, kept at
/// `~/.vec/<db>/index.log`. Capped at the most recent
/// `IndexLog.maxRecords` entries via a last-N rotation that operates on
/// raw lines (no decode/re-encode), so additive future fields survive
/// rotation by older binaries.
public enum IndexLog {
    public static let filename = "index.log"
    public static let tmpFilename = "index.log.tmp"
    public static let maxRecords = 200

    /// Encoder shared across writes. `.iso8601` matches the timestamp
    /// shape the spec pins. We deliberately do NOT set
    /// `.prettyPrinted` — one record == one line is a load-bearing
    /// invariant of the rotation algorithm.
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Decoder helper exposed for test round-trip assertions and any
    /// future external reader. Mirrors the encoder's date strategy.
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Read existing log, drop empty trailing splits, keep the trailing
    /// `maxRecords - 1` lines, append the new line, atomically replace
    /// the file. Always terminates with a single `\n` so the on-disk
    /// form is `record1\nrecord2\n…\nrecordN\n` — a clean idempotent
    /// append target.
    public static func append(_ entry: IndexLogEntry, to dbDir: URL) throws {
        let logURL = dbDir.appendingPathComponent(filename)
        let tmpURL = dbDir.appendingPathComponent(tmpFilename)

        let encoder = makeEncoder()
        let encoded = try encoder.encode(entry)
        guard let newLine = String(data: encoded, encoding: .utf8) else {
            throw IndexLogError.encodingFailed
        }

        // Existing log → kept tail. Treat any read error other than
        // "file does not exist" as fatal: we don't want to silently
        // overwrite a log we couldn't parse, since rotation depends on
        // the byte-for-byte tail.
        var keptLines: [String] = []
        if FileManager.default.fileExists(atPath: logURL.path) {
            let existing = try String(contentsOf: logURL, encoding: .utf8)
            // `split(omittingEmptySubsequences: true)` drops the trailing
            // empty element produced by a terminal `\n`, plus any
            // accidental blank lines from a future bug. The next write
            // re-terminates with a single `\n`, so the file converges
            // back to the canonical shape regardless.
            let split = existing.split(separator: "\n", omittingEmptySubsequences: true)
            keptLines = split.map(String.init)
        }

        // Reserve one slot for the new record. `prefix(0)` short-circuits
        // gracefully if `maxRecords` is ever set to 1.
        let keepCount = max(0, maxRecords - 1)
        if keptLines.count > keepCount {
            keptLines = Array(keptLines.suffix(keepCount))
        }

        var output = ""
        for line in keptLines {
            output += line
            output += "\n"
        }
        output += newLine
        output += "\n"

        guard let outputData = output.data(using: .utf8) else {
            throw IndexLogError.encodingFailed
        }

        // tmp+rename: write the full new contents to a sibling, then
        // swap. A crash mid-write leaves either the prior log or the
        // new one — never a partial file. `replaceItemAt` is a single
        // atomic rename when the destination exists; when it doesn't,
        // we fall through to a `moveItem` after removing the (absent)
        // destination.
        try outputData.write(to: tmpURL, options: .atomic)
        do {
            if FileManager.default.fileExists(atPath: logURL.path) {
                _ = try FileManager.default.replaceItemAt(logURL, withItemAt: tmpURL)
            } else {
                try FileManager.default.moveItem(at: tmpURL, to: logURL)
            }
        } catch {
            // Best-effort cleanup of the tmp file on failure — the
            // caller's `try?` will swallow the throw, but we don't
            // want to leave an `index.log.tmp` artifact behind.
            try? FileManager.default.removeItem(at: tmpURL)
            throw error
        }
    }
}

/// Narrow error surface for log-write failures that are distinct from
/// the underlying `FileManager` errors (e.g. encoding refused to
/// produce UTF-8). External callers use `try?`, so these mostly exist
/// for test diagnostics.
public enum IndexLogError: Error, LocalizedError {
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode index log entry as UTF-8 JSON."
        }
    }
}
