import Foundation
import ArgumentParser
import VecKit

struct SweepCommand: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "sweep",
        abstract: "Reset+reindex+score across a chunk-geometry grid for a given embedder"
    )

    @Option(name: .shortAndLong, help: "Name of the database to sweep. The DB must already be init'd; its source directory will be reindexed for every grid point.")
    var db: String

    @Option(name: .long, help: "Embedder alias (\(IndexingProfileFactory.knownAliases.joined(separator: ", ")))")
    var embedder: String

    @Option(name: .long, help: "Comma-separated chunk sizes in characters, e.g. '400,600,800,1200,1600'")
    var sizes: String

    @Option(name: .long, help: "Comma-separated chunk overlap percentages of size, e.g. '0,10,20'. Each overlap is computed as round(size * pct / 100) per grid point.")
    var overlapPcts: String

    @Option(name: .long, help: "Output directory for per-grid-point archives and summary.md. Defaults to benchmarks/sweep-<alias>-<yyyymmdd-HHmmss>/.")
    var out: String?

    @Flag(name: .long, help: "Skip grid points that already have a complete archive + summary row at the output path")
    var skipExisting: Bool = false

    @Option(name: .long, help: "Path to rubric manifest JSON (default: scripts/rubric-queries.json)")
    var rubric: String = "scripts/rubric-queries.json"

    @Flag(name: .long, help: "Skip the destructive-wipe confirmation prompt. Sweeps delete the database's `index.db` and rebuild it from scratch for every grid point; this flag is required in non-interactive contexts.")
    var force: Bool = false

    @Flag(name: .shortAndLong, help: "Print progress line per grid point")
    var verbose: Bool = false

    func run() async throws {
        // Step 1: parse grid.
        let grid = try Self.parseGrid(sizes: sizes, overlapPcts: overlapPcts)

        // Step 2: load rubric manifest.
        let rubricURL = URL(fileURLWithPath: rubric)
        let rubricData: Data
        do {
            rubricData = try Data(contentsOf: rubricURL)
        } catch {
            print("Error: could not read rubric manifest at \(rubricURL.path): \(error.localizedDescription)")
            throw ExitCode.failure
        }
        let manifest: RubricManifest
        do {
            manifest = try JSONDecoder().decode(RubricManifest.self, from: rubricData)
        } catch {
            print("Error: malformed rubric manifest at \(rubricURL.path): \(error.localizedDescription)")
            throw ExitCode.failure
        }
        guard manifest.target_files.count == 2 else {
            print("Error: rubric manifest currently assumes exactly 2 target files (got \(manifest.target_files.count)).")
            throw ExitCode.failure
        }

        // Step 3: resolve DB.
        let (dbDir, _, sourceDir) = try DatabaseLocator.resolve(db)

        // Step 3a: Every grid point wipes `dbDir` and rebuilds the index
        // from scratch. Mirror ResetCommand's confirmation pattern so a
        // misdirected `--db` can't silently destroy production data.
        let dbName = dbDir.lastPathComponent
        if !force {
            print("This sweep will repeatedly delete and re-index '\(dbName)' at \(dbDir.path) (\(grid.count) grid points).")
            print("Type the database name to confirm: ", terminator: "")
            guard let confirmation = readLine(), confirmation == dbName else {
                print("Aborted.")
                throw ExitCode.failure
            }
        }

        // Step 4: determine + create output directory.
        let outDir: URL
        if let out {
            outDir = URL(fileURLWithPath: out)
        } else {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.timeZone = TimeZone(identifier: "UTC")
            fmt.dateFormat = "yyyyMMdd-HHmmss"
            let stamp = fmt.string(from: Date())
            outDir = URL(fileURLWithPath: "benchmarks/sweep-\(embedder)-\(stamp)", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        // Step 5: open/create summary.md.
        let summaryURL = outDir.appendingPathComponent("summary.md")
        if !FileManager.default.fileExists(atPath: summaryURL.path) {
            let header = """
            | chunk_size | overlap | overlap_pct | chunks | wall_s | chps_wall | total_60 | top10_either | top10_both |
            |-----------:|--------:|------------:|-------:|-------:|----------:|---------:|-------------:|-----------:|

            """
            try header.write(to: summaryURL, atomically: true, encoding: .utf8)
        }

        // Step 6: iterate grid points.
        //
        // Each iteration body runs in `runGridPoint`, a helper function
        // (not an inlined for-body block). This is load-bearing: the
        // `VectorDatabase` actor is a reference type whose underlying
        // sqlite3 handle is only closed when the last ARC reference
        // drops, and the *next* iteration's `resetDatabase` call deletes
        // the on-disk DB directory. A for-loop `let database` would let
        // the previous iteration's actor live until ARC happens to
        // reclaim it — confining it to a helper function guarantees all
        // local references (database, pipeline, stats) are released
        // before `resetDatabase` runs next.
        var bestTotal = -1
        var bestPoint: String = ""

        for (i, point) in grid.enumerated() {
            let pointName = "\(embedder)-\(point.size)-\(point.overlap)"
            let pointDir = outDir.appendingPathComponent(pointName, isDirectory: true)

            // --skip-existing: an archive is "complete" when q01…q10.json
            // all exist AND the summary row for this chunk_size/overlap
            // pair is already present.
            if skipExisting && archiveIsComplete(pointDir: pointDir, manifest: manifest)
                && summaryHasRow(summaryURL: summaryURL, size: point.size, overlap: point.overlap) {
                if verbose {
                    print("point \(i + 1)/\(grid.count) \(embedder)@\(point.size)/\(point.overlap): skipped (already complete)")
                }
                continue
            }

            let scored = try await runGridPoint(
                index: i,
                point: point,
                pointDir: pointDir,
                dbDir: dbDir,
                sourceDir: sourceDir,
                manifest: manifest,
                summaryURL: summaryURL,
                gridCount: grid.count
            )

            if scored.total > bestTotal {
                bestTotal = scored.total
                bestPoint = "\(embedder)@\(point.size)/\(point.overlap)"
            }
        }

        // Step 7: final summary.
        print("Sweep complete. Summary: \(summaryURL.path)")
        if bestTotal >= 0 {
            print("Winner: \(bestPoint) — total=\(bestTotal)/\(manifest.scoring.max_total)")
        }
    }

    // MARK: - Per-grid-point execution

    /// Executes one grid point: reset → index → query → score → append
    /// summary row. See the call site in `run()` for why this is a
    /// separate function (it confines the `VectorDatabase` actor
    /// binding's lifetime to the function scope so ARC releases the
    /// sqlite handle before the next iteration's `resetDatabase`).
    private func runGridPoint(
        index: Int,
        point: (size: Int, overlap: Int),
        pointDir: URL,
        dbDir: URL,
        sourceDir: URL,
        manifest: RubricManifest,
        summaryURL: URL,
        gridCount: Int
    ) async throws -> ScoredResult {
        // Step 6a/b: fresh per-point archive directory.
        try? FileManager.default.removeItem(at: pointDir)
        try FileManager.default.createDirectory(at: pointDir, withIntermediateDirectories: true)

        // Step 6c: reset the DB.
        try await resetDatabase(dbDir: dbDir, sourceDir: sourceDir)

        // Step 6d/e: build profile, persist record, open DB.
        let profile = try IndexingProfileFactory.make(
            alias: embedder,
            chunkSize: point.size,
            chunkOverlap: point.overlap
        )
        let record = DatabaseConfig.ProfileRecord(
            identity: profile.identity,
            embedderName: profile.embedder.name,
            dimension: profile.embedder.dimension
        )
        let updatedConfig = DatabaseConfig(
            sourceDirectory: sourceDir.path,
            createdAt: Date(),
            profile: record
        )
        try DatabaseLocator.writeConfig(updatedConfig, to: dbDir)

        let database = VectorDatabase(
            databaseDirectory: dbDir,
            sourceDirectory: sourceDir,
            dimension: profile.embedder.dimension
        )
        try await database.open()

        // Step 6f/g: scan, build work items (all fresh → "Added"), run pipeline.
        let scanner = FileScanner(directory: sourceDir, includeHiddenFiles: false)
        let files = try scanner.scan()
        let workItems: [(file: FileInfo, label: String)] = files.map { (file: $0, label: "Added") }

        let pipeline = IndexingPipeline(profile: profile)
        let pipelineStart = Date()
        let (_, stats) = try await pipeline.run(
            workItems: workItems,
            extractor: TextExtractor(splitter: profile.splitter),
            database: database,
            progress: nil
        )
        let wallSeconds = Date().timeIntervalSince(pipelineStart)
        let chunkCount = stats.totalChunksEmbedded

        // Step 6h: run the 10 rubric queries, write q<NN>.json per point.
        try await runRubricQueries(
            profile: profile,
            database: database,
            manifest: manifest,
            outDir: pointDir
        )

        // Step 6i: score in-process.
        let scored = try scoreArchive(manifest: manifest, pointDir: pointDir)

        // Step 6j: append summary row.
        let chps = wallSeconds > 0 ? Double(chunkCount) / wallSeconds : 0
        let overlapPct = point.size > 0 ? Int((Double(point.overlap) / Double(point.size) * 100).rounded()) : 0
        let row = String(
            format: "| %d | %d | %d | %d | %.1f | %.1f | %d | %d | %d |\n",
            point.size,
            point.overlap,
            overlapPct,
            chunkCount,
            wallSeconds,
            chps,
            scored.total,
            scored.top10Either,
            scored.top10Both
        )
        try appendToFile(url: summaryURL, text: row)

        if verbose {
            print("point \(index + 1)/\(gridCount) \(embedder)@\(point.size)/\(point.overlap): total=\(scored.total)/\(manifest.scoring.max_total) top10_either=\(scored.top10Either)/\(manifest.queries.count) wall=\(String(format: "%.1f", wallSeconds))s")
        }

        return scored
    }

    // MARK: - Grid parsing

    /// Parses CSV sizes + overlap percentages into a grid. Overlap per
    /// grid point = round(size * pct / 100). Rejects empty inputs and
    /// any overlap that would be >= its size. Dedupes (size, overlap)
    /// pairs preserving first-seen order — e.g. small sizes with
    /// differing percentages can round to the same overlap, and the
    /// sweep workflow treats a point directory as a single unit.
    static func parseGrid(sizes: String, overlapPcts: String) throws -> [(size: Int, overlap: Int)] {
        let sizeList = try parseCSVInts(sizes, label: "--sizes")
        let pctList = try parseCSVInts(overlapPcts, label: "--overlap-pcts")
        guard !sizeList.isEmpty else {
            throw ValidationError("--sizes must contain at least one value")
        }
        guard !pctList.isEmpty else {
            throw ValidationError("--overlap-pcts must contain at least one value")
        }
        var grid: [(size: Int, overlap: Int)] = []
        var seen = Set<String>()
        for size in sizeList {
            guard size > 0 else {
                throw ValidationError("--sizes values must be positive (got \(size))")
            }
            for pct in pctList {
                guard pct >= 0 else {
                    throw ValidationError("--overlap-pcts values must be non-negative (got \(pct))")
                }
                let overlap = Int((Double(size) * Double(pct) / 100.0).rounded())
                guard overlap < size else {
                    throw ValidationError("grid point size=\(size) pct=\(pct) produces overlap=\(overlap) which is >= size")
                }
                let key = "\(size):\(overlap)"
                if seen.insert(key).inserted {
                    grid.append((size: size, overlap: overlap))
                }
            }
        }
        return grid
    }

    private static func parseCSVInts(_ csv: String, label: String) throws -> [Int] {
        let parts = csv.split(separator: ",")
        var result: [Int] = []
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let value = Int(trimmed) else {
                throw ValidationError("\(label): '\(trimmed)' is not a valid integer")
            }
            result.append(value)
        }
        return result
    }

    // MARK: - Reset helper

    /// Factored-out mirror of `ResetCommand.run()`'s force-mode body:
    /// remove the DB directory, re-create an empty DB with the same
    /// source, and write a profile-less config. The subsequent
    /// `update-index`-equivalent steps in `run()` will write a real
    /// `ProfileRecord` before touching the DB, just like `UpdateIndexCommand`.
    ///
    /// Uses `try?` on `removeItem` because the directory may legitimately
    /// not exist yet on the first iteration, and the next step creates it.
    func resetDatabase(dbDir: URL, sourceDir: URL) async throws {
        try? FileManager.default.removeItem(at: dbDir)
        let database = VectorDatabase(databaseDirectory: dbDir, sourceDirectory: sourceDir, dimension: 0)
        try await database.initialize()
        let config = DatabaseConfig(
            sourceDirectory: sourceDir.path,
            createdAt: Date(),
            profile: nil
        )
        try DatabaseLocator.writeConfig(config, to: dbDir)
    }

    // MARK: - Rubric query execution

    /// Runs every rubric query against the given (already-open) DB and
    /// writes per-query JSON archives matching `vec search --format json`
    /// output so `score-rubric.py` can rescore historical archives. The
    /// in-process scorer below consumes the same JSON shape.
    func runRubricQueries(
        profile: IndexingProfile,
        database: VectorDatabase,
        manifest: RubricManifest,
        outDir: URL
    ) async throws {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]

        for query in manifest.queries {
            let embedding = try await profile.embedder.embedQuery(query.text)
            // Fetch pool of 60 (matches prior rubric captures: 60 raw
            // results → coalesce to 20 file groups for the rubric
            // scorer's top-20 rank lookup).
            let rawResults = try await database.search(embedding: embedding, limit: 60)
            let grouped = SearchResultCoalescer.coalesce(rawResults, limit: 20)
            let metadata = try await database.indexedFileMetadata(paths: grouped.map(\.filePath))

            var jsonArray: [[String: Any]] = []
            for group in grouped {
                var matchesArray: [[String: Any]] = []
                for match in group.matches {
                    var matchObj: [String: Any] = [
                        "score": max(0, 1.0 - match.distance),
                        "chunk_type": match.chunkType.rawValue
                    ]
                    if let start = match.lineStart {
                        matchObj["line_start"] = start
                    }
                    if let end = match.lineEnd {
                        matchObj["line_end"] = end
                    }
                    if let page = match.pageNumber {
                        matchObj["page_number"] = page
                    }
                    matchesArray.append(matchObj)
                }

                var obj: [String: Any] = [
                    "file": group.filePath,
                    "score": group.bestScore,
                    "matches": matchesArray
                ]
                if let meta = metadata[group.filePath] {
                    obj["modified"] = fmt.string(from: meta.modifiedAt)
                    if let count = meta.linePageCount {
                        let ext = (group.filePath as NSString).pathExtension
                        let key = SearchCommand.isPDFExtension(ext) ? "page_count" : "line_count"
                        obj[key] = count
                    }
                }
                jsonArray.append(obj)
            }

            let fileURL = outDir.appendingPathComponent(String(format: "q%02d.json", query.n))
            let data = try JSONSerialization.data(withJSONObject: jsonArray, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - In-process scorer

    /// Result of scoring an archive. Mirrors `score-rubric.py`'s output
    /// lines: total points, top10_either count, top10_both count, and
    /// a per-query breakdown of the two target-file ranks for diagnostics.
    struct ScoredResult {
        let total: Int
        let top10Either: Int
        let top10Both: Int
        let perQueryRanks: [(n: Int, tRank: Int?, sRank: Int?, subtotal: Int)]
    }

    /// Scores an archive directory of `q<NN>.json` files against the
    /// rubric. Byte-for-byte equivalent to `scripts/score-rubric.py`'s
    /// total/top10_either/top10_both math — tested against fixture data
    /// in `SweepCommandTests.testScoreArchive_matchesReferenceData`.
    func scoreArchive(manifest: RubricManifest, pointDir: URL) throws -> ScoredResult {
        guard manifest.target_files.count == 2 else {
            throw ValidationError("rubric manifest currently assumes exactly 2 target files")
        }
        let tTarget = manifest.target_files[0].path
        let sTarget = manifest.target_files[1].path
        let brackets = manifest.scoring.rank_brackets
        let top10Threshold = manifest.scoring.top10_threshold

        var total = 0
        var top10Either = 0
        var top10Both = 0
        var perQuery: [(n: Int, tRank: Int?, sRank: Int?, subtotal: Int)] = []

        for query in manifest.queries {
            let path = pointDir.appendingPathComponent(String(format: "q%02d.json", query.n))
            let data = try Data(contentsOf: path)
            guard let array = try JSONSerialization.jsonObject(with: data) as? [Any] else {
                throw ValidationError("q\(String(format: "%02d", query.n)).json is not a JSON array")
            }

            let tRank = Self.rankOf(array: array, targetPath: tTarget)
            let sRank = Self.rankOf(array: array, targetPath: sTarget)
            let tPts = Self.pointsForRank(tRank, brackets: brackets)
            let sPts = Self.pointsForRank(sRank, brackets: brackets)
            let subtotal = tPts + sPts
            total += subtotal

            let tInTop10 = tRank.map { $0 <= top10Threshold } ?? false
            let sInTop10 = sRank.map { $0 <= top10Threshold } ?? false
            if tInTop10 || sInTop10 { top10Either += 1 }
            if tInTop10 && sInTop10 { top10Both += 1 }

            perQuery.append((n: query.n, tRank: tRank, sRank: sRank, subtotal: subtotal))
        }

        return ScoredResult(total: total, top10Either: top10Either, top10Both: top10Both, perQueryRanks: perQuery)
    }

    /// 1-based rank of `targetPath` in a `vec search --format json` array,
    /// or nil if absent. Matches `score-rubric.py`'s `rank_of`.
    static func rankOf(array: [Any], targetPath: String) -> Int? {
        for (idx, entry) in array.enumerated() {
            if let obj = entry as? [String: Any],
               let file = obj["file"] as? String,
               file == targetPath {
                return idx + 1
            }
        }
        return nil
    }

    /// Points awarded for a given rank using the rubric bracket table.
    /// `nil` rank → `absent_points` (0). Matches `score-rubric.py`'s
    /// `points_for_rank`.
    static func pointsForRank(_ rank: Int?, brackets: [RubricManifest.RankBracket]) -> Int {
        guard let rank else { return 0 }
        for bracket in brackets {
            if rank >= bracket.min && rank <= bracket.max {
                return bracket.points
            }
        }
        return 0
    }

    // MARK: - Filesystem helpers

    /// "Complete" means every `q<NN>.json` for the rubric's queries
    /// exists in the point dir. Summary-row presence is checked
    /// separately by `summaryHasRow`. Iterates the manifest's actual
    /// query numbers (not `1…count`) so a non-sequential manifest is
    /// handled correctly.
    func archiveIsComplete(pointDir: URL, manifest: RubricManifest) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: pointDir.path) else { return false }
        for query in manifest.queries {
            let p = pointDir.appendingPathComponent(String(format: "q%02d.json", query.n))
            if !fm.fileExists(atPath: p.path) { return false }
        }
        return true
    }

    /// Scans summary.md for a row whose chunk_size and overlap columns
    /// match the given point. Dumb substring check — the table is
    /// sweep-scoped so collisions are impossible.
    func summaryHasRow(summaryURL: URL, size: Int, overlap: Int) -> Bool {
        guard let text = try? String(contentsOf: summaryURL, encoding: .utf8) else {
            return false
        }
        let needle = "| \(size) | \(overlap) |"
        return text.contains(needle)
    }

    private func appendToFile(url: URL, text: String) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            if let data = text.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
        } else {
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
