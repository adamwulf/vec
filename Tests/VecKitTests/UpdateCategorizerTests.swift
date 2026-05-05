import XCTest
import Foundation
@testable import VecKit

/// Boundary tests for `categorizeForUpdate`, the helper that decides
/// whether each scanned file is `Added`, `Updated`, or `unchanged`
/// against an `indexed_files` snapshot.
///
/// The interesting cases are around the `Date → timeIntervalSince1970
/// → REAL → Date` round-trip ULP drift documented on
/// `mtimeRoundtripTolerance`: a strict `>` would re-extract files that
/// haven't actually changed; the tolerance comparison must let them
/// through as `unchanged`.
final class UpdateCategorizerTests: XCTestCase {

    private func makeFile(_ relativePath: String, mtime: Date) -> FileInfo {
        return FileInfo(
            relativePath: relativePath,
            url: URL(fileURLWithPath: "/tmp/\(relativePath)"),
            modificationDate: mtime,
            fileExtension: "md"
        )
    }

    /// Push a `Date` through the same lossy path the DB takes:
    /// `Date → timeIntervalSince1970 (Double) → Date(timeIntervalSince1970:)`.
    /// SQLite REAL is itself a true 8-byte double and round-trips
    /// exactly, so reproducing the drift in-memory matches the
    /// production behavior.
    ///
    /// **Codec dependency**: this test only reproduces the production
    /// drift if BOTH legs of the SQLite codec use
    /// `timeIntervalSince1970`. If either side ever switches to
    /// `timeIntervalSinceReferenceDate` (or any other epoch), the
    /// production round-trip changes and this in-memory model would
    /// silently pass while production keeps drifting. Anchor checks:
    /// `VectorDatabase.markFileIndexed` binds via
    /// `modifiedAt.timeIntervalSince1970`, and `allIndexedFiles`
    /// reads via `Date(timeIntervalSince1970: timestamp)`. Keep both
    /// in sync with the helper below.
    private func roundtripVia1970(_ date: Date) -> Date {
        return Date(timeIntervalSince1970: date.timeIntervalSince1970)
    }

    func testFileNotInIndex_isAdded() {
        let mtime = Date(timeIntervalSinceReferenceDate: 778_025_381.59197628)
        let scanned = [makeFile("new.md", mtime: mtime)]
        let result = categorizeForUpdate(scanned: scanned, indexed: [:])
        XCTAssertEqual(result.workItems.count, 1)
        XCTAssertEqual(result.workItems.first?.label, "Added")
        XCTAssertEqual(result.unchanged, 0)
    }

    func testExactlyEqualMtime_isUnchanged() {
        let mtime = Date(timeIntervalSinceReferenceDate: 778_025_381.59197628)
        let scanned = [makeFile("a.md", mtime: mtime)]
        let result = categorizeForUpdate(
            scanned: scanned,
            indexed: ["a.md": mtime]
        )
        XCTAssertEqual(result.workItems.count, 0)
        XCTAssertEqual(result.unchanged, 1)
    }

    /// The bug in production: filesystem mtime is read losslessly into
    /// a `Date`, persisted via `timeIntervalSince1970`, and read back
    /// drifts by exactly one ULP at the reference-date binade
    /// (~1.19e-7 s). Strict `>` would call this "newer"; the
    /// tolerance comparison must say "unchanged".
    func testOneULPDrift_isUnchanged() {
        // A real APFS-grade mtime that exhibits the drift in
        // production (matches the empirical observation reported
        // when this bug was diagnosed).
        let scannedMtime = Date(timeIntervalSinceReferenceDate: 778_025_381.59197628)
        let dbMtime = roundtripVia1970(scannedMtime)

        // Sanity: the round-trip *did* lose precision (otherwise the
        // test would silently pass for the wrong reason on a future
        // Foundation that fixes this).
        let drift = scannedMtime.timeIntervalSinceReferenceDate
            - dbMtime.timeIntervalSinceReferenceDate
        XCTAssertGreaterThan(drift, 0, "expected the round-trip to drop one ULP")
        XCTAssertLessThan(drift, mtimeRoundtripTolerance,
                          "drift must fall under the categorizer's tolerance")

        let scanned = [makeFile("a.md", mtime: scannedMtime)]
        let result = categorizeForUpdate(
            scanned: scanned,
            indexed: ["a.md": dbMtime]
        )
        XCTAssertEqual(result.workItems.count, 0,
                       "round-trip ULP drift must not trigger a re-index")
        XCTAssertEqual(result.unchanged, 1)
    }

