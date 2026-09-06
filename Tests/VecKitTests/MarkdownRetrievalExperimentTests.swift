import XCTest
import Foundation
import Darwin
import CryptoKit
@testable import VecKit

/// E10 — reproducible Markdown-extraction retrieval benchmark.
///
/// Compares two `TextExtractor` arms — `.raw` (current extraction) and
/// `.markdownV1` (generic Markdown normalization) — against ONE identical
/// corpus snapshot, the real `e5-base-v2` embedder pinned at
/// `e5-base@1200/0`, identical chunk geometry, batch/bucket, and
/// concurrency. Only the text-extraction mode differs; no format-specific
/// database behavior is introduced.
///
/// HEAVY, opt-in: skipped unless `VEC_E10_BENCHMARK=1`. It loads the
/// pinned model bundle from `VEC_MARKDOWN_MODEL_DIRECTORY` (the default
/// `swift-embeddings` download target is outside the harness's writable
/// roots, so the harness NEVER downloads).
///
///     VEC_E10_BENCHMARK=1 \
///     VEC_MARKDOWN_MODEL_DIRECTORY=/private/tmp/vec-e10-model/<rev> \
///     swift test --disable-sandbox \
///       --filter VecKitTests.MarkdownRetrievalExperimentTests
///
/// See `experiments/E10-markdown-extraction/harness-notes.md`.
///
/// Invariants: freeze (hash all inputs + model files) BEFORE any ranking;
/// preflight every arm/query BEFORE any work; refuse to reuse a non-empty
/// output dir; rebuild an interrupted arm rather than trust partial data;
/// fail immediately on any skipped/partial-failed file; snapshot bodies
/// stay scratch-only and are removed on teardown (no corpus body committed).
final class MarkdownRetrievalExperimentTests: XCTestCase {

    private enum Env {
        static let enable = "VEC_E10_BENCHMARK"
        static let modelDirectory = "VEC_MARKDOWN_MODEL_DIRECTORY"
        static let modelRevision = "VEC_MARKDOWN_MODEL_REVISION"
        static let corpusDirectory = "VEC_MARKDOWN_CORPUS_DIRECTORY"
        static let outputDirectory = "VEC_E10_OUTPUT_DIRECTORY"
        static let scratchDirectory = "VEC_E10_SCRATCH_DIRECTORY"
        static let concurrency = "VEC_E10_CONCURRENCY"
        static let manifest = "VEC_E10_MANIFEST"
    }

    private static let defaultCorpus = "/tmp/LinksDatabase"
    private static let profileIdentity = "e5-base@1200/0"
    private static let chunkChars = 1200
    private static let chunkOverlap = 0
    // Mirror the real CLI: fetch limit*3 raw chunk hits, coalesce to limit.
    private static let searchLimit = 10
    private static let coalesceLimit = 10
    private static let rawFetchLimit = 30

    private var scratchRoot: URL!

    override func tearDown() {
        // Remove only the unique child we own; never the caller's override.
        if let scratchRoot {
            try? FileManager.default.removeItem(at: scratchRoot)
        }
        super.tearDown()
    }

    // MARK: - Test

