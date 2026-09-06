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
/// `e5-base@1200/0`, identical chunk geometry, and identical concurrency.
/// Only the text-extraction mode differs; no format-specific database
/// behavior is introduced.
///
/// This is a HEAVY, opt-in benchmark. It is skipped unless
/// `VEC_E10_BENCHMARK=1`. It exercises the real model and the real
/// indexing/search pipeline, so it needs the pinned model bundle on disk
/// (the default download target `~/Documents/huggingface` is outside the
/// harness's writable roots, so we NEVER let the embedder download — we
/// load the pinned bundle from `VEC_MARKDOWN_MODEL_DIRECTORY`).
///
///     VEC_E10_BENCHMARK=1 \
///     VEC_MARKDOWN_MODEL_DIRECTORY=/private/tmp/vec-e10-model/<rev> \
///     swift test --disable-sandbox \
///       --filter VecKitTests.MarkdownRetrievalExperimentTests
///
/// See `experiments/E10-markdown-extraction/harness-notes.md` for the full
/// environment contract, the freeze/resume policy, and the archive layout.
///
/// Design invariants (see the manager's integration notes):
///   * FREEZE BEFORE RANKING. The corpus is copied (Markdown only) into a
///     scratch snapshot and every input is hashed into
///     `frozen-input-manifest.json` BEFORE any indexing or search runs.
///     The query labels are committed (fixed) beforehand in
///     `queries/rubric-queries.json`.
///   * NO AUTO-RESUME. The runner refuses to reuse a non-empty output
///     directory. Each arm is rebuilt into a fresh database; partial
///     output from an interrupted run is inspectable but never trusted.
///   * SNAPSHOT BODIES STAY SCRATCH-ONLY. The snapshot lives under a
///     scratch directory that is deleted on teardown; no corpus body is
///     ever written into the committed archive (only hashes, counts,
///     line ranges, and metric results).
final class MarkdownRetrievalExperimentTests: XCTestCase {

    // MARK: - Environment contract

    private enum Env {
        static let enable = "VEC_E10_BENCHMARK"
        static let modelDirectory = "VEC_MARKDOWN_MODEL_DIRECTORY"
        static let modelRevision = "VEC_MARKDOWN_MODEL_REVISION"
        static let corpusDirectory = "VEC_MARKDOWN_CORPUS_DIRECTORY"
        static let outputDirectory = "VEC_E10_OUTPUT_DIRECTORY"
        static let scratchDirectory = "VEC_E10_SCRATCH_DIRECTORY"
        static let concurrency = "VEC_E10_CONCURRENCY"
        static let persistPreviews = "VEC_E10_PERSIST_PREVIEWS"
    }

    private static let defaultCorpus = "/tmp/LinksDatabase"
    private static let profileIdentity = "e5-base@1200/0"
    private static let chunkChars = 1200
    private static let chunkOverlap = 0
    private static let coalesceLimit = 10
    private static let rawFetchLimit = 50

    private var scratchRoot: URL!

    override func tearDown() {
        // Scratch (snapshot + throwaway DBs) is always removed — snapshot
        // bodies must never outlive the run. The output/archive directory
        // is intentionally left in place.
        if let scratchRoot {
            try? FileManager.default.removeItem(at: scratchRoot)
        }
        super.tearDown()
    }

    // MARK: - Test

