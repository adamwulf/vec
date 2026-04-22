import XCTest
import Foundation
@testable import vec

/// Unit tests for the pure logic in `SweepCommand`: grid parsing and the
/// in-process scorer. The scorer tests use synthesized q<NN>.json archives
/// instead of real model output so they don't depend on a DB, a corpus,
/// or an embedder.
final class SweepCommandTests: XCTestCase {

    // MARK: - Grid parsing

    func testParseGrid_twoDimensions() throws {
        let grid = try SweepCommand.parseGrid(sizes: "800,1200", overlapPcts: "0,20")
        XCTAssertEqual(grid.count, 4)
        XCTAssertEqual(grid[0].size, 800)
        XCTAssertEqual(grid[0].overlap, 0)
        XCTAssertEqual(grid[1].size, 800)
        XCTAssertEqual(grid[1].overlap, 160)
        XCTAssertEqual(grid[2].size, 1200)
        XCTAssertEqual(grid[2].overlap, 0)
        XCTAssertEqual(grid[3].size, 1200)
        XCTAssertEqual(grid[3].overlap, 240)
    }

    func testParseGrid_rejectsInvalidOverlap() {
        // 100% of 100 = 100, which is NOT < size (100) — must throw.
        XCTAssertThrowsError(try SweepCommand.parseGrid(sizes: "100", overlapPcts: "100"))
    }

    func testParseGrid_rejectsEmpty() {
        XCTAssertThrowsError(try SweepCommand.parseGrid(sizes: "", overlapPcts: "20"))
        XCTAssertThrowsError(try SweepCommand.parseGrid(sizes: "800", overlapPcts: ""))
    }

    func testParseGrid_trimsWhitespace() throws {
        let grid = try SweepCommand.parseGrid(sizes: "800 , 1200", overlapPcts: " 20 ")
        XCTAssertEqual(grid.count, 2)
        XCTAssertEqual(grid[0].size, 800)
        XCTAssertEqual(grid[0].overlap, 160)
        XCTAssertEqual(grid[1].size, 1200)
        XCTAssertEqual(grid[1].overlap, 240)
    }

    func testParseGrid_dedupesRoundedOverlaps() throws {
        // 1% of 10 = 0.1 → rounds to 0; 2% of 10 = 0.2 → also rounds to 0.
        // Both collapse to (10, 0) and should produce exactly one grid point.
        let grid = try SweepCommand.parseGrid(sizes: "10", overlapPcts: "0,1,2")
        XCTAssertEqual(grid.count, 1)
        XCTAssertEqual(grid[0].size, 10)
        XCTAssertEqual(grid[0].overlap, 0)
    }

    // MARK: - scoreArchive