    func testMarkdownExtractionRetrievalBenchmark() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            env[Env.enable] == "1",
            "Heavy opt-in benchmark — set \(Env.enable)=1 to run (needs the pinned E5 model; see harness-notes.md)."
        )

        // Model directory: REQUIRED when enabled; FAIL (not skip) if absent.
        guard let modelDirRaw = env[Env.modelDirectory], !modelDirRaw.isEmpty else {
            throw E10HarnessError("\(Env.enable) is set but \(Env.modelDirectory) is not. The benchmark must not download the model; point it at the pinned e5-base-v2 bundle.")
        }
        let modelDir = URL(fileURLWithPath: modelDirRaw, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: modelDir.path, isDirectory: &isDir), isDir.boolValue else {
            throw E10HarnessError("\(Env.modelDirectory) = \(modelDirRaw) is not an existing directory.")
        }
        let modelRevision = env[Env.modelRevision]

        let corpusDir = resolvedURL(env[Env.corpusDirectory] ?? Self.defaultCorpus)
        guard FileManager.default.fileExists(atPath: corpusDir.path) else {
            throw E10HarnessError("Corpus directory \(corpusDir.path) does not exist (override with \(Env.corpusDirectory)).")
        }

        // Concurrency: if provided, require a valid positive int (no silent fallback/clamp).
        let concurrency: Int
        if let raw = env[Env.concurrency] {
            guard let n = Int(raw), n >= 1 else {
                throw E10HarnessError("\(Env.concurrency) = '\(raw)' must be a positive integer.")
            }
            concurrency = n
        } else {
            concurrency = IndexingPipeline.defaultConcurrency
        }

        let outputDir = try prepareOutputDirectory(env[Env.outputDirectory])
        logLine("[e10] output/archive directory: \(outputDir.path)")

        scratchRoot = try makeScratchRoot(env[Env.scratchDirectory])
        let snapshotRoot = scratchRoot.appendingPathComponent("snapshot", isDirectory: true)

        // Load + PREFLIGHT the fixed manifest before any work.
        let manifestURL = try locateManifest(env)
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(RubricManifest.self, from: manifestData)
        let manifestSHA = sha256Hex(manifestData)
        try E10Preflight.validate(manifest)
        logLine("[e10] preflight OK: \(manifest.arms.count) arms, \(manifest.queries.count) queries")

        // ===== FREEZE (before any ranking) =====
        let frozenFiles = try freezeMarkdownSnapshot(from: corpusDir, to: snapshotRoot)
        logLine("[e10] froze \(frozenFiles.count) Markdown file(s)")
        if let expected = manifest.corpus?.expected_markdown_files, frozenFiles.count != expected {
            logLine("[e10] NOTE: snapshot file count \(frozenFiles.count) != manifest expected \(expected). Corpus may have drifted (operator-triggered).")
        }
        XCTAssertGreaterThan(frozenFiles.count, 0, "Snapshot must contain at least one Markdown file")

        // Every labeled file must be present in the frozen snapshot.
        try validateLabeledFilesExist(manifest: manifest, snapshotRoot: snapshotRoot)

        let normalization = try normalizationSizes(for: frozenFiles, snapshotRoot: snapshotRoot)
        let modelFiles = try hashDirectoryFiles(modelDir)
        XCTAssertGreaterThan(modelFiles.count, 0, "Model directory must contain files to hash")

        let settings = FrozenSettings(
            profile_identity: Self.profileIdentity, embedder: "e5-base-v2", dimension: 768,
            chunk_chars: Self.chunkChars, chunk_overlap: Self.chunkOverlap, concurrency: concurrency,
            batch_size: IndexingPipeline.defaultBatchSize, bucket_width: IndexingPipeline.defaultBucketWidth,
            compute_policy: "default(nil)", search_limit: Self.searchLimit,
            coalesce_limit: Self.coalesceLimit, raw_fetch_limit: Self.rawFetchLimit
        )
        let runIdentity = computeRunIdentity(files: frozenFiles, modelFiles: modelFiles,
                                             manifestSHA: manifestSHA, settings: settings)

        let frozen = FrozenInputManifest(
            experiment: "E10-markdown-extraction", run_identity: runIdentity,
            frozen_at: ISO8601DateFormatter().string(from: Date()),
            corpus_source: corpusDir.path,
            corpus_scope: manifest.corpus?.scope ?? "Markdown-only (*.md); no JSON/OCR assets.",
            files: frozenFiles, file_count: frozenFiles.count,
            query_manifest_path: relativeToRepo(manifestURL), query_manifest_sha256: manifestSHA,
            query_count: manifest.queries.count,
            model_directory: modelDir.path, model_revision: modelRevision, model_files: modelFiles,
            build: buildIdentity(), settings: settings, normalization: normalization
        )
        try writeJSON(frozen, to: outputDir.appendingPathComponent("frozen-input-manifest.json"))
        logLine("[e10] freeze complete — run_identity=\(runIdentity). Ranking begins now.")

        // ===== ARMS (each into a fresh DB) =====
        var armSummaries: [ArmSummary] = []
        var perArm: [String: [String: QueryResult]] = [:]
        for arm in manifest.arms {
            // Mode already validated in preflight; force-unwrap is safe.
            let mode = TextExtractionMode(rawValue: arm.text_extraction)!
            logLine("[e10] === arm '\(arm.key)' (textExtraction=\(mode.rawValue)) ===")
            let (summary, results) = try await runArm(arm: arm, mode: mode, snapshotRoot: snapshotRoot,
                                                      modelDir: modelDir, concurrency: concurrency,
                                                      manifest: manifest, outputDir: outputDir)
            armSummaries.append(summary)
            perArm[arm.key] = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0) })
            XCTAssertEqual(results.count, manifest.queries.count, "arm \(arm.key): every query evaluated")
        }

        // ===== COMPARISON + summary =====
        let comparison = buildComparison(manifest: manifest, perArm: perArm, arms: armSummaries)
        try writeJSON(comparison, to: outputDir.appendingPathComponent("comparison.json"))
        try writeSummaryMarkdown(frozen: frozen, arms: armSummaries, comparison: comparison,
                                 to: outputDir.appendingPathComponent("summary.md"))
        for name in ["frozen-input-manifest.json", "comparison.json", "summary.md"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: outputDir.appendingPathComponent(name).path),
                          "archive file \(name) must exist")
        }
        logLine("[e10] done. Archive at \(outputDir.path)")
    }

    // MARK: - One arm

    private func runArm(arm: RubricManifest.Arm, mode: TextExtractionMode, snapshotRoot: URL,
                        modelDir: URL, concurrency: Int, manifest: RubricManifest,
                        outputDir: URL) async throws -> (ArmSummary, [QueryResult]) {
        let armOut = outputDir.appendingPathComponent(arm.key, isDirectory: true)
        try FileManager.default.createDirectory(at: armOut, withIntermediateDirectories: true)
        let dbDir = scratchRoot.appendingPathComponent("db-\(arm.key)", isDirectory: true)

        // Profile via the PUBLIC IndexingProfile initializer + an E5 factory
        // bound to the pinned local model dir. NOT IndexingProfileFactory.make
        // (its e5 factory would download to a non-writable path).
        let e5Factory: @Sendable () -> any Embedder = { E5BaseEmbedder(modelDirectory: modelDir) }
        let profile = IndexingProfile(
            identity: Self.profileIdentity, embedder: e5Factory(), embedderFactory: e5Factory,
            splitter: RecursiveCharacterSplitter(chunkSize: Self.chunkChars, chunkOverlap: Self.chunkOverlap),
            chunkSize: Self.chunkChars, chunkOverlap: Self.chunkOverlap, isBuiltIn: true)

        let db = VectorDatabase(databaseDirectory: dbDir, sourceDirectory: snapshotRoot, dimension: profile.embedder.dimension)
        try await db.initialize()

        let files = try FileScanner(directory: snapshotRoot).scan()
        let workItems = files.map { (file: $0, label: "Added") }
        let extractor = TextExtractor(splitter: profile.splitter, textExtraction: mode)
        let pipeline = IndexingPipeline(concurrency: concurrency, profile: profile)

        let rssBefore = residentBytes()
        let indexStart = DispatchTime.now()
        let (indexResults, stats) = try await pipeline.run(workItems: workItems, extractor: extractor, database: db)
        let indexSeconds = Self.elapsed(since: indexStart)
        let rssAfter = residentBytes()

        // Fail immediately on ANY skip or partial embed failure — never emit
        // a quality result on a partial index.
        var indexedCount = 0
        var failures: [String] = []
        for r in indexResults {
            switch r {
            case .indexed(let p, _, _, let failed):
                indexedCount += 1
                if failed > 0 { failures.append("\(p): \(failed) chunk(s) failed to embed") }
            case .skippedUnreadable(let p): failures.append("\(p): skippedUnreadable")
            case .skippedEmbedFailure(let p): failures.append("\(p): skippedEmbedFailure")
            }
        }
        guard failures.isEmpty else {
            throw E10HarnessError("arm \(arm.key): index incomplete — \(failures.joined(separator: "; "))")
        }
        guard indexedCount == files.count else {
            throw E10HarnessError("arm \(arm.key): indexed \(indexedCount) of \(files.count) files")
        }
        let totalChunks = try await db.totalChunkCount()

        var perFileChunks: [PerFileChunks] = []
        for file in files {
            perFileChunks.append(PerFileChunks(path: file.relativePath, chunks: try await db.chunkCount(filePath: file.relativePath)))
        }
        perFileChunks.sort { $0.path < $1.path }
        logLine("[e10] arm \(arm.key): indexed=\(indexedCount)/\(files.count) chunks=\(totalChunks) index=\(fmt2(indexSeconds))s extract=\(fmt2(stats.extractSeconds))s embedSpan=\(fmt2(stats.embedSeconds))s db=\(fmt2(stats.dbSeconds))s rss=\(fmtMB(rssAfter))")

        // ---- Search (persist each query immediately) ----
        var results: [QueryResult] = []
        var ordinalsCache: [String: [Int64: Int]] = [:]
        var chunkCache: [String: [TextChunk]] = [:]
        var lineCache: [String: [String]] = [:]
        let searchStart = DispatchTime.now()

        func ordinals(_ path: String) async throws -> [Int64: Int] {
            if let c = ordinalsCache[path] { return c }
            let c = try await db.chunkOrdinals(filePath: path); ordinalsCache[path] = c; return c
        }
        func extractedChunks(_ path: String) throws -> [TextChunk] {
            if let c = chunkCache[path] { return c }
            let info = try FileScanner.fileInfo(for: snapshotRoot.appendingPathComponent(path), relativeTo: snapshotRoot)
            let c = try extractor.extract(from: info).chunks
            chunkCache[path] = c
            return c
        }

        for q in manifest.queries {
            let qStart = DispatchTime.now()
            let vec = try await profile.embedder.embedQuery(q.text)
            XCTAssertFalse(vec.isEmpty, "arm \(arm.key) \(q.id): empty query embedding")
            let raw = try await db.search(embedding: vec, limit: Self.rawFetchLimit)
            let groups = SearchResultCoalescer.coalesce(raw, limit: Self.coalesceLimit)
            let searchSeconds = Self.elapsed(since: qStart)
            let distinctInPool = Set(raw.map { $0.filePath }).count

            // Archive ALL coalesced groups + every match's source range, so
            // rank can be recomputed independently.
            var archivedGroups: [ArchivedGroup] = []
            for (i, g) in groups.enumerated() {
                let ords = try await ordinals(g.filePath)
                let matches = g.matches.map { m in
                    ArchivedMatch(score: max(0, 1 - m.distance), distance: m.distance,
                                  chunk_type: m.chunkType.rawValue, line_start: m.lineStart,
                                  line_end: m.lineEnd, chunk_ordinal: ords[m.chunkId])
                }
                archivedGroups.append(ArchivedGroup(rank: i + 1, file: g.filePath,
                                                    best_score: g.bestScore, match_count: g.matches.count, matches: matches))
            }

            let isNoAnswer = (q.primary_file == nil)
            var fileRank: Int? = nil
            var reciprocal = 0.0
            var audit: PrimaryAudit? = nil

            if let primary = q.primary_file, let idx = groups.firstIndex(where: { $0.filePath == primary }) {
                fileRank = idx + 1
                reciprocal = 1.0 / Double(idx + 1)
                let best = groups[idx].matches.first!
                let ords = try await ordinals(primary)
                let ordinal = ords[best.chunkId]

                // Pre-tokenizer model input for the retrieved chunk: EXACTLY
                // the string the indexing path fed the tokenizer — content
                // capped at the E5 char limit, then the "passage: " document
                // prefix — produced by the SAME normalizeBertInputs the embedder
                // uses. This is a PRE-TOKENIZER check: the BERT tokenizer then
                // truncates to 512 tokens (fewer chars than the char cap), so a
                // match here is NECESSARY but NOT SUFFICIENT evidence the model
                // encoded the term. It never over-claims a whole-doc chunk that
                // was truncated, and it is advisory (does not gate file rank).
                var preTokenizerInput = ""
                if let ordinal, ordinal >= 1 {
                    let chunks = try extractedChunks(primary)
                    if ordinal <= chunks.count {
                        preTokenizerInput = normalizeBertInputs(
                            [chunks[ordinal - 1].text], prefix: "passage: ",
                            maxChars: E5BaseEmbedder.maxInputCharacters).liveInputs.first ?? ""
                    }
                }
                // Advisory source-range text (a superset of the chunk).
                let sourceRange = reconstructSourceRange(primary: primary, match: best, snapshotRoot: snapshotRoot, cache: &lineCache)

                var crits: [CriterionResult] = []
                for c in q.passage_criteria {
                    crits.append(CriterionResult(type: c.type, value: c.value,
                                                 matched_in_pre_tokenizer_input: matches(c, in: preTokenizerInput),
                                                 matched_in_source_range: matches(c, in: sourceRange)))
                }
                audit = PrimaryAudit(
                    file_rank: idx + 1, best_score: groups[idx].bestScore, distance: best.distance,
                    chunk_type: best.chunkType.rawValue, line_start: best.lineStart, line_end: best.lineEnd,
                    chunk_ordinal: ordinal, input_chars: preTokenizerInput.count, criteria: crits,
                    all_criteria_met: !crits.isEmpty && crits.allSatisfy { $0.matched_in_pre_tokenizer_input })
            }

            let result = QueryResult(
                arm: arm.key, id: q.id, text: q.text, categories: q.categories,
                is_no_answer: isNoAnswer, primary_file: q.primary_file, relevant_files: q.relevant_files,
                file_rank: fileRank, hit_at_1: fileRank == 1,
                hit_at_3: (fileRank.map { $0 <= 3 }) ?? false, hit_at_5: (fileRank.map { $0 <= 5 }) ?? false,
                reciprocal_rank: reciprocal, overfetch_distinct_files: distinctInPool,
                search_seconds: searchSeconds, groups: archivedGroups, primary_audit: audit)
            results.append(result)
            try writeJSON(result, to: armOut.appendingPathComponent("\(q.id).json"))
        }
        let searchSecondsTotal = Self.elapsed(since: searchStart)

        let answered = results.filter { !$0.is_no_answer }
        let n = max(answered.count, 1)
        let metrics = ArmMetrics(
            answered_queries: answered.count,
            rank1_rate: Double(answered.filter { $0.hit_at_1 }.count) / Double(n),
            top3_rate: Double(answered.filter { $0.hit_at_3 }.count) / Double(n),
            top5_rate: Double(answered.filter { $0.hit_at_5 }.count) / Double(n),
            mean_reciprocal_rank: answered.map { $0.reciprocal_rank }.reduce(0, +) / Double(n),
            passage_all_met_rate: Double(answered.filter { $0.primary_audit?.all_criteria_met == true }.count) / Double(n))
        let noAnswer = results.filter { $0.is_no_answer }.map {
            NoAnswerProbe(id: $0.id, top_file: $0.groups.first?.file, top_score: $0.groups.first?.best_score)
        }
        let summary = ArmSummary(
            arm: arm.key, text_extraction: mode.rawValue, file_count: files.count, indexed_count: indexedCount,
            total_chunks: totalChunks, per_file_chunks: perFileChunks, index_seconds: indexSeconds,
            extract_seconds: stats.extractSeconds, embed_span_seconds: stats.embedSeconds, db_seconds: stats.dbSeconds,
            search_seconds: searchSecondsTotal, rss_before_index_bytes: rssBefore, rss_after_index_bytes: rssAfter,
            metrics: metrics, no_answer_probes: noAnswer)
        try writeJSON(summary, to: armOut.appendingPathComponent("arm-summary.json"))
        return (summary, results)
    }

    // MARK: - Freeze helpers

    private func freezeMarkdownSnapshot(from corpusDir: URL, to snapshotRoot: URL) throws -> [FrozenFile] {
        let fm = FileManager.default
        try fm.createDirectory(at: snapshotRoot, withIntermediateDirectories: true)
        var frozen: [FrozenFile] = []
        guard let en = fm.enumerator(at: corpusDir, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw VecError.cannotScanDirectory(corpusDir.path)
        }
        while let url = en.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "md" else { continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let rel = PathUtilities.relativePath(of: url.path, in: corpusDir.path)
            let dest = snapshotRoot.appendingPathComponent(rel)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: url, to: dest)
            let (bytes, hex) = try sha256File(dest)
            frozen.append(FrozenFile(path: rel, bytes: bytes, sha256: hex))
        }
        frozen.sort { $0.path < $1.path }
        return frozen
    }

    private func validateLabeledFilesExist(manifest: RubricManifest, snapshotRoot: URL) throws {
        var wanted = Set<String>()
        for q in manifest.queries {
            if let p = q.primary_file { wanted.insert(p) }
            for f in q.relevant_files { wanted.insert(f) }
        }
        let missing = wanted.filter { !FileManager.default.fileExists(atPath: snapshotRoot.appendingPathComponent($0).path) }
        guard missing.isEmpty else {
            throw E10HarnessError("labeled files missing from frozen snapshot: \(missing.sorted().joined(separator: ", "))")
        }
    }

    private func normalizationSizes(for files: [FrozenFile], snapshotRoot: URL) throws -> Normalization {
        var perFile: [NormalizationFile] = []
        var totalRaw = 0, totalNorm = 0
        for f in files {
            let content = (try? String(contentsOf: snapshotRoot.appendingPathComponent(f.path), encoding: .utf8)) ?? ""
            let raw = content.count
            let norm = MarkdownTextNormalizer.normalize(content).count   // public static (agreed)
            perFile.append(NormalizationFile(path: f.path, raw_chars: raw, normalized_chars: norm,
                                             reduction_ratio: raw > 0 ? 1 - Double(norm) / Double(raw) : 0))
            totalRaw += raw; totalNorm += norm
        }
        perFile.sort { $0.path < $1.path }
        return Normalization(per_file: perFile, total_raw_chars: totalRaw, total_normalized_chars: totalNorm,
                             total_reduction_ratio: totalRaw > 0 ? 1 - Double(totalNorm) / Double(totalRaw) : 0)
    }

    private func hashDirectoryFiles(_ dir: URL) throws -> [FrozenFile] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out: [FrozenFile] = []
        while let u = en.nextObject() as? URL {
            guard (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let (bytes, hex) = try sha256File(u)
            out.append(FrozenFile(path: PathUtilities.relativePath(of: u.path, in: dir.path), bytes: bytes, sha256: hex))
        }
        out.sort { $0.path < $1.path }
        return out
    }

    private func buildIdentity() -> BuildIdentity {
        #if DEBUG
        let config = "debug"
        #else
        let config = "release"
        #endif
        let repo = Self.repoRoot()
        let head = runCommand("/usr/bin/git", ["rev-parse", "HEAD"], cwd: repo)
        // `-uno`: ignore untracked files (e.g. an in-repo output dir) so the
        // flag reflects the reviewed SOURCE tree, not run artifacts.
        let dirty = runCommand("/usr/bin/git", ["status", "--porcelain", "-uno"], cwd: repo).map { !$0.isEmpty }
        let resolved = repo.appendingPathComponent("Package.resolved")
        let resolvedSHA = FileManager.default.fileExists(atPath: resolved.path) ? (try? sha256File(resolved).hex) : nil
        return BuildIdentity(
            configuration: config,
            os_version: ProcessInfo.processInfo.operatingSystemVersionString,
            active_processor_count: ProcessInfo.processInfo.activeProcessorCount,
            host_name: ProcessInfo.processInfo.hostName,
            swift_version: runCommand("/usr/bin/env", ["swift", "--version"]),
            git_head: head, git_dirty: dirty, package_resolved_sha256: resolvedSHA)
    }

    /// Best-effort subprocess capture (nil on any failure or non-zero exit).
    private func runCommand(_ launchPath: String, _ args: [String], cwd: URL? = nil) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Audit helpers

    /// Advisory source-range text for a match: the source lines the chunk
    /// spans (a SUPERSET of the embedded chunk), or the whole file for a
    /// whole-document chunk. Never persisted; used only to compute booleans.
    private func reconstructSourceRange(primary: String, match: SearchResult, snapshotRoot: URL,
                                        cache: inout [String: [String]]) -> String {
        let url = snapshotRoot.appendingPathComponent(primary)
        let lines: [String]
        if let cached = cache[primary] { lines = cached }
        else { lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").components(separatedBy: "\n"); cache[primary] = lines }
        guard !lines.isEmpty else { return "" }
        if let start = match.lineStart, let end = match.lineEnd {
            let lo = max(0, start - 1), hi = min(lines.count, max(lo + 1, end))
            return lines[lo..<hi].joined(separator: "\n")
        }
        return lines.joined(separator: "\n")   // whole-document chunk
    }

    private func matches(_ c: RubricManifest.Criterion, in haystack: String) -> Bool {
        guard !haystack.isEmpty else { return false }
        let ci = !(c.case_sensitive ?? false)
        switch c.type {
        case "contains":
            return haystack.range(of: c.value, options: ci ? [.caseInsensitive] : []) != nil
        case "regex":
            guard let re = try? NSRegularExpression(pattern: c.value, options: ci ? [.caseInsensitive] : []) else { return false }
            return re.firstMatch(in: haystack, range: NSRange(haystack.startIndex..., in: haystack)) != nil
        default:
            return false
        }
    }

    // MARK: - Comparison + summary

    private func buildComparison(manifest: RubricManifest, perArm: [String: [String: QueryResult]],
                                 arms: [ArmSummary]) -> Comparison {
        let keys = manifest.arms.map { $0.key }
        var rows: [ComparisonRow] = []
        for q in manifest.queries {
            var byArm: [String: ComparisonCell] = [:]
            for k in keys {
                if let r = perArm[k]?[q.id] {
                    byArm[k] = ComparisonCell(file_rank: r.file_rank, reciprocal_rank: r.reciprocal_rank,
                                              all_criteria_met: r.primary_audit?.all_criteria_met,
                                              top_file: r.groups.first?.file, top_score: r.groups.first?.best_score)
                }
            }
            rows.append(ComparisonRow(id: q.id, is_no_answer: q.primary_file == nil, arms: byArm))
        }
        return Comparison(arms: keys, per_query: rows,
                          aggregate: Dictionary(uniqueKeysWithValues: arms.map { ($0.arm, $0.metrics) }))
    }

    private func writeSummaryMarkdown(frozen: FrozenInputManifest, arms: [ArmSummary],
                                      comparison: Comparison, to url: URL) throws {
        var s = "# E10 Markdown-extraction retrieval benchmark\n\n"
        s += "Run identity: `\(frozen.run_identity)`  \nFrozen at: \(frozen.frozen_at)\n\n"
        s += "Corpus: `\(frozen.corpus_source)` — \(frozen.file_count) Markdown file(s). "
        s += "Manifest sha256 `\(frozen.query_manifest_sha256.prefix(12))…` (\(frozen.query_count) queries). "
        s += "Model files hashed: \(frozen.model_files.count). Build: \(frozen.build.configuration).\n\n"
        s += "Settings: `\(frozen.settings.profile_identity)`, chunk \(frozen.settings.chunk_chars)/\(frozen.settings.chunk_overlap), "
        s += "concurrency \(frozen.settings.concurrency), batch \(frozen.settings.batch_size), bucket \(frozen.settings.bucket_width).\n\n"

        s += "## Aggregate (answered queries only)\n\n"
        s += "| arm | rank1 | top3 | top5 | MRR | passage-all-met | chunks | index s | search s | RSS after |\n"
        s += "|---|---|---|---|---|---|---|---|---|---|\n"
        for a in arms {
            s += "| \(a.arm) | \(pct(a.metrics.rank1_rate)) | \(pct(a.metrics.top3_rate)) | \(pct(a.metrics.top5_rate)) | "
            s += "\(fmt3(a.metrics.mean_reciprocal_rank)) | \(pct(a.metrics.passage_all_met_rate)) | \(a.total_chunks) | "
            s += "\(fmt2(a.index_seconds)) | \(fmt2(a.search_seconds)) | \(fmtMB(a.rss_after_index_bytes)) |\n"
        }
        s += "\n> File rank is authoritative. `passage-all-met` is an advisory, case-insensitive check of the criteria against the PRE-TOKENIZER model input (content capped at the E5 char limit, then the `passage: ` prefix). The BERT tokenizer truncates further to 512 tokens, so a match here is necessary but NOT sufficient evidence the model encoded the term; it does not gate file rank.\n\n"

        let keys = comparison.arms
        s += "## Per-query file rank (answered)\n\n| query | " + keys.map { "\($0) rank" }.joined(separator: " | ") + " |\n"
        s += "|---|" + keys.map { _ in "---" }.joined(separator: "|") + "|\n"
        for row in comparison.per_query where !row.is_no_answer {
            let cells = keys.map { k -> String in row.arms[k]?.file_rank.map(String.init) ?? "—" }
            s += "| \(row.id) | " + cells.joined(separator: " | ") + " |\n"
        }
        s += "\n## No-answer probes (top file / score; no cutoff assumed)\n\n| query | " + keys.map { "\($0) top / score" }.joined(separator: " | ") + " |\n"
        s += "|---|" + keys.map { _ in "---" }.joined(separator: "|") + "|\n"
        for row in comparison.per_query where row.is_no_answer {
            let cells = keys.map { k -> String in
                guard let c = row.arms[k] else { return "—" }
                let f = c.top_file.map { ($0 as NSString).lastPathComponent } ?? "—"
                return "\(f) / \(fmt3(c.top_score ?? 0))"
            }
            s += "| \(row.id) | " + cells.joined(separator: " | ") + " |\n"
        }
        s += "\nSee `comparison.json`, per-arm `arm-summary.json`, and per-query `<arm>/q*.json` (full ordered groups) for detail.\n"
        try s.data(using: .utf8)!.write(to: url)
    }

    // MARK: - Directory / path helpers

    private func prepareOutputDirectory(_ raw: String?) throws -> URL {
        let fm = FileManager.default
        if let raw, !raw.isEmpty {
            let url = URL(fileURLWithPath: raw, isDirectory: true)
            if fm.fileExists(atPath: url.path) {
                let contents = ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).filter { $0 != ".DS_Store" }
                if !contents.isEmpty {
                    throw E10HarnessError("REFUSING to reuse non-empty output directory \(url.path). Point \(Env.outputDirectory) at a fresh path; interrupted runs are rebuilt, not resumed.")
                }
            } else {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            }
            return url
        }
        let url = fm.temporaryDirectory.appendingPathComponent("vec-e10-out-\(UUID().uuidString)")
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return resolvedURL(url.path)
    }

    private func makeScratchRoot(_ raw: String?) throws -> URL {
        let fm = FileManager.default
        let base: URL
        if let raw, !raw.isEmpty {
            base = URL(fileURLWithPath: raw, isDirectory: true)
            try fm.createDirectory(at: base, withIntermediateDirectories: true)   // we own only the child
        } else {
            base = fm.temporaryDirectory
        }
        let child = E10Scratch.uniqueChild(under: base)
        try fm.createDirectory(at: child, withIntermediateDirectories: true)
        return resolvedURL(child.path)
    }

    private func locateManifest(_ env: [String: String]) throws -> URL {
        if let p = env[Env.manifest], !p.isEmpty { return URL(fileURLWithPath: p) }
        let url = Self.repoRoot().appendingPathComponent("experiments/E10-markdown-extraction/queries/rubric-queries.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw E10HarnessError("Query manifest not found at \(url.path); set \(Env.manifest).")
        }
        return url
    }

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private func relativeToRepo(_ url: URL) -> String { PathUtilities.relativePath(of: url.path, in: Self.repoRoot().path) }

    private func resolvedURL(_ path: String) -> URL {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(path, &buf) != nil { return URL(fileURLWithPath: String(cString: buf)) }
        return URL(fileURLWithPath: path)
    }

    // MARK: - Small utilities

    private func computeRunIdentity(files: [FrozenFile], modelFiles: [FrozenFile], manifestSHA: String, settings: FrozenSettings) -> String {
        var parts = files.map { "corpus:\($0.path):\($0.sha256)" }
        parts += modelFiles.map { "model:\($0.path):\($0.sha256)" }
        parts.append("manifest:\(manifestSHA)")
        // Encode ALL settings via sorted-key JSON so every field (dimension,
        // compute_policy, search/coalesce/fetch limits, batch/bucket, …) is
        // bound into the identity — not a hand-picked subset.
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let settingsJSON = (try? enc.encode(settings)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        parts.append("settings:\(settingsJSON)")
        return sha256Hex(Data(parts.sorted().joined(separator: "\n").utf8))
    }

    private func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func sha256File(_ url: URL) throws -> (bytes: Int, hex: String) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var total = 0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk); total += chunk.count
        }
        return (total, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try enc.encode(value).write(to: url)
    }

    private func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { p in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), p, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.resident_size : 0
    }

    private func logLine(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
    private static func elapsed(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000_000
    }
    private func fmt2(_ d: Double) -> String { String(format: "%.2f", d) }
    private func fmt3(_ d: Double) -> String { String(format: "%.3f", d) }
    private func pct(_ d: Double) -> String { String(format: "%.0f%%", d * 100) }
    private func fmtMB(_ b: UInt64) -> String { String(format: "%.0f MB", Double(b) / 1_048_576) }
}