    func testMarkdownExtractionRetrievalBenchmark() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment[Env.enable] != nil,
            "Heavy opt-in benchmark — set \(Env.enable)=1 to run (needs the pinned E5 model; see harness-notes.md)."
        )

        let env = ProcessInfo.processInfo.environment

        // --- Model directory: REQUIRED when enabled; FAIL (not skip) if absent. ---
        guard let modelDirRaw = env[Env.modelDirectory], !modelDirRaw.isEmpty else {
            XCTFail("\(Env.enable) is set but \(Env.modelDirectory) is not. The benchmark must not download the model to a non-writable path; point \(Env.modelDirectory) at the pinned e5-base-v2 bundle.")
            return
        }
        let modelDir = URL(fileURLWithPath: modelDirRaw, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: modelDir.path, isDirectory: &isDir), isDir.boolValue else {
            XCTFail("\(Env.modelDirectory) = \(modelDirRaw) is not an existing directory.")
            return
        }
        let modelRevision = env[Env.modelRevision]

        // --- Corpus root (default /tmp/LinksDatabase). ---
        let corpusDir = resolvedURL(env[Env.corpusDirectory] ?? Self.defaultCorpus)
        guard FileManager.default.fileExists(atPath: corpusDir.path) else {
            XCTFail("Corpus directory \(corpusDir.path) does not exist (override with \(Env.corpusDirectory)).")
            return
        }

        // --- Concurrency: shared by both arms (does not affect vectors). ---
        let concurrency = env[Env.concurrency].flatMap { Int($0) } ?? IndexingPipeline.defaultConcurrency
        let persistPreviews = env[Env.persistPreviews] == "1"

        // --- Output/archive directory: refuse to reuse a non-empty dir. ---
        let outputDir = try prepareOutputDirectory(env[Env.outputDirectory])
        logLine("[e10] output/archive directory: \(outputDir.path)")
        if persistPreviews {
            logLine("[e10] WARNING: \(Env.persistPreviews)=1 — previews/snippets will be written; DO NOT commit this output.")
        }

        // --- Scratch (snapshot + throwaway DBs), always fresh, deleted on teardown. ---
        scratchRoot = try makeScratchRoot(env[Env.scratchDirectory])
        let snapshotRoot = scratchRoot.appendingPathComponent("snapshot", isDirectory: true)

        // --- Load the fixed query manifest. ---
        let manifestURL = try locateManifest(env)
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(RubricManifest.self, from: manifestData)
        let manifestSHA = sha256Hex(manifestData)

        // ============================================================
        // FREEZE PHASE — everything below runs BEFORE any ranking.
        // ============================================================
        let frozenFiles = try freezeMarkdownSnapshot(from: corpusDir, to: snapshotRoot)
        logLine("[e10] froze \(frozenFiles.count) Markdown file(s) into snapshot")
        if let expected = manifest.corpus?.expected_markdown_files, frozenFiles.count != expected {
            logLine("[e10] NOTE: snapshot file count \(frozenFiles.count) != manifest expected \(expected). Corpus may have drifted (operator-triggered) — recording actual counts and continuing.")
        }
        XCTAssertGreaterThan(frozenFiles.count, 0, "Snapshot must contain at least one Markdown file")

        // Normalization sizes: raw vs normalized char counts per file
        // (arm-independent corpus facts; cheap — no splitter cost).
        let normalization = try normalizationSizes(for: frozenFiles, snapshotRoot: snapshotRoot)

        let settings = FrozenSettings(
            profile_identity: Self.profileIdentity,
            embedder: "e5-base-v2",
            dimension: 768,
            chunk_chars: Self.chunkChars,
            chunk_overlap: Self.chunkOverlap,
            concurrency: concurrency,
            coalesce_limit: Self.coalesceLimit,
            raw_fetch_limit: Self.rawFetchLimit
        )

        let runIdentity = computeRunIdentity(
            files: frozenFiles,
            manifestSHA: manifestSHA,
            modelRevision: modelRevision,
            settings: settings
        )

        let frozen = FrozenInputManifest(
            experiment: "E10-markdown-extraction",
            run_identity: runIdentity,
            frozen_at: ISO8601DateFormatter().string(from: Date()),
            corpus_source: corpusDir.path,
            corpus_scope: manifest.corpus?.scope ?? "Markdown-only (*.md); no JSON/OCR assets.",
            files: frozenFiles,
            file_count: frozenFiles.count,
            query_manifest_path: relativeToRepo(manifestURL),
            query_manifest_sha256: manifestSHA,
            query_count: manifest.queries.count,
            model_directory: modelDir.path,
            model_revision: modelRevision,
            settings: settings,
            normalization: normalization
        )
        try writeJSON(frozen, to: outputDir.appendingPathComponent("frozen-input-manifest.json"))
        logLine("[e10] freeze complete — run_identity=\(runIdentity). Ranking begins now.")

        // ============================================================
        // ARMS — each rebuilt into a FRESH database.
        // ============================================================
        var armSummaries: [ArmSummary] = []
        var perArmQueryResults: [String: [String: QueryResult]] = [:]

        for arm in manifest.arms {
            guard let mode = TextExtractionMode(rawValue: arm.text_extraction) else {
                XCTFail("Unknown text-extraction mode '\(arm.text_extraction)' in manifest arm '\(arm.key)'.")
                return
            }
            logLine("[e10] === arm '\(arm.key)' (textExtraction=\(mode.rawValue)) ===")

            let (summary, results) = try await runArm(
                arm: arm,
                mode: mode,
                snapshotRoot: snapshotRoot,
                modelDir: modelDir,
                concurrency: concurrency,
                manifest: manifest,
                outputDir: outputDir,
                persistPreviews: persistPreviews
            )
            armSummaries.append(summary)
            perArmQueryResults[arm.key] = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0) })

            // Structural assertions only — NOT ranking quality.
            XCTAssertEqual(summary.file_count, frozenFiles.count,
                           "arm \(arm.key): every snapshot file should be indexed")
            XCTAssertGreaterThan(summary.total_chunks, 0,
                                 "arm \(arm.key): indexing must produce chunks")
            XCTAssertEqual(results.count, manifest.queries.count,
                           "arm \(arm.key): every query should be evaluated")
        }

        // ============================================================
        // COMPARISON + human-readable summary.
        // ============================================================
        let comparison = buildComparison(manifest: manifest, perArm: perArmQueryResults, arms: armSummaries)
        try writeJSON(comparison, to: outputDir.appendingPathComponent("comparison.json"))
        try writeSummaryMarkdown(
            manifest: manifest,
            frozen: frozen,
            arms: armSummaries,
            comparison: comparison,
            to: outputDir.appendingPathComponent("summary.md")
        )

        // Final structural checks that the archive is complete.
        for name in ["frozen-input-manifest.json", "comparison.json", "summary.md"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: outputDir.appendingPathComponent(name).path),
                          "archive file \(name) must exist")
        }
        logLine("[e10] done. Archive at \(outputDir.path)")
    }

    // MARK: - One arm

    private func runArm(
        arm: RubricManifest.Arm,
        mode: TextExtractionMode,
        snapshotRoot: URL,
        modelDir: URL,
        concurrency: Int,
        manifest: RubricManifest,
        outputDir: URL,
        persistPreviews: Bool
    ) async throws -> (ArmSummary, [QueryResult]) {

        let armOut = outputDir.appendingPathComponent(arm.key, isDirectory: true)
        try FileManager.default.createDirectory(at: armOut, withIntermediateDirectories: true)

        // Fresh DB for this arm.
        let dbDir = scratchRoot.appendingPathComponent("db-\(arm.key)", isDirectory: true)

        // Profile built via the PUBLIC IndexingProfile initializer + an E5
        // factory closure bound to the pinned local model directory. We do
        // NOT use IndexingProfileFactory.make here because its e5-base
        // factory constructs `E5BaseEmbedder(computePolicy:)`, which would
        // trigger a HuggingFace download to a non-writable path.
        let e5Factory: @Sendable () -> any Embedder = { E5BaseEmbedder(modelDirectory: modelDir) }
        let profile = IndexingProfile(
            identity: Self.profileIdentity,
            embedder: e5Factory(),
            embedderFactory: e5Factory,
            splitter: RecursiveCharacterSplitter(chunkSize: Self.chunkChars, chunkOverlap: Self.chunkOverlap),
            chunkSize: Self.chunkChars,
            chunkOverlap: Self.chunkOverlap,
            isBuiltIn: true
        )

        let db = VectorDatabase(databaseDirectory: dbDir, sourceDirectory: snapshotRoot, dimension: profile.embedder.dimension)
        try await db.initialize()

        let scanner = FileScanner(directory: snapshotRoot)
        let files = try scanner.scan()
        let workItems = files.map { (file: $0, label: "Added") }

        let extractor = TextExtractor(splitter: profile.splitter, textExtraction: mode)
        let pipeline = IndexingPipeline(concurrency: concurrency, profile: profile)

        // ---- Index (timed, with RSS around the call). ----
        let rssBefore = residentBytes()
        let indexStart = DispatchTime.now()
        let (indexResults, stats) = try await pipeline.run(
            workItems: workItems,
            extractor: extractor,
            database: db
        )
        let indexSeconds = Self.elapsed(since: indexStart)
        let rssAfter = residentBytes()

        let indexedCount = indexResults.filter { if case .indexed = $0 { return true } else { return false } }.count
        let totalChunks = try await db.totalChunkCount()

        var perFileChunks: [PerFileChunks] = []
        for file in files {
            let c = try await db.chunkCount(filePath: file.relativePath)
            perFileChunks.append(PerFileChunks(path: file.relativePath, chunks: c))
        }
        perFileChunks.sort { $0.path < $1.path }

        logLine("[e10] arm \(arm.key): indexed=\(indexedCount)/\(files.count) chunks=\(totalChunks) indexWall=\(String(format: "%.2f", indexSeconds))s extract=\(String(format: "%.2f", stats.extractSeconds))s embedSpan=\(String(format: "%.2f", stats.embedSeconds))s db=\(String(format: "%.2f", stats.dbSeconds))s rss=\(fmtMB(rssAfter))")

        // ---- Search every query (persist each result immediately). ----
        var results: [QueryResult] = []
        var lineCache: [String: [String]] = [:]
        var contentCache: [String: String] = [:]
        let searchStart = DispatchTime.now()

        for q in manifest.queries {
            let qStart = DispatchTime.now()
            let queryVec = try await profile.embedder.embedQuery(q.text)
            XCTAssertFalse(queryVec.isEmpty, "arm \(arm.key) \(q.id): empty query embedding")

            let raw = try await db.search(embedding: queryVec, limit: Self.rawFetchLimit)
            let groups = SearchResultCoalescer.coalesce(raw, limit: Self.coalesceLimit)
            let searchSeconds = Self.elapsed(since: qStart)

            // Overfetch diversity: distinct files in the pre-coalesce pool.
            let distinctInPool = Set(raw.map { $0.filePath }).count

            // Top file groups (path + score + match count) for audit / no-answer.
            let topGroups = groups.prefix(5).map {
                TopGroup(file: $0.filePath, best_score: $0.bestScore, match_count: $0.matches.count)
            }

            let isNoAnswer = (q.primary_file == nil)
            var fileRank: Int? = nil
            var reciprocal = 0.0
            var audit: PrimaryAudit? = nil

            if let primary = q.primary_file {
                if let idx = groups.firstIndex(where: { $0.filePath == primary }) {
                    fileRank = idx + 1
                    reciprocal = 1.0 / Double(idx + 1)

                    // Passage audit on the best match within the primary file.
                    let group = groups[idx]
                    let best = group.matches.first!
                    let ordinals = try await db.chunkOrdinals(filePath: primary)
                    let ordinal = ordinals[best.chunkId]

                    let (passage, passageSource) = reconstructPassage(
                        primary: primary, match: best,
                        snapshotRoot: snapshotRoot,
                        lineCache: &lineCache, contentCache: &contentCache
                    )

                    var criteriaResults: [CriterionResult] = []
                    for c in q.passage_criteria {
                        let matchedPassage = matches(criterion: c, in: passage)
                        let previewHay = best.contentPreview ?? ""
                        let matchedPreview = matches(criterion: c, in: previewHay)
                        var where_: [String] = []
                        if matchedPassage { where_.append(passageSource) }
                        if matchedPreview { where_.append("preview") }
                        criteriaResults.append(CriterionResult(
                            type: c.type, value: c.value,
                            matched: matchedPassage || matchedPreview,
                            matched_in: where_
                        ))
                    }
                    let allMet = !criteriaResults.isEmpty && criteriaResults.allSatisfy { $0.matched }

                    audit = PrimaryAudit(
                        file_rank: idx + 1,
                        best_score: group.bestScore,
                        distance: best.distance,
                        chunk_type: best.chunkType.rawValue,
                        line_start: best.lineStart,
                        line_end: best.lineEnd,
                        chunk_ordinal: ordinal,
                        passage_source: passageSource,
                        criteria: criteriaResults,
                        all_criteria_met: allMet,
                        content_preview: persistPreviews ? best.contentPreview : nil,
                        reconstructed_passage: persistPreviews ? String(passage.prefix(600)) : nil
                    )
                }
            }

            let result = QueryResult(
                arm: arm.key,
                id: q.id,
                text: q.text,
                categories: q.categories,
                is_no_answer: isNoAnswer,
                primary_file: q.primary_file,
                relevant_files: q.relevant_files,
                file_rank: fileRank,
                hit_at_1: fileRank == 1,
                hit_at_3: (fileRank.map { $0 <= 3 }) ?? false,
                hit_at_5: (fileRank.map { $0 <= 5 }) ?? false,
                reciprocal_rank: reciprocal,
                overfetch_distinct_files: distinctInPool,
                search_seconds: searchSeconds,
                top_groups: topGroups,
                primary_audit: audit
            )
            results.append(result)

            // Persist this query immediately so an interrupted run leaves
            // inspectable (but never auto-trusted) partial output.
            try writeJSON(result, to: armOut.appendingPathComponent("\(q.id).json"))
        }
        let searchSecondsTotal = Self.elapsed(since: searchStart)

        // ---- Arm-level metric roll-up over ANSWERED queries. ----
        let answered = results.filter { !$0.is_no_answer }
        let answeredN = max(answered.count, 1)
        let metrics = ArmMetrics(
            answered_queries: answered.count,
            rank1_rate: Double(answered.filter { $0.hit_at_1 }.count) / Double(answeredN),
            top3_rate: Double(answered.filter { $0.hit_at_3 }.count) / Double(answeredN),
            top5_rate: Double(answered.filter { $0.hit_at_5 }.count) / Double(answeredN),
            mean_reciprocal_rank: answered.map { $0.reciprocal_rank }.reduce(0, +) / Double(answeredN),
            passage_all_met_rate: Double(answered.filter { $0.primary_audit?.all_criteria_met == true }.count) / Double(answeredN)
        )

        let noAnswer = results.filter { $0.is_no_answer }.map {
            NoAnswerProbe(id: $0.id, top_file: $0.top_groups.first?.file, top_score: $0.top_groups.first?.best_score)
        }

        let summary = ArmSummary(
            arm: arm.key,
            text_extraction: mode.rawValue,
            file_count: files.count,
            indexed_count: indexedCount,
            total_chunks: totalChunks,
            per_file_chunks: perFileChunks,
            index_seconds: indexSeconds,
            extract_seconds: stats.extractSeconds,
            embed_span_seconds: stats.embedSeconds,
            db_seconds: stats.dbSeconds,
            search_seconds: searchSecondsTotal,
            rss_before_index_bytes: rssBefore,
            rss_after_index_bytes: rssAfter,
            metrics: metrics,
            no_answer_probes: noAnswer
        )
        try writeJSON(summary, to: armOut.appendingPathComponent("arm-summary.json"))
        return (summary, results)
    }

    // MARK: - Freeze helpers

    /// Copies every `*.md` file under `corpusDir` into `snapshotRoot`,
    /// preserving the relative directory structure, and records size + SHA256.
    private func freezeMarkdownSnapshot(from corpusDir: URL, to snapshotRoot: URL) throws -> [FrozenFile] {
        let fm = FileManager.default
        try fm.createDirectory(at: snapshotRoot, withIntermediateDirectories: true)

        var frozen: [FrozenFile] = []
        guard let enumerator = fm.enumerator(at: corpusDir, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw VecError.cannotScanDirectory(corpusDir.path)
        }
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "md" else { continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }

            let rel = PathUtilities.relativePath(of: url.path, in: corpusDir.path)
            let dest = snapshotRoot.appendingPathComponent(rel)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: url, to: dest)

            let data = try Data(contentsOf: dest)
            frozen.append(FrozenFile(path: rel, bytes: data.count, sha256: sha256Hex(data)))
        }
        frozen.sort { $0.path < $1.path }
        return frozen
    }

    /// Raw vs normalized character counts per file. Arm-independent; cheap.
    private func normalizationSizes(for files: [FrozenFile], snapshotRoot: URL) throws -> Normalization {
        var perFile: [NormalizationFile] = []
        var totalRaw = 0
        var totalNorm = 0
        for f in files {
            let url = snapshotRoot.appendingPathComponent(f.path)
            let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let rawChars = content.count
            let normChars = MarkdownTextNormalizer.normalize(content).count
            let reduction = rawChars > 0 ? 1.0 - (Double(normChars) / Double(rawChars)) : 0.0
            perFile.append(NormalizationFile(path: f.path, raw_chars: rawChars, normalized_chars: normChars, reduction_ratio: reduction))
            totalRaw += rawChars
            totalNorm += normChars
        }
        perFile.sort { $0.path < $1.path }
        let totalReduction = totalRaw > 0 ? 1.0 - (Double(totalNorm) / Double(totalRaw)) : 0.0
        return Normalization(per_file: perFile, total_raw_chars: totalRaw, total_normalized_chars: totalNorm, total_reduction_ratio: totalReduction)
    }

    // MARK: - Passage reconstruction & criteria

    /// Rebuilds the passage a match came from, in memory only (never
    /// persisted unless VEC_E10_PERSIST_PREVIEWS=1). Line ranges refer to
    /// the ORIGINAL source lines (the normalizer preserves newlines), so the
    /// snapshot file's lines are the right audit source for both arms.
    private func reconstructPassage(
        primary: String, match: SearchResult, snapshotRoot: URL,
        lineCache: inout [String: [String]], contentCache: inout [String: String]
    ) -> (String, String) {
        let url = snapshotRoot.appendingPathComponent(primary)
        if let start = match.lineStart, let end = match.lineEnd {
            let lines: [String]
            if let cached = lineCache[primary] {
                lines = cached
            } else {
                let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                lines = content.components(separatedBy: "\n")
                lineCache[primary] = lines
            }
            guard !lines.isEmpty else { return ("", "empty") }
            let lo = max(0, start - 1)
            let hi = min(lines.count, max(lo + 1, end))
            return (lines[lo..<hi].joined(separator: "\n"), "source-lines")
        } else {
            // Whole-document chunk: audit against the whole file content.
            let content: String
            if let cached = contentCache[primary] {
                content = cached
            } else {
                content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                contentCache[primary] = content
            }
            return (content, "whole-file")
        }
    }

    private func matches(criterion: RubricManifest.Criterion, in haystack: String) -> Bool {
        guard !haystack.isEmpty else { return false }
        let caseInsensitive = !(criterion.case_sensitive ?? false)
        switch criterion.type {
        case "contains":
            let opts: String.CompareOptions = caseInsensitive ? [.caseInsensitive] : []
            return haystack.range(of: criterion.value, options: opts) != nil
        case "regex":
            let opts: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
            guard let re = try? NSRegularExpression(pattern: criterion.value, options: opts) else { return false }
            let range = NSRange(haystack.startIndex..., in: haystack)
            return re.firstMatch(in: haystack, options: [], range: range) != nil
        default:
            return false
        }
    }

    // MARK: - Comparison + summary

    private func buildComparison(
        manifest: RubricManifest,
        perArm: [String: [String: QueryResult]],
        arms: [ArmSummary]
    ) -> Comparison {
        let armKeys = manifest.arms.map { $0.key }
        var perQuery: [ComparisonRow] = []
        for q in manifest.queries {
            var byArm: [String: ComparisonCell] = [:]
            for key in armKeys {
                if let r = perArm[key]?[q.id] {
                    byArm[key] = ComparisonCell(
                        file_rank: r.file_rank,
                        reciprocal_rank: r.reciprocal_rank,
                        all_criteria_met: r.primary_audit?.all_criteria_met,
                        top_file: r.top_groups.first?.file,
                        top_score: r.top_groups.first?.best_score
                    )
                }
            }
            perQuery.append(ComparisonRow(id: q.id, is_no_answer: q.primary_file == nil, arms: byArm))
        }
        let aggregate = Dictionary(uniqueKeysWithValues: arms.map { ($0.arm, $0.metrics) })
        return Comparison(arms: armKeys, per_query: perQuery, aggregate: aggregate)
    }

    private func writeSummaryMarkdown(
        manifest: RubricManifest,
        frozen: FrozenInputManifest,
        arms: [ArmSummary],
        comparison: Comparison,
        to url: URL
    ) throws {
        var s = "# E10 Markdown-extraction retrieval benchmark\n\n"
        s += "Run identity: `\(frozen.run_identity)`  \nFrozen at: \(frozen.frozen_at)\n\n"
        s += "Corpus: `\(frozen.corpus_source)` — \(frozen.file_count) Markdown file(s). "
        s += "Query manifest sha256: `\(frozen.query_manifest_sha256.prefix(12))…` (\(frozen.query_count) queries).\n\n"
        s += "Settings: `\(frozen.settings.profile_identity)`, chunk \(frozen.settings.chunk_chars)/\(frozen.settings.chunk_overlap), concurrency \(frozen.settings.concurrency).\n\n"

        s += "## Aggregate (answered queries only)\n\n"
        s += "| arm | rank1 | top3 | top5 | MRR | passage-all-met | chunks | index s | search s | RSS after |\n"
        s += "|---|---|---|---|---|---|---|---|---|---|\n"
        for a in arms {
            s += "| \(a.arm) | \(pct(a.metrics.rank1_rate)) | \(pct(a.metrics.top3_rate)) | \(pct(a.metrics.top5_rate)) | \(fmt3(a.metrics.mean_reciprocal_rank)) | \(pct(a.metrics.passage_all_met_rate)) | \(a.total_chunks) | \(fmt2(a.index_seconds)) | \(fmt2(a.search_seconds)) | \(fmtMB(a.rss_after_index_bytes)) |\n"
        }
        s += "\n> File rank is authoritative. `passage-all-met` is an advisory, case-insensitive check of the manifest's passage criteria against the retrieved passage; it does not gate file rank.\n\n"

        s += "## Per-query file rank (answered)\n\n"
        let armKeys = comparison.arms
        s += "| query | " + armKeys.map { "\($0) rank" }.joined(separator: " | ") + " |\n"
        s += "|---|" + armKeys.map { _ in "---" }.joined(separator: "|") + "|\n"
        for row in comparison.per_query where !row.is_no_answer {
            let cells = armKeys.map { row.arms[$0]?.file_rank.map(String.init) ?? "—" }
            s += "| \(row.id) | " + cells.joined(separator: " | ") + " |\n"
        }

        s += "\n## No-answer probes (top file + score; no cutoff assumed)\n\n"
        s += "| query | " + armKeys.map { "\($0) top / score" }.joined(separator: " | ") + " |\n"
        s += "|---|" + armKeys.map { _ in "---" }.joined(separator: "|") + "|\n"
        for row in comparison.per_query where row.is_no_answer {
            let cells = armKeys.map { key -> String in
                guard let c = row.arms[key] else { return "—" }
                let f = c.top_file.map { ($0 as NSString).lastPathComponent } ?? "—"
                return "\(f) / \(fmt3(c.top_score ?? 0))"
            }
            s += "| \(row.id) | " + cells.joined(separator: " | ") + " |\n"
        }
        s += "\nSee `comparison.json`, per-arm `arm-summary.json`, and per-query `<arm>/q*.json` for full detail.\n"

        try s.data(using: .utf8)!.write(to: url)
    }

    // MARK: - Directory / path helpers

    private func prepareOutputDirectory(_ raw: String?) throws -> URL {
        let fm = FileManager.default
        if let raw, !raw.isEmpty {
            let url = URL(fileURLWithPath: raw, isDirectory: true)
            if fm.fileExists(atPath: url.path) {
                let contents = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
                let meaningful = contents.filter { $0 != ".DS_Store" }
                if !meaningful.isEmpty {
                    throw E10HarnessError("REFUSING to reuse non-empty output directory \(url.path). Point \(Env.outputDirectory) at a fresh path; interrupted runs are rebuilt, not resumed.")
                }
            } else {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            }
            return url
        }
        let url = resolvedURL(fm.temporaryDirectory.appendingPathComponent("vec-e10-out-\(UUID().uuidString)").path)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeScratchRoot(_ raw: String?) throws -> URL {
        let fm = FileManager.default
        let base = (raw.flatMap { $0.isEmpty ? nil : $0 }).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? fm.temporaryDirectory.appendingPathComponent("vec-e10-scratch-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        return resolvedURL(base.path)
    }

    /// Locate the fixed query manifest. `VEC_E10_MANIFEST` overrides; else
    /// resolve relative to this source file's repo root.
    private func locateManifest(_ env: [String: String]) throws -> URL {
        if let p = env["VEC_E10_MANIFEST"], !p.isEmpty {
            return URL(fileURLWithPath: p)
        }
        let url = Self.repoRoot()
            .appendingPathComponent("experiments/E10-markdown-extraction/queries/rubric-queries.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw E10HarnessError("Query manifest not found at \(url.path); set VEC_E10_MANIFEST.")
        }
        return url
    }

    /// Repo root, derived from this file at `<repo>/Tests/VecKitTests/…`.
    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // VecKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }

    private func relativeToRepo(_ url: URL) -> String {
        PathUtilities.relativePath(of: url.path, in: Self.repoRoot().path)
    }

    /// Resolve /var → /private/var (and symlinks) so relative-path math is
    /// consistent, mirroring the existing integration tests.
    private func resolvedURL(_ path: String) -> URL {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(path, &buf) != nil {
            return URL(fileURLWithPath: String(cString: buf))
        }
        return URL(fileURLWithPath: path)
    }

    // MARK: - Small utilities

    private func computeRunIdentity(files: [FrozenFile], manifestSHA: String, modelRevision: String?, settings: FrozenSettings) -> String {
        var parts: [String] = []
        for f in files { parts.append("\(f.path):\(f.sha256)") }
        parts.append("manifest:\(manifestSHA)")
        parts.append("model:\(modelRevision ?? "unspecified")")
        parts.append("settings:\(settings.profile_identity)/\(settings.chunk_chars)/\(settings.chunk_overlap)/\(settings.concurrency)")
        let joined = parts.sorted().joined(separator: "\n")
        return sha256Hex(Data(joined.utf8))
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try enc.encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
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

    private func logLine(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }

    private static func elapsed(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000_000
    }

    private func fmt2(_ d: Double) -> String { String(format: "%.2f", d) }
    private func fmt3(_ d: Double) -> String { String(format: "%.3f", d) }
    private func pct(_ d: Double) -> String { String(format: "%.0f%%", d * 100) }
    private func fmtMB(_ b: UInt64) -> String { String(format: "%.0f MB", Double(b) / 1_048_576) }
}

// MARK: - Manifest decoding

private struct RubricManifest: Codable {
    struct Corpus: Codable {
        let scope: String?
        let expected_markdown_files: Int?
    }
    struct Arm: Codable {
        let key: String
        let text_extraction: String
        let label: String?
    }
    struct Criterion: Codable {
        let type: String
        let value: String
        let case_sensitive: Bool?
        let note: String?
    }
    struct Query: Codable {
        let id: String
        let text: String
        let categories: [String]
        let primary_file: String?
        let relevant_files: [String]
        let passage_criteria: [Criterion]
        let rationale: String?
    }
    let corpus: Corpus?
    let arms: [Arm]
    let queries: [Query]
}

// MARK: - Archive models

private struct FrozenFile: Codable {
    let path: String
    let bytes: Int
    let sha256: String
}

private struct FrozenSettings: Codable {
    let profile_identity: String
    let embedder: String
    let dimension: Int
    let chunk_chars: Int
    let chunk_overlap: Int
    let concurrency: Int
    let coalesce_limit: Int
    let raw_fetch_limit: Int
}

private struct NormalizationFile: Codable {
    let path: String
    let raw_chars: Int
    let normalized_chars: Int
    let reduction_ratio: Double
}

private struct Normalization: Codable {
    let per_file: [NormalizationFile]
    let total_raw_chars: Int
    let total_normalized_chars: Int
    let total_reduction_ratio: Double
}

private struct FrozenInputManifest: Codable {
    let experiment: String
    let run_identity: String
    let frozen_at: String
    let corpus_source: String
    let corpus_scope: String
    let files: [FrozenFile]
    let file_count: Int
    let query_manifest_path: String
    let query_manifest_sha256: String
    let query_count: Int
    let model_directory: String
    let model_revision: String?
    let settings: FrozenSettings
    let normalization: Normalization
}

private struct TopGroup: Codable {
    let file: String
    let best_score: Double
    let match_count: Int
}

private struct CriterionResult: Codable {
    let type: String
    let value: String
    let matched: Bool
    let matched_in: [String]
}

private struct PrimaryAudit: Codable {
    let file_rank: Int
    let best_score: Double
    let distance: Double
    let chunk_type: String
    let line_start: Int?
    let line_end: Int?
    let chunk_ordinal: Int?
    let passage_source: String
    let criteria: [CriterionResult]
    let all_criteria_met: Bool
    let content_preview: String?
    let reconstructed_passage: String?
}

private struct QueryResult: Codable {
    let arm: String
    let id: String
    let text: String
    let categories: [String]
    let is_no_answer: Bool
    let primary_file: String?
    let relevant_files: [String]
    let file_rank: Int?
    let hit_at_1: Bool
    let hit_at_3: Bool
    let hit_at_5: Bool
    let reciprocal_rank: Double
    let overfetch_distinct_files: Int
    let search_seconds: Double
    let top_groups: [TopGroup]
    let primary_audit: PrimaryAudit?
}

private struct PerFileChunks: Codable {
    let path: String
    let chunks: Int
}

private struct ArmMetrics: Codable {
    let answered_queries: Int
    let rank1_rate: Double
    let top3_rate: Double
    let top5_rate: Double
    let mean_reciprocal_rank: Double
    let passage_all_met_rate: Double
}

private struct NoAnswerProbe: Codable {
    let id: String
    let top_file: String?
    let top_score: Double?
}

private struct ArmSummary: Codable {
    let arm: String
    let text_extraction: String
    let file_count: Int
    let indexed_count: Int
    let total_chunks: Int
    let per_file_chunks: [PerFileChunks]
    let index_seconds: Double
    let extract_seconds: Double
    let embed_span_seconds: Double
    let db_seconds: Double
    let search_seconds: Double
    let rss_before_index_bytes: UInt64
    let rss_after_index_bytes: UInt64
    let metrics: ArmMetrics
    let no_answer_probes: [NoAnswerProbe]
}

private struct ComparisonCell: Codable {
    let file_rank: Int?
    let reciprocal_rank: Double
    let all_criteria_met: Bool?
    let top_file: String?
    let top_score: Double?
}

private struct ComparisonRow: Codable {
    let id: String
    let is_no_answer: Bool
    let arms: [String: ComparisonCell]
}

private struct Comparison: Codable {
    let arms: [String]
    let per_query: [ComparisonRow]
    let aggregate: [String: ArmMetrics]
}

/// Hard-failure error for setup problems that must abort the benchmark
/// (a refused non-empty output directory, a missing manifest). Thrown so
/// the test FAILS visibly rather than silently skipping.
private struct E10HarnessError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
