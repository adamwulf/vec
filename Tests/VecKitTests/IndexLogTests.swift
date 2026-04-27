import XCTest
@testable import VecKit

/// Tests the E8 `index.log` writer.
///
/// Pin-points:
///  1. Round-trip: encoded entry parses back to an equal struct, the raw
///     JSON is exactly one line, and `schemaVersion` survives encoding.
///  2. Append: first write produces one record, second write produces
///     two — both decode.
///  3. Last-N rotation: pre-fill with 250 lines, append → file has
///     exactly 200 lines AND the kept tail contains entries from the
///     pre-fill (not just the new entry — guards against the "drop
///     everything" off-by-one).
///  4. Atomic-replace cleanup: no `index.log.tmp` artifact remains after
///     a successful append.
final class IndexLogTests: XCTestCase {

    private var tempDir: URL!
    private var dbDir: URL!

    override func setUp() {
        super.setUp()
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("VecIndexLog-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        tempDir = realpath(raw.path, &buf) != nil
            ? URL(fileURLWithPath: String(cString: buf), isDirectory: true)
            : raw
        dbDir = tempDir.appendingPathComponent("db")
        try! FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        super.tearDown()
    }

    // MARK: - Round-trip

    /// Encoding-then-decoding produces an equal struct, and the raw JSON
    /// has the load-bearing properties: ISO-8601 `Z`-suffix timestamp,
    /// schemaVersion present in the JSON, and the encoded form is
    /// exactly one line (no embedded `\n` — guards against accidental
    /// `.prettyPrinted`).
    func testRoundTripEncodeDecode() throws {
        let entry = makeEntry(unreadable: ["a/b.bin"], embedFailures: [])

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entry)

        let raw = String(data: data, encoding: .utf8) ?? ""

        // One line: no `\n` anywhere in the encoded form.
        XCTAssertFalse(raw.contains("\n"),
                       "encoded entry must be a single line — embedded \\n breaks JSONL rotation")

        // schemaVersion appears in raw JSON (forward-compat marker).
        XCTAssertTrue(raw.contains("\"schemaVersion\":1"),
                      "schemaVersion=1 must be present in raw JSON")

        // ISO-8601 with `Z` suffix.
        XCTAssertTrue(raw.contains("\"timestamp\":\""),
                      "timestamp field must be present")
        XCTAssertTrue(raw.range(of: #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"#,
                                options: .regularExpression) != nil,
                      "timestamp must be ISO-8601 with Z suffix; raw=\(raw)")

        // Decode round-trip equality.
        let decoded = try IndexLog.makeDecoder().decode(IndexLogEntry.self, from: data)
        XCTAssertEqual(decoded, entry, "round-trip must preserve every field")
    }

    // MARK: - Append

    /// Fresh dir → first append produces a one-line file that parses
    /// back to the input entry.
    func testAppendToFreshDirectoryProducesOneRecord() throws {
        let entry = makeEntry()
        try IndexLog.append(entry, to: dbDir)

        let logURL = dbDir.appendingPathComponent(IndexLog.filename)
        let contents = try String(contentsOf: logURL, encoding: .utf8)

        // Canonical shape: every record (including the last) ends in `\n`.
        XCTAssertTrue(contents.hasSuffix("\n"), "log must terminate with a trailing newline")

        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 1, "first append must produce exactly one record")