// MARK: - Cheap, always-on validation (NOT behind the heavy gate)

/// Guards against the manifest/enum drift that would otherwise abort the
/// second arm mid-run, and against the scratch-ownership bug. Runs in a
/// normal `swift test` with no model, corpus, or env gate.
final class MarkdownRetrievalManifestTests: XCTestCase {

    private static func committedManifestURL() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("experiments/E10-markdown-extraction/queries/rubric-queries.json")
    }

    func testCommittedManifestPreflights() throws {
        let data = try Data(contentsOf: Self.committedManifestURL())
        let manifest = try JSONDecoder().decode(RubricManifest.self, from: data)
        XCTAssertNoThrow(try E10Preflight.validate(manifest), "committed manifest must preflight")
        for a in manifest.arms {
            XCTAssertNotNil(TextExtractionMode(rawValue: a.text_extraction),
                            "arm '\(a.key)' text_extraction '\(a.text_extraction)' must map to a TextExtractionMode")
        }
        XCTAssertEqual(Set(manifest.queries.map { $0.id }).count, manifest.queries.count, "query ids must be unique")
        XCTAssertFalse(manifest.queries.isEmpty)
    }

    func testScratchChildIsOwnedNotCaller() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("vec-e10-owntest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let child = E10Scratch.uniqueChild(under: base)
        XCTAssertNotEqual(child.standardizedFileURL, base.standardizedFileURL, "scratch child must differ from the caller dir")
        XCTAssertEqual(child.deletingLastPathComponent().standardizedFileURL, base.standardizedFileURL,
                       "scratch child must live UNDER the caller dir so teardown never deletes the caller dir")
    }
}