    func testJustUnderTolerance_isUnchanged() {
        let dbMtime = Date(timeIntervalSinceReferenceDate: 778_025_381.5)
        let scannedMtime = dbMtime.addingTimeInterval(0.0009)  // 0.9 ms newer
        let result = categorizeForUpdate(
            scanned: [makeFile("a.md", mtime: scannedMtime)],
            indexed: ["a.md": dbMtime]
        )
        XCTAssertEqual(result.workItems.count, 0)
        XCTAssertEqual(result.unchanged, 1)
    }

    func testJustOverTolerance_isUpdated() {
        let dbMtime = Date(timeIntervalSinceReferenceDate: 778_025_381.5)
        let scannedMtime = dbMtime.addingTimeInterval(0.002)  // 2 ms newer
        let result = categorizeForUpdate(
            scanned: [makeFile("a.md", mtime: scannedMtime)],
            indexed: ["a.md": dbMtime]
        )
        XCTAssertEqual(result.workItems.count, 1)
        XCTAssertEqual(result.workItems.first?.label, "Updated")
        XCTAssertEqual(result.unchanged, 0)
    }

    /// If the scanned mtime is *older* than the indexed value (clock
    /// skew, restored-from-backup, network share with rollback), the
    /// categorizer's intent is "is the source newer than the indexed
    /// copy" — older still answers no. Asymmetric `>` semantics, not
    /// symmetric equality.
    func testOlderThanIndexed_isUnchanged() {
        let dbMtime = Date(timeIntervalSinceReferenceDate: 778_025_381.5)
        let scannedMtime = dbMtime.addingTimeInterval(-60)  // 1 min older
        let result = categorizeForUpdate(
            scanned: [makeFile("a.md", mtime: scannedMtime)],
            indexed: ["a.md": dbMtime]
        )
        XCTAssertEqual(result.workItems.count, 0)
        XCTAssertEqual(result.unchanged, 1)
    }

    /// Property test: across a wide span of plausible APFS-grade mtimes,
    /// the round-trip-then-compare should always say `unchanged`. Pins
    /// the precision claim against the entire mtime distribution we
    /// care about, not a single example.
    func testRoundtripPropertyAcrossYearRange() {
        // 2020-01-01 through 2030-12-31 covers any plausible vec corpus.
        let minRef = Date(timeIntervalSince1970: 1_577_836_800).timeIntervalSinceReferenceDate
        let maxRef = Date(timeIntervalSince1970: 1_924_991_999).timeIntervalSinceReferenceDate

        var rng = SystemRandomNumberGenerator()
        for _ in 0..<1000 {
            let ref = Double.random(in: minRef...maxRef, using: &rng)
            let original = Date(timeIntervalSinceReferenceDate: ref)
            let roundTripped = roundtripVia1970(original)

            let result = categorizeForUpdate(
                scanned: [makeFile("p.md", mtime: original)],
                indexed: ["p.md": roundTripped]
            )
            XCTAssertEqual(result.workItems.count, 0,
                           "round-trip drift at ref=\(ref) caused re-index")
            XCTAssertEqual(result.unchanged, 1)
        }
    }

    func testMixOfAddedUpdatedUnchanged() {
        let baseMtime = Date(timeIntervalSinceReferenceDate: 778_025_381.5)
        let scanned = [
            makeFile("a.md", mtime: baseMtime),                         // unchanged
            makeFile("b.md", mtime: baseMtime.addingTimeInterval(60)),  // updated (1 min newer)
            makeFile("c.md", mtime: baseMtime),                         // added (no DB row)
        ]
        let result = categorizeForUpdate(
            scanned: scanned,
            indexed: [
                "a.md": baseMtime,
                "b.md": baseMtime,
            ]
        )
        XCTAssertEqual(result.unchanged, 1)
        XCTAssertEqual(result.workItems.count, 2)
        let labelsByPath = Dictionary(uniqueKeysWithValues:
            result.workItems.map { ($0.file.relativePath, $0.label) })
        XCTAssertEqual(labelsByPath["b.md"], "Updated")
        XCTAssertEqual(labelsByPath["c.md"], "Added")
    }
}