        let decoded = try IndexLog.makeDecoder().decode(
            IndexLogEntry.self,
            from: Data(lines[0].utf8)
        )
        XCTAssertEqual(decoded, entry)
    }

    /// Two appends → two records, both parse, ordering preserved.
    func testAppendTwiceProducesTwoOrderedRecords() throws {
        let first = makeEntry(filesScanned: 100)
        let second = makeEntry(filesScanned: 200)

        try IndexLog.append(first, to: dbDir)
        try IndexLog.append(second, to: dbDir)

        let logURL = dbDir.appendingPathComponent(IndexLog.filename)
        let contents = try String(contentsOf: logURL, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 2)

        let decoder = IndexLog.makeDecoder()
        let decodedFirst = try decoder.decode(IndexLogEntry.self, from: Data(lines[0].utf8))
        let decodedSecond = try decoder.decode(IndexLogEntry.self, from: Data(lines[1].utf8))
        XCTAssertEqual(decodedFirst.filesScanned, 100, "first record stays first")
        XCTAssertEqual(decodedSecond.filesScanned, 200, "second record stays second")
    }

    // MARK: - Last-N rotation

    /// Pre-fill with 250 raw lines, append one entry → file has exactly
    /// 200 lines AND contains entries from the pre-filled tail (not just
    /// the newly appended one). The "kept tail must include >1 prior
    /// record" assertion guards against the "drop everything" off-by-one
    /// the spec calls out.
    func testLastNRotationKeepsPriorTail() throws {
        let logURL = dbDir.appendingPathComponent(IndexLog.filename)

        // Pre-fill 250 synthetic raw JSON lines so we don't depend on
        // 250 real encodes. Each line is parseable JSON with a unique
        // marker so we can tell which survived rotation.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var prefill = ""
        for i in 0..<250 {
            let entry = makeEntry(embedderName: "prefill-\(i)", filesScanned: i)
            let data = try encoder.encode(entry)
            prefill += String(data: data, encoding: .utf8)!
            prefill += "\n"
        }
        try prefill.write(to: logURL, atomically: true, encoding: .utf8)

        // Append one new entry.
        let newEntry = makeEntry(embedderName: "the-new-one", filesScanned: 9_999)
        try IndexLog.append(newEntry, to: dbDir)

        let contents = try String(contentsOf: logURL, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)

        // Hard cap: exactly maxRecords lines after rotation.
        XCTAssertEqual(lines.count, IndexLog.maxRecords,
                       "post-rotation log must have exactly \(IndexLog.maxRecords) lines")

        let decoder = IndexLog.makeDecoder()

        // Last line is the new entry.
        let last = try decoder.decode(IndexLogEntry.self, from: Data(lines[lines.count - 1].utf8))
        XCTAssertEqual(last.embedder, "the-new-one",
                       "newest entry must land at the tail")

        // Critical: the kept tail includes >1 prior record. With 250
        // pre-filled + 1 new and a 200-cap, the kept slice is the LAST
        // 199 of the pre-fill (entries 51..249) plus the new one. So
        // line 0 must decode to the prefill entry with filesScanned=51.
        let first = try decoder.decode(IndexLogEntry.self, from: Data(lines[0].utf8))
        XCTAssertEqual(first.filesScanned, 51,
                       "kept tail must start at prefill entry 51 (250 - (200-1) = 51)")
        XCTAssertEqual(first.embedder, "prefill-51",
                       "kept tail must preserve the original prefill entries verbatim")

        // And many entries from the prefill tail survived — not just
        // the new one. Spot-check the boundary and somewhere in the
        // middle.
        let secondToLast = try decoder.decode(
            IndexLogEntry.self,
            from: Data(lines[lines.count - 2].utf8)
        )
        XCTAssertEqual(secondToLast.embedder, "prefill-249",
                       "the last prefill entry must survive — it's the one immediately before the new tail")

        let middle = try decoder.decode(IndexLogEntry.self, from: Data(lines[100].utf8))
        XCTAssertEqual(middle.embedder, "prefill-151",
                       "rotation must preserve raw lines verbatim across the tail")
    }

    // MARK: - Atomic-replace cleanup

    /// After a successful append, no `index.log.tmp` artifact remains in
    /// the DB directory. Pins the cleanup contract regardless of whether
    /// the implementation uses `replaceItemAt` or `moveItem`.
    func testAtomicReplaceLeavesNoTmpArtifact() throws {
        try IndexLog.append(makeEntry(), to: dbDir)
        let tmpURL = dbDir.appendingPathComponent(IndexLog.tmpFilename)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpURL.path),
                       "no \(IndexLog.tmpFilename) artifact must remain after a successful append")

        // Append again — a second successful write also leaves no tmp.
        try IndexLog.append(makeEntry(filesScanned: 5), to: dbDir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpURL.path),
                       "no tmp artifact after the second append either")
    }

    // MARK: - One-line invariant on append

    /// Sanity check the on-disk form of every line: each record must be
    /// a single line of valid JSON. Pre-fill produces 250 records and
    /// rotation must preserve the property after trimming.
    func testEveryLineIsValidJSONOneLine() throws {
        for i in 0..<3 {
            try IndexLog.append(makeEntry(filesScanned: i), to: dbDir)
        }
        let logURL = dbDir.appendingPathComponent(IndexLog.filename)
        let contents = try String(contentsOf: logURL, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 3)

        let decoder = IndexLog.makeDecoder()
        for line in lines {
            // No embedded newlines (line is, by construction, a split
            // result; this assertion is the dual of the round-trip
            // test's no-`\n` check applied to the on-disk form).
            XCTAssertFalse(line.contains("\n"))
            // Each line decodes to a valid IndexLogEntry.
            _ = try decoder.decode(IndexLogEntry.self, from: Data(line.utf8))
        }
    }

    // MARK: - Helpers

    /// Constructs an entry with default-but-distinct values. Tests
    /// override only the fields they need.
    private func makeEntry(
        timestamp: Date = Date(timeIntervalSince1970: 1_761_502_242), // 2025-10-26T19:30:42Z
        embedderName: String = "e5-base",
        profile: String = "e5-base@1200/0",
        wallSeconds: Double = 963.4,
        filesScanned: Int = 752,
        added: Int = 734,
        updated: Int = 0,
        removed: Int = 0,
        unchanged: Int = 0,
        unreadable: [String] = [],
        embedFailures: [String] = []
    ) -> IndexLogEntry {
        IndexLogEntry(
            timestamp: timestamp,
            embedder: embedderName,
            profile: profile,
            wallSeconds: wallSeconds,
            filesScanned: filesScanned,
            added: added,
            updated: updated,
            removed: removed,
            unchanged: unchanged,
            skippedUnreadable: unreadable,
            skippedEmbedFailures: embedFailures
        )
    }
}