// MARK: - Preflight + scratch (file-scope so the cheap tests can exercise them)

enum E10Preflight {
    static func validate(_ m: RubricManifest) throws {
        guard !m.arms.isEmpty else { throw E10HarnessError("manifest has no arms") }
        var armKeys = Set<String>()
        for a in m.arms {
            guard TextExtractionMode(rawValue: a.text_extraction) != nil else {
                throw E10HarnessError("arm '\(a.key)': text_extraction '\(a.text_extraction)' is not a valid TextExtractionMode (valid: \(TextExtractionMode.allCases.map { $0.rawValue }.joined(separator: ", ")))")
            }
            guard isSafeKey(a.key) else { throw E10HarnessError("arm key '\(a.key)' is not filename-safe") }
            guard armKeys.insert(a.key).inserted else { throw E10HarnessError("duplicate arm key '\(a.key)'") }
        }
        guard !m.queries.isEmpty else { throw E10HarnessError("manifest has no queries") }
        var ids = Set<String>()
        for q in m.queries {
            guard isSafeKey(q.id) else { throw E10HarnessError("query id '\(q.id)' is not filename-safe") }
            guard ids.insert(q.id).inserted else { throw E10HarnessError("duplicate query id '\(q.id)'") }
            if q.primary_file == nil {
                guard q.relevant_files.isEmpty else { throw E10HarnessError("query '\(q.id)': no-answer query must have empty relevant_files") }
            } else if let p = q.primary_file, !q.relevant_files.contains(p) {
                throw E10HarnessError("query '\(q.id)': primary_file must be listed in relevant_files")
            }
        }
    }
    static func isSafeKey(_ s: String) -> Bool {
        !s.isEmpty && s != "." && s != ".." && s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
    }
}