    /// Builds a synthetic q<NN>.json whose results array places
    /// `tPath` at `tRank` (1-based) and `sPath` at `sRank`, padding
    /// the rest with placeholder file entries so absent targets (nil
    /// ranks) truly don't appear anywhere in the array.
    private func writeArchive(
        at dir: URL,
        queries: [RubricManifest.Query],
        placements: [Int: (tRank: Int?, sRank: Int?)],
        tPath: String,
        sPath: String
    ) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for q in queries {
            let placement = placements[q.n] ?? (tRank: nil, sRank: nil)
            var results: [[String: Any]] = []
            // Max rank we need to cover; array length is max(maxRank, 5).
            let maxRank = max(
                placement.tRank ?? 0,
                placement.sRank ?? 0
            )
            let length = max(maxRank, 5)
            for i in 1...length {
                let file: String
                if i == placement.tRank {
                    file = tPath
                } else if i == placement.sRank {
                    file = sPath
                } else {
                    file = "filler/file\(q.n)-\(i).md"
                }
                results.append([
                    "file": file,
                    "score": Double(length - i) / Double(length),
                    "matches": [[String: Any]]()
                ])
            }
            let data = try JSONSerialization.data(withJSONObject: results, options: [])
            let url = dir.appendingPathComponent(String(format: "q%02d.json", q.n))
            try data.write(to: url)
        }
    }

    private func fixtureManifest() -> RubricManifest {
        let targets = [
            RubricManifest.TargetFile(key: "T", path: "target/transcript.txt", label: "transcript"),
            RubricManifest.TargetFile(key: "S", path: "target/summary.md", label: "summary")
        ]
        let brackets = [
            RubricManifest.RankBracket(min: 1, max: 3, points: 3),
            RubricManifest.RankBracket(min: 4, max: 10, points: 2),
            RubricManifest.RankBracket(min: 11, max: 20, points: 1)
        ]
        let scoring = RubricManifest.Scoring(
            rank_brackets: brackets,
            absent_points: 0,
            max_per_query: 6,
            max_total: 60,
            top10_threshold: 10
        )
        let queries = (1...10).map { RubricManifest.Query(n: $0, text: "q\($0)") }
        return RubricManifest(
            description: "test",
            corpus: "test",
            target_files: targets,
            scoring: scoring,
            queries: queries
        )
    }

    func testScoreArchive_matchesReferenceData() throws {
        // Cover every bracket + absent:
        //   q1: T=1, S=4    → T gets 3 (rank 1-3), S gets 2 (rank 4-10) = 5
        //   q2: T=3, S=10   → T gets 3, S gets 2 = 5
        //   q3: T=11, S=20  → T gets 1 (rank 11-20), S gets 1 = 2
        //   q4: T=21, S=nil → T gets 0 (rank > 20), S absent = 0 = 0
        //   q5: T=nil, S=nil → both absent = 0
        //   q6: T=2, S=nil  → T gets 3, S absent = 3
        //   q7: T=5, S=8    → T gets 2, S gets 2 = 4
        //   q8: T=1, S=1    → both at rank 1 is impossible in a real search
        //                     (same array slot), so simulate T=1, S=2 → 3+3=6
        //   q9: T=11, S=5   → T gets 1, S gets 2 = 3
        //   q10: T=nil, S=11 → T absent, S gets 1 = 1
        //
        // total = 5+5+2+0+0+3+4+6+3+1 = 29
        //
        // top10_either: q1,q2,q6,q7,q8,q9 = 6
        //   q3 ranks are 11/20 → neither ≤ 10, no
        //   q4 T=21/absent → no
        //   q5 both absent → no
        //   q10 S=11 → no
        // top10_both:
        //   q1: T=1 (yes), S=4 (yes) → yes
        //   q2: T=3 (yes), S=10 (yes) → yes
        //   q7: T=5 (yes), S=8 (yes) → yes
        //   q8: T=1 (yes), S=2 (yes) → yes
        //   q6: S absent → no
        //   q9: T=11 → no
        // top10_both = 4

        let manifest = fixtureManifest()
        let placements: [Int: (tRank: Int?, sRank: Int?)] = [
            1:  (tRank: 1,    sRank: 4),
            2:  (tRank: 3,    sRank: 10),
            3:  (tRank: 11,   sRank: 20),
            4:  (tRank: 21,   sRank: nil),
            5:  (tRank: nil,  sRank: nil),
            6:  (tRank: 2,    sRank: nil),
            7:  (tRank: 5,    sRank: 8),
            8:  (tRank: 1,    sRank: 2),
            9:  (tRank: 11,   sRank: 5),
            10: (tRank: nil,  sRank: 11)
        ]

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sweep-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try writeArchive(
            at: tmp,
            queries: manifest.queries,
            placements: placements,
            tPath: manifest.target_files[0].path,
            sPath: manifest.target_files[1].path
        )

        let cmd = SweepCommand.parseSweepCommand(
            args: ["--db", "x", "--embedder", "bge-base", "--sizes", "800", "--overlap-pcts", "0"]
        )
        let scored = try cmd.scoreArchive(manifest: manifest, pointDir: tmp)
        XCTAssertEqual(scored.total, 29)
        XCTAssertEqual(scored.top10Either, 6)
        XCTAssertEqual(scored.top10Both, 4)
    }

    func testScoreArchive_handlesAbsent() throws {
        // Every query has both targets absent → total = 0,
        // top10_either = 0, top10_both = 0.
        let manifest = fixtureManifest()
        let placements: [Int: (tRank: Int?, sRank: Int?)] = [:]

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sweep-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try writeArchive(
            at: tmp,
            queries: manifest.queries,
            placements: placements,
            tPath: manifest.target_files[0].path,
            sPath: manifest.target_files[1].path
        )

        let cmd = SweepCommand.parseSweepCommand(
            args: ["--db", "x", "--embedder", "bge-base", "--sizes", "800", "--overlap-pcts", "0"]
        )
        let scored = try cmd.scoreArchive(manifest: manifest, pointDir: tmp)
        XCTAssertEqual(scored.total, 0)
        XCTAssertEqual(scored.top10Either, 0)
        XCTAssertEqual(scored.top10Both, 0)
    }

    // MARK: - Real manifest round-trip

    func testManifestDecodes() throws {
        // Walk up from the test bundle to find the repo root.
        // Tests run from .build/...; climb until we find scripts/rubric-queries.json.
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: fm.currentDirectoryPath)
        var foundURL: URL?
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent("scripts/rubric-queries.json")
            if fm.fileExists(atPath: candidate.path) {
                foundURL = candidate
                break
            }
            dir.deleteLastPathComponent()
        }
        guard let url = foundURL else {
            throw XCTSkip("scripts/rubric-queries.json not locatable from test cwd")
        }

        let data = try Data(contentsOf: url)
        let manifest = try JSONDecoder().decode(RubricManifest.self, from: data)

        XCTAssertEqual(manifest.corpus, "markdown-memory")
        XCTAssertEqual(manifest.target_files.count, 2)
        XCTAssertEqual(manifest.target_files[0].key, "T")
        XCTAssertEqual(manifest.target_files[1].key, "S")
        XCTAssertEqual(manifest.queries.count, 10)
        XCTAssertEqual(manifest.scoring.rank_brackets.count, 3)
        XCTAssertEqual(manifest.scoring.max_total, 60)
        XCTAssertEqual(manifest.scoring.top10_threshold, 10)

        // Bracket point sanity: 3pts for rank 1-3, 2pts for 4-10, 1pt for 11-20.
        XCTAssertEqual(SweepCommand.pointsForRank(1, brackets: manifest.scoring.rank_brackets), 3)
        XCTAssertEqual(SweepCommand.pointsForRank(4, brackets: manifest.scoring.rank_brackets), 2)
        XCTAssertEqual(SweepCommand.pointsForRank(11, brackets: manifest.scoring.rank_brackets), 1)
        XCTAssertEqual(SweepCommand.pointsForRank(21, brackets: manifest.scoring.rank_brackets), 0)
        XCTAssertEqual(SweepCommand.pointsForRank(nil, brackets: manifest.scoring.rank_brackets), 0)
    }
}

// MARK: - Test helpers

extension SweepCommand {
    /// Parses a canonical arg list into a `SweepCommand` instance for
    /// tests. Avoids typing the full ArgumentParser boilerplate per test.
    static func parseSweepCommand(args: [String]) -> SweepCommand {
        do {
            return try SweepCommand.parseAsRoot(args) as! SweepCommand
        } catch {
            fatalError("test fixture: failed to parse SweepCommand args \(args): \(error)")
        }
    }
}