enum E10Scratch {
    /// A unique child directory under `base`. The harness owns and deletes
    /// only this child, never `base` itself.
    static func uniqueChild(under base: URL) -> URL {
        base.appendingPathComponent("vec-e10-scratch-\(UUID().uuidString)", isDirectory: true)
    }
}

// MARK: - Manifest decoding

struct RubricManifest: Codable {
    struct Corpus: Codable { let scope: String?; let expected_markdown_files: Int? }
    struct Arm: Codable { let key: String; let text_extraction: String; let label: String? }
    struct Criterion: Codable { let type: String; let value: String; let case_sensitive: Bool?; let note: String? }
    struct Query: Codable {
        let id: String; let text: String; let categories: [String]
        let primary_file: String?; let relevant_files: [String]
        let passage_criteria: [Criterion]; let rationale: String?
    }
    let corpus: Corpus?
    let arms: [Arm]
    let queries: [Query]
}

// MARK: - Archive models

struct FrozenFile: Codable { let path: String; let bytes: Int; let sha256: String }

struct FrozenSettings: Codable {
    let profile_identity: String; let embedder: String; let dimension: Int
    let chunk_chars: Int; let chunk_overlap: Int; let concurrency: Int
    let batch_size: Int; let bucket_width: Int; let compute_policy: String
    let search_limit: Int; let coalesce_limit: Int; let raw_fetch_limit: Int
}

struct BuildIdentity: Codable {
    let configuration: String; let os_version: String; let active_processor_count: Int; let host_name: String
    let swift_version: String?; let git_head: String?; let git_dirty: Bool?; let package_resolved_sha256: String?
}

struct NormalizationFile: Codable { let path: String; let raw_chars: Int; let normalized_chars: Int; let reduction_ratio: Double }
struct Normalization: Codable {
    let per_file: [NormalizationFile]; let total_raw_chars: Int; let total_normalized_chars: Int; let total_reduction_ratio: Double
}

struct FrozenInputManifest: Codable {
    let experiment: String; let run_identity: String; let frozen_at: String
    let corpus_source: String; let corpus_scope: String
    let files: [FrozenFile]; let file_count: Int
    let query_manifest_path: String; let query_manifest_sha256: String; let query_count: Int
    let model_directory: String; let model_revision: String?; let model_files: [FrozenFile]
    let build: BuildIdentity; let settings: FrozenSettings; let normalization: Normalization
}

struct ArchivedMatch: Codable {
    let score: Double; let distance: Double; let chunk_type: String
    let line_start: Int?; let line_end: Int?; let chunk_ordinal: Int?
}
struct ArchivedGroup: Codable {
    let rank: Int; let file: String; let best_score: Double; let match_count: Int; let matches: [ArchivedMatch]
}

struct CriterionResult: Codable {
    let type: String; let value: String
    /// Matched in the PRE-TOKENIZER model input (content capped at the E5
    /// char limit + "passage: " prefix). The tokenizer truncates further to
    /// 512 tokens, so this is necessary-but-not-sufficient evidence.
    let matched_in_pre_tokenizer_input: Bool
    /// Matched in the chunk's source line range (a superset). Advisory.
    let matched_in_source_range: Bool
}
struct PrimaryAudit: Codable {
    let file_rank: Int; let best_score: Double; let distance: Double; let chunk_type: String
    let line_start: Int?; let line_end: Int?; let chunk_ordinal: Int?
    /// Length of the pre-tokenizer input string audited (content + prefix).
    let input_chars: Int
    let criteria: [CriterionResult]; let all_criteria_met: Bool
}

struct QueryResult: Codable {
    let arm: String; let id: String; let text: String; let categories: [String]
    let is_no_answer: Bool; let primary_file: String?; let relevant_files: [String]
    let file_rank: Int?; let hit_at_1: Bool; let hit_at_3: Bool; let hit_at_5: Bool
    let reciprocal_rank: Double; let overfetch_distinct_files: Int; let search_seconds: Double
    let groups: [ArchivedGroup]; let primary_audit: PrimaryAudit?
}

struct PerFileChunks: Codable { let path: String; let chunks: Int }
struct ArmMetrics: Codable {
    let answered_queries: Int; let rank1_rate: Double; let top3_rate: Double; let top5_rate: Double
    let mean_reciprocal_rank: Double; let passage_all_met_rate: Double
}
struct NoAnswerProbe: Codable { let id: String; let top_file: String?; let top_score: Double? }
struct ArmSummary: Codable {
    let arm: String; let text_extraction: String; let file_count: Int; let indexed_count: Int
    let total_chunks: Int; let per_file_chunks: [PerFileChunks]
    let index_seconds: Double; let extract_seconds: Double; let embed_span_seconds: Double
    let db_seconds: Double; let search_seconds: Double
    let rss_before_index_bytes: UInt64; let rss_after_index_bytes: UInt64
    let metrics: ArmMetrics; let no_answer_probes: [NoAnswerProbe]
}

struct ComparisonCell: Codable {
    let file_rank: Int?; let reciprocal_rank: Double; let all_criteria_met: Bool?
    let top_file: String?; let top_score: Double?
}
struct ComparisonRow: Codable { let id: String; let is_no_answer: Bool; let arms: [String: ComparisonCell] }
struct Comparison: Codable { let arms: [String]; let per_query: [ComparisonRow]; let aggregate: [String: ArmMetrics] }

/// Hard-failure error for setup problems that must abort the benchmark.
struct E10HarnessError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
