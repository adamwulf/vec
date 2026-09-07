import XCTest
import Foundation
import Darwin
import CryptoKit
@testable import VecKit

/// E11 — reproducible WebVTT-extraction retrieval benchmark.
///
/// Adapts the E10 Markdown harness to captions. Compares two
/// `TextExtractor` arms — `.raw` (current extraction: the whole `.vtt`
/// file, cue scaffolding included) and `.vttV1` (the v1 WebVTT normalizer,
/// which strips the header, cue identifiers, timing lines, `NOTE`/`STYLE`/
/// `REGION` blocks, inline cue markup, and rolling overlap before chunking)
/// — against ONE identical corpus snapshot, the real `e5-base-v2` embedder
/// pinned at `e5-base@1200/0`, identical chunk geometry, batch/bucket, and
/// concurrency. Only the text-extraction mode differs; NO format-specific
/// database behavior and NO inference change is introduced.
///
/// HEAVY, opt-in: skipped unless `VEC_E11_BENCHMARK=1`. It loads the pinned
/// model bundle from `VEC_VTT_MODEL_DIRECTORY` (default: the same pinned E5
/// bundle E10 used). The default `swift-embeddings` download target is
/// outside the harness's writable roots, so the harness NEVER downloads.
///
///     VEC_E11_BENCHMARK=1 \
///     VEC_VTT_MODEL_DIRECTORY=/private/tmp/vec-e10-model/<rev> \
///     swift test --disable-sandbox --disable-swift-testing -c release -j 4 \
///       --filter VecKitTests.VTTRetrievalExperimentTests
///
/// See `experiments/E11-vtt-extraction/harness-notes.md`.
///
/// Invariants carried over from E10 unchanged: freeze (hash all inputs +
/// model files) BEFORE any ranking; preflight every arm/query BEFORE any
/// work; refuse to reuse a non-empty output dir; rebuild an interrupted arm
/// rather than trust partial data; fail immediately on any skipped/
/// partial-failed file; snapshot bodies stay scratch-only and are removed
/// on teardown (no corpus body committed).
///
/// E11-specific additions:
/// - the frozen corpus is WebVTT (`*.vtt`), discovered recursively;
/// - a corpus-count mismatch FAILS the run (E10 only warned): the E11
///   sample is a fixed, committed 16-file corpus, so a drift means the
///   sample is wrong, not operator-triggered growth;
/// - per-arm and per-file "noise" statistics record how much WebVTT
///   scaffolding (timing lines / inline cue tags) survives into the FULL
///   extracted chunk texts — an upper-bound heuristic measured BEFORE E5's
///   char cap and the tokenizer's 512-token truncation, so it bounds (does
///   not confirm) what reaches the vectors — the point of comparing raw vs
///   vtt-v1 (see `VTTNoiseDetector`);
/// - the pre-tokenizer passage audit reconstructs the retrieved chunk BY
///   ORDINAL from the arm's own extractor via `E5BaseEmbedder.normalizeInputs`,
///   so a reflowed vtt-v1 chunk is checked against the pre-tokenizer input
///   the E5 document path builds — never against the raw cue source range
///   (which still carries timestamps and tags).
final class VTTRetrievalExperimentTests: XCTestCase {

    private enum Env {
        static let enable = "VEC_E11_BENCHMARK"
        static let modelDirectory = "VEC_VTT_MODEL_DIRECTORY"
        static let modelRevision = "VEC_VTT_MODEL_REVISION"
        static let corpusDirectory = "VEC_VTT_CORPUS_DIRECTORY"
        static let outputDirectory = "VEC_E11_OUTPUT_DIRECTORY"
        static let scratchDirectory = "VEC_E11_SCRATCH_DIRECTORY"
        static let concurrency = "VEC_E11_CONCURRENCY"
        static let manifest = "VEC_E11_MANIFEST"
    }

    // Explicit, fixed defaults. The AUTHORITATIVE values for any run are the
    // ones recorded in that run's frozen-input-manifest.json (settings +
    // model hashes), captured before ranking; these are only the fallbacks.
    private static let defaultModelDirectory = "/private/tmp/vec-e10-model/f52bf8ec8c7124536f0efb74aca902b2995e5bcd"
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

    func testVTTExtractionRetrievalBenchmark() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            env[Env.enable] == "1",
            "Heavy opt-in benchmark — set \(Env.enable)=1 to run (needs the pinned E5 model; see harness-notes.md)."
        )

        // Model directory: default to the pinned E5 bundle; NEVER download.
        // FAIL (not skip) if the resolved directory does not exist.
        let modelDirRaw = env[Env.modelDirectory] ?? Self.defaultModelDirectory
        let modelDir = URL(fileURLWithPath: modelDirRaw, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: modelDir.path, isDirectory: &isDir), isDir.boolValue else {
            throw VTTHarnessError("model directory \(modelDirRaw) is not an existing directory. The benchmark must not download the model; point \(Env.modelDirectory) at the pinned e5-base-v2 bundle.")
        }
        // Record a revision string. Default to the directory leaf, which by
        // convention is the pinned model revision (…/vec-e10-model/<rev>).
        let modelRevision = env[Env.modelRevision] ?? modelDir.lastPathComponent

        let corpusDir = resolvedURL(env[Env.corpusDirectory] ?? Self.defaultCorpusDirectory().path)
        guard FileManager.default.fileExists(atPath: corpusDir.path) else {
            throw VTTHarnessError("Corpus directory \(corpusDir.path) does not exist (override with \(Env.corpusDirectory)).")
        }

        // Concurrency: if provided, require a valid positive int (no silent fallback/clamp).
        let concurrency: Int
        if let raw = env[Env.concurrency] {
            guard let n = Int(raw), n >= 1 else {
                throw VTTHarnessError("\(Env.concurrency) = '\(raw)' must be a positive integer.")
            }
            concurrency = n
        } else {
            concurrency = IndexingPipeline.defaultConcurrency
        }

        let outputDir = try prepareOutputDirectory(env[Env.outputDirectory])
        logLine("[e11] output/archive directory: \(outputDir.path)")

        scratchRoot = try makeScratchRoot(env[Env.scratchDirectory])
        let snapshotRoot = scratchRoot.appendingPathComponent("snapshot", isDirectory: true)

        // Load + PREFLIGHT the fixed manifest before any work.
        let manifestURL = try locateManifest(env)
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(VTTRubricManifest.self, from: manifestData)
        let manifestSHA = sha256Hex(manifestData)
        try VTTPreflight.validate(manifest)
        logLine("[e11] preflight OK: \(manifest.arms.count) arms, \(manifest.queries.count) queries")

        // ===== FREEZE (before any ranking) =====
        let frozenFiles = try freezeVTTSnapshot(from: corpusDir, to: snapshotRoot)
        logLine("[e11] froze \(frozenFiles.count) WebVTT file(s)")
        XCTAssertGreaterThan(frozenFiles.count, 0, "Snapshot must contain at least one WebVTT file")
        // E11 FAILS on drift: the sample is a fixed committed corpus, so a
        // count mismatch means the sample is wrong (E10 merely warned about
        // operator-triggered corpus growth; that does not apply here).
        if let expected = manifest.corpus?.expected_vtt_files, frozenFiles.count != expected {
            throw VTTHarnessError("frozen WebVTT file count \(frozenFiles.count) != manifest expected_vtt_files \(expected). The E11 sample is a fixed committed corpus; a mismatch means the sample is wrong. E11 fails on drift; it does not warn.")
        }

        // Every labeled file must be present in the frozen snapshot.
        try validateLabeledFilesExist(manifest: manifest, snapshotRoot: snapshotRoot)

        // ===== SAMPLE MANIFEST (anti-drift) =====
        // The parent's freeze-sample.py writes `manifest.json` next to the
        // `.vtt` sample recording each file's path/bytes/sha256. REQUIRE it,
        // verify it matches the frozen snapshot EXACTLY (path + byte + hash
        // set) BEFORE any indexing, archive a copy, and bind its hash into
        // provenance + run identity. This makes it impossible to score the
        // fixed rubric labels against a sample that drifted after labeling.
        let sampleManifestURL = corpusDir.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: sampleManifestURL.path) else {
            throw VTTHarnessError("sample manifest not found at \(sampleManifestURL.path). The parent's freeze-sample.py writes it next to the .vtt sample; the benchmark refuses to run without it.")
        }
        let sampleManifestData = try Data(contentsOf: sampleManifestURL)
        let sampleManifest = try JSONDecoder().decode(VTTSampleManifest.self, from: sampleManifestData)
        let sampleManifestSHA = sha256Hex(sampleManifestData)
        try VTTSampleManifestCheck.verify(sample: sampleManifest, against: frozenFiles)
        try sampleManifestData.write(to: outputDir.appendingPathComponent("sample-manifest.json"))
        logLine("[e11] sample manifest verified against snapshot (\(sampleManifest.files.count) files) and archived")

        let normalization = try normalizationSizes(for: frozenFiles, snapshotRoot: snapshotRoot)
        let modelFiles = try hashDirectoryFiles(modelDir)
        XCTAssertGreaterThan(modelFiles.count, 0, "Model directory must contain files to hash")

        let settings = VTTFrozenSettings(
            profile_identity: Self.profileIdentity, embedder: "e5-base-v2", dimension: 768,
            chunk_chars: Self.chunkChars, chunk_overlap: Self.chunkOverlap, concurrency: concurrency,
            batch_size: IndexingPipeline.defaultBatchSize, bucket_width: IndexingPipeline.defaultBucketWidth,
            compute_policy: "default(nil)", search_limit: Self.searchLimit,
            coalesce_limit: Self.coalesceLimit, raw_fetch_limit: Self.rawFetchLimit
        )
        let runIdentity = computeRunIdentity(files: frozenFiles, modelFiles: modelFiles,
                                             manifestSHA: manifestSHA, sampleManifestSHA: sampleManifestSHA,
                                             settings: settings)

        let frozen = VTTFrozenInputManifest(
            experiment: "E11-vtt-extraction", run_identity: runIdentity,
            frozen_at: ISO8601DateFormatter().string(from: Date()),
            corpus_source: corpusDir.path,
            corpus_scope: manifest.corpus?.scope ?? "WebVTT-only (*.vtt); discovered recursively. No other file types are indexed.",
            files: frozenFiles, file_count: frozenFiles.count,
            query_manifest_path: relativeToRepo(manifestURL), query_manifest_sha256: manifestSHA,
            query_count: manifest.queries.count,
            sample_manifest_path: sampleManifestURL.path, sample_manifest_sha256: sampleManifestSHA,
            model_directory: modelDir.path, model_revision: modelRevision, model_files: modelFiles,
            build: buildIdentity(), settings: settings, normalization: normalization)
        try writeJSON(frozen, to: outputDir.appendingPathComponent("frozen-input-manifest.json"))
        logLine("[e11] freeze complete — run_identity=\(runIdentity). Ranking begins now.")

        // ===== ARMS (each into a fresh DB) =====
        var armSummaries: [VTTArmSummary] = []
        var perArm: [String: [String: VTTQueryResult]] = [:]
        for arm in manifest.arms {
            // Mode already validated in preflight; force-unwrap is safe.
            let mode = TextExtractionMode(rawValue: arm.text_extraction)!
            logLine("[e11] === arm '\(arm.key)' (textExtraction=\(mode.rawValue)) ===")
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
        logLine("[e11] done. Archive at \(outputDir.path)")
    }

    // MARK: - One arm

    private func runArm(arm: VTTRubricManifest.Arm, mode: TextExtractionMode, snapshotRoot: URL,
                        modelDir: URL, concurrency: Int, manifest: VTTRubricManifest,
                        outputDir: URL) async throws -> (VTTArmSummary, [VTTQueryResult]) {
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
            throw VTTHarnessError("arm \(arm.key): index incomplete — \(failures.joined(separator: "; "))")
        }
        guard indexedCount == files.count else {
            throw VTTHarnessError("arm \(arm.key): indexed \(indexedCount) of \(files.count) files")
        }
        let totalChunks = try await db.totalChunkCount()

        // Re-extract each file with the arm's extractor so we can (a) audit
        // passages by ordinal and (b) measure noise on the FULL extracted
        // chunk texts (before E5's char cap / tokenizer truncation). The
        // extractor is deterministic, so the re-extracted chunk list matches
        // the indexed set 1:1 in order — we assert that below so the
        // ordinal-based audit and the noise counts stay trustworthy.
        var chunkCache: [String: [TextChunk]] = [:]
        func extractedChunks(_ path: String) throws -> [TextChunk] {
            if let c = chunkCache[path] { return c }
            let info = try FileScanner.fileInfo(for: snapshotRoot.appendingPathComponent(path), relativeTo: snapshotRoot)
            let c = try extractor.extract(from: info).chunks
            chunkCache[path] = c
            return c
        }

        var perFileChunks: [VTTPerFileChunks] = []
        for file in files {
            let dbCount = try await db.chunkCount(filePath: file.relativePath)
            let chunks = try extractedChunks(file.relativePath)
            XCTAssertEqual(chunks.count, dbCount,
                           "arm \(arm.key) \(file.relativePath): re-extracted chunk count \(chunks.count) != DB count \(dbCount); the ordinal-based audit assumes they match")
            perFileChunks.append(VTTPerFileChunks(path: file.relativePath, chunks: dbCount,
                                                  noise_stats: VTTNoiseDetector.stats(for: chunks)))
        }
        perFileChunks.sort { $0.path < $1.path }
        // The arm aggregate is the SUM of the per-file buckets, so the Python
        // scorer can re-derive it by summing per-file counts (ratios are
        // recomputed from the aggregate counts).
        let armNoise = VTTNoiseStats(
            all_chunks: VTTNoiseDetector.sum(perFileChunks.map { $0.noise_stats.all_chunks }),
            passage_chunks: VTTNoiseDetector.sum(perFileChunks.map { $0.noise_stats.passage_chunks }))
        logLine("[e11] arm \(arm.key): indexed=\(indexedCount)/\(files.count) chunks=\(totalChunks) index=\(fmt2(indexSeconds))s extract=\(fmt2(stats.extractSeconds))s embedSpan=\(fmt2(stats.embedSeconds))s db=\(fmt2(stats.dbSeconds))s rss=\(fmtMB(rssAfter)) noisyShare(all)=\(fmt3(armNoise.all_chunks.noisy_share)) noisyShare(passages)=\(fmt3(armNoise.passage_chunks.noisy_share))")

        // ---- Search (persist each query immediately) ----
        var results: [VTTQueryResult] = []
        var ordinalsCache: [String: [Int64: Int]] = [:]
        var lineCache: [String: [String]] = [:]
        let searchStart = DispatchTime.now()

        func ordinals(_ path: String) async throws -> [Int64: Int] {
            if let c = ordinalsCache[path] { return c }
            let c = try await db.chunkOrdinals(filePath: path); ordinalsCache[path] = c; return c
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
            var archivedGroups: [VTTArchivedGroup] = []
            for (i, g) in groups.enumerated() {
                let ords = try await ordinals(g.filePath)
                let matches = g.matches.map { m in
                    VTTArchivedMatch(score: max(0, 1 - m.distance), distance: m.distance,
                                     chunk_type: m.chunkType.rawValue, line_start: m.lineStart,
                                     line_end: m.lineEnd, chunk_ordinal: ords[m.chunkId])
                }
                archivedGroups.append(VTTArchivedGroup(rank: i + 1, file: g.filePath,
                                                       best_score: g.bestScore, match_count: g.matches.count, matches: matches))
            }

            let isNoAnswer = (q.primary_file == nil)
            var fileRank: Int? = nil
            var reciprocal = 0.0
            var audit: VTTPrimaryAudit? = nil

            if let primary = q.primary_file, let idx = groups.firstIndex(where: { $0.filePath == primary }) {
                fileRank = idx + 1
                reciprocal = 1.0 / Double(idx + 1)
                let best = groups[idx].matches.first!
                let ords = try await ordinals(primary)
                let ordinal = ords[best.chunkId]

                // Pre-tokenizer model input for the retrieved chunk: EXACTLY
                // the string the E5 document path feeds the tokenizer — the
                // "passage: " prefix prepended, then the combined string
                // capped at the E5 char limit (prefix-THEN-cap, so the
                // prefix's tokens eat into the budget) — produced by the SAME
                // `E5BaseEmbedder.normalizeInputs` the embedder uses. Under the
                // current-main single/batch parity fix, the batch document
                // path now shares this exact helper with the single path, so
                // this reconstruction matches whichever path embedded the
                // chunk. It is RECONSTRUCTED BY ORDINAL from the arm's own
                // extractor, which is essential for vtt-v1: the normalizer
                // reflows cue lines, so the raw source line range is NOT the
                // embedded text. Re-extracting the chunk by its ordinal
                // recovers the actual reflowed prose that was embedded.
                //
                // This is still a PRE-TOKENIZER check: the BERT tokenizer then
                // truncates to 512 tokens (fewer chars than the char cap), so a
                // match here is NECESSARY but NOT SUFFICIENT evidence the model
                // encoded the term. It is advisory (does not gate file rank).
                //
                // NOTE: `normalizeInputs` is E5's own helper (internal, reached
                // via @testable) — NOT the generic `normalizeBertInputs`, which
                // caps content BEFORE prefixing (the Nomic convention) and no
                // longer describes E5. "passage: " duplicates the private
                // `E5BaseEmbedder.documentPrefix`, so if E5's document prefix
                // ever changes this literal must be updated in step. Production
                // inference is left untouched.
                var preTokenizerInput = ""
                if let ordinal, ordinal >= 1 {
                    let chunks = try extractedChunks(primary)
                    if ordinal <= chunks.count {
                        preTokenizerInput = E5BaseEmbedder.normalizeInputs(
                            [chunks[ordinal - 1].text], prefix: "passage: ").liveInputs.first ?? ""
                    }
                }
                // Advisory raw source-range text: the originating cue span in
                // the `.vtt` file (a SUPERSET that still contains timing lines
                // and inline tags for the raw arm, and the raw cue scaffolding
                // for vtt-v1). Kept distinct from the by-ordinal input above.
                let sourceRange = reconstructSourceRange(primary: primary, match: best, snapshotRoot: snapshotRoot, cache: &lineCache)

                var crits: [VTTCriterionResult] = []
                for c in q.passage_criteria {
                    crits.append(VTTCriterionResult(type: c.type, value: c.value,
                                                    matched_in_pre_tokenizer_input: matches(c, in: preTokenizerInput),
                                                    matched_in_source_range: matches(c, in: sourceRange)))
                }
                audit = VTTPrimaryAudit(
                    file_rank: idx + 1, best_score: groups[idx].bestScore, distance: best.distance,
                    chunk_type: best.chunkType.rawValue, line_start: best.lineStart, line_end: best.lineEnd,
                    chunk_ordinal: ordinal, input_chars: preTokenizerInput.count, criteria: crits,
                    all_criteria_met: !crits.isEmpty && crits.allSatisfy { $0.matched_in_pre_tokenizer_input })
            }

            let result = VTTQueryResult(
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
        let metrics = VTTArmMetrics(
            answered_queries: answered.count,
            rank1_rate: Double(answered.filter { $0.hit_at_1 }.count) / Double(n),
            top3_rate: Double(answered.filter { $0.hit_at_3 }.count) / Double(n),
            top5_rate: Double(answered.filter { $0.hit_at_5 }.count) / Double(n),
            mean_reciprocal_rank: answered.map { $0.reciprocal_rank }.reduce(0, +) / Double(n),
            passage_all_met_rate: Double(answered.filter { $0.primary_audit?.all_criteria_met == true }.count) / Double(n))
        let noAnswer = results.filter { $0.is_no_answer }.map {
            VTTNoAnswerProbe(id: $0.id, top_file: $0.groups.first?.file, top_score: $0.groups.first?.best_score)
        }
        let summary = VTTArmSummary(
            arm: arm.key, text_extraction: mode.rawValue, file_count: files.count, indexed_count: indexedCount,
            total_chunks: totalChunks, per_file_chunks: perFileChunks, index_seconds: indexSeconds,
            extract_seconds: stats.extractSeconds, embed_span_seconds: stats.embedSeconds, db_seconds: stats.dbSeconds,
            search_seconds: searchSecondsTotal, rss_before_index_bytes: rssBefore, rss_after_index_bytes: rssAfter,
            metrics: metrics, noise_stats: armNoise, no_answer_probes: noAnswer)
        try writeJSON(summary, to: armOut.appendingPathComponent("arm-summary.json"))
        return (summary, results)
    }

    // MARK: - Freeze helpers

    private func freezeVTTSnapshot(from corpusDir: URL, to snapshotRoot: URL) throws -> [VTTFrozenFile] {
        let fm = FileManager.default
        try fm.createDirectory(at: snapshotRoot, withIntermediateDirectories: true)
        var frozen: [VTTFrozenFile] = []
        guard let en = fm.enumerator(at: corpusDir, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw VecError.cannotScanDirectory(corpusDir.path)
        }
        while let url = en.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "vtt" else { continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let rel = PathUtilities.relativePath(of: url.path, in: corpusDir.path)
            let dest = snapshotRoot.appendingPathComponent(rel)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: url, to: dest)
            let (bytes, hex) = try sha256File(dest)
            frozen.append(VTTFrozenFile(path: rel, bytes: bytes, sha256: hex))
        }
        frozen.sort { $0.path < $1.path }
        return frozen
    }

    private func validateLabeledFilesExist(manifest: VTTRubricManifest, snapshotRoot: URL) throws {
        var wanted = Set<String>()
        for q in manifest.queries {
            if let p = q.primary_file { wanted.insert(p) }
            for f in q.relevant_files { wanted.insert(f) }
        }
        let missing = wanted.filter { !FileManager.default.fileExists(atPath: snapshotRoot.appendingPathComponent($0).path) }
        guard missing.isEmpty else {
            throw VTTHarnessError("labeled files missing from frozen snapshot: \(missing.sorted().joined(separator: ", "))")
        }
    }

    /// Records raw vs vtt-v1-normalized character counts per file. Uses the
    /// PUBLIC `VTTTextNormalizer.normalize` — the same v1 algorithm the
    /// extractor applies — so the reduction ratio reflects exactly what the
    /// vtt-v1 arm feeds the splitter.
    private func normalizationSizes(for files: [VTTFrozenFile], snapshotRoot: URL) throws -> VTTNormalization {
        var perFile: [VTTNormalizationFile] = []
        var totalRaw = 0, totalNorm = 0
        for f in files {
            let content = (try? String(contentsOf: snapshotRoot.appendingPathComponent(f.path), encoding: .utf8)) ?? ""
            let raw = content.count
            let norm = VTTTextNormalizer.normalize(content).count
            perFile.append(VTTNormalizationFile(path: f.path, raw_chars: raw, normalized_chars: norm,
                                                reduction_ratio: raw > 0 ? 1 - Double(norm) / Double(raw) : 0))
            totalRaw += raw; totalNorm += norm
        }
        perFile.sort { $0.path < $1.path }
        return VTTNormalization(per_file: perFile, total_raw_chars: totalRaw, total_normalized_chars: totalNorm,
                                total_reduction_ratio: totalRaw > 0 ? 1 - Double(totalNorm) / Double(totalRaw) : 0)
    }

    private func hashDirectoryFiles(_ dir: URL) throws -> [VTTFrozenFile] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out: [VTTFrozenFile] = []
        while let u = en.nextObject() as? URL {
            guard (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let (bytes, hex) = try sha256File(u)
            out.append(VTTFrozenFile(path: PathUtilities.relativePath(of: u.path, in: dir.path), bytes: bytes, sha256: hex))
        }
        out.sort { $0.path < $1.path }
        return out
    }

    private func buildIdentity() -> VTTBuildIdentity {
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
        return VTTBuildIdentity(
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

    /// Advisory RAW source-range text for a match: the source lines the cue
    /// span occupies in the `.vtt` file (a SUPERSET of the embedded chunk;
    /// for vtt-v1 it still carries timing lines and inline tags), or the
    /// whole file for a whole-document chunk. Never persisted; used only to
    /// compute the `matched_in_source_range` boolean. The authoritative,
    /// reflow-correct check is `matched_in_pre_tokenizer_input`, reconstructed
    /// by ordinal — see the note at its call site.
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

    private func matches(_ c: VTTRubricManifest.Criterion, in haystack: String) -> Bool {
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

    private func buildComparison(manifest: VTTRubricManifest, perArm: [String: [String: VTTQueryResult]],
                                 arms: [VTTArmSummary]) -> VTTComparison {
        let keys = manifest.arms.map { $0.key }
        var rows: [VTTComparisonRow] = []
        for q in manifest.queries {
            var byArm: [String: VTTComparisonCell] = [:]
            for k in keys {
                if let r = perArm[k]?[q.id] {
                    byArm[k] = VTTComparisonCell(file_rank: r.file_rank, reciprocal_rank: r.reciprocal_rank,
                                                 all_criteria_met: r.primary_audit?.all_criteria_met,
                                                 top_file: r.groups.first?.file, top_score: r.groups.first?.best_score)
                }
            }
            rows.append(VTTComparisonRow(id: q.id, is_no_answer: q.primary_file == nil, arms: byArm))
        }
        return VTTComparison(arms: keys, per_query: rows,
                             aggregate: Dictionary(uniqueKeysWithValues: arms.map { ($0.arm, $0.metrics) }))
    }

    private func writeSummaryMarkdown(frozen: VTTFrozenInputManifest, arms: [VTTArmSummary],
                                      comparison: VTTComparison, to url: URL) throws {
        var s = "# E11 WebVTT-extraction retrieval benchmark\n\n"
        s += "Run identity: `\(frozen.run_identity)`  \nFrozen at: \(frozen.frozen_at)\n\n"
        s += "Corpus: `\(frozen.corpus_source)` — \(frozen.file_count) WebVTT file(s). "
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
        s += "\n> File rank is authoritative. `passage-all-met` is an advisory, case-insensitive check of the criteria against the PRE-TOKENIZER model input, reconstructed BY ORDINAL from the arm's extractor via `E5BaseEmbedder.normalizeInputs` (the `passage: ` prefix prepended, then the combined string capped at the E5 char limit — prefix-then-cap, shared by E5's single and batch document paths under the current-main parity fix). For vtt-v1 the normalizer reflows cue lines, so this by-ordinal reconstruction — not the raw source range — is the text actually embedded. The BERT tokenizer truncates further to 512 tokens, so a match here is necessary but NOT sufficient evidence the model encoded the term; it does not gate file rank.\n\n"

        s += "## Scaffolding noise (share of embedded chunks carrying ≥1 WebVTT timing line or inline tag)\n\n"
        s += "| arm | all: noisy/total | all share | passages: noisy/total | passages share |\n"
        s += "|---|---|---|---|---|\n"
        for a in arms {
            let all = a.noise_stats.all_chunks, pass = a.noise_stats.passage_chunks
            s += "| \(a.arm) | \(all.noisy_chunks)/\(all.chunk_count) | \(pct(all.noisy_share)) | "
            s += "\(pass.noisy_chunks)/\(pass.chunk_count) | \(pct(pass.noisy_share)) |\n"
        }
        s += "\n> Noise is a syntactic heuristic on the FULL extracted chunk texts, computed BEFORE E5's 2000-char cap and the tokenizer's 512-token truncation — an upper bound on scaffolding reaching the model, not a guarantee it is in the vectors. A timing LINE is a full cue timing line (`HH:MM:SS.fff --> HH:MM:SS.fff`, leading whitespace allowed); an inline tag is a narrow WebVTT tag (`<v …>`, `</v>`, `<c…>`, `<i>`, `<br>`, an inline `<HH:MM:SS.fff>` timestamp, …). A decoded literal `<i>` in genuine prose counts as syntactic noise. It measures residual scaffolding, not retrieval quality.\n\n"

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
        s += "\nSee `comparison.json`, per-arm `arm-summary.json` (incl. per-file noise), and per-query `<arm>/q*.json` (full ordered groups) for detail.\n"
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
                    throw VTTHarnessError("REFUSING to reuse non-empty output directory \(url.path). Point \(Env.outputDirectory) at a fresh path; interrupted runs are rebuilt, not resumed.")
                }
            } else {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            }
            return url
        }
        let url = fm.temporaryDirectory.appendingPathComponent("vec-e11-out-\(UUID().uuidString)")
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
        let child = VTTScratch.uniqueChild(under: base)
        try fm.createDirectory(at: child, withIntermediateDirectories: true)
        return resolvedURL(child.path)
    }

    private func locateManifest(_ env: [String: String]) throws -> URL {
        if let p = env[Env.manifest], !p.isEmpty { return URL(fileURLWithPath: p) }
        let url = Self.repoRoot().appendingPathComponent("experiments/E11-vtt-extraction/queries/rubric-queries.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VTTHarnessError("Query manifest not found at \(url.path); set \(Env.manifest).")
        }
        return url
    }

    private static func defaultCorpusDirectory() -> URL {
        repoRoot().appendingPathComponent("experiments/E11-vtt-extraction/sample", isDirectory: true)
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

    private func computeRunIdentity(files: [VTTFrozenFile], modelFiles: [VTTFrozenFile], manifestSHA: String,
                                    sampleManifestSHA: String, settings: VTTFrozenSettings) -> String {
        var parts = files.map { "corpus:\($0.path):\($0.sha256)" }
        parts += modelFiles.map { "model:\($0.path):\($0.sha256)" }
        parts.append("manifest:\(manifestSHA)")
        parts.append("sample_manifest:\(sampleManifestSHA)")
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

/// Guards against manifest/enum drift that would otherwise abort the second
/// arm mid-run, against the scratch-ownership bug, and against noise-regex
/// drift. Runs in a normal `swift test` with no model, corpus, or env gate.
/// The committed manifest may not exist yet (the manager writes the sample +
/// rubric before the benchmark), so the manifest check SKIPS when it is
/// absent rather than failing.
final class VTTRetrievalManifestTests: XCTestCase {

    private static func committedManifestURL() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("experiments/E11-vtt-extraction/queries/rubric-queries.json")
    }

    func testCommittedManifestPreflights() throws {
        let url = Self.committedManifestURL()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path),
                          "E11 rubric manifest not committed yet (manager writes the sample + rubric before the benchmark).")
        let data = try Data(contentsOf: url)
        let manifest = try JSONDecoder().decode(VTTRubricManifest.self, from: data)
        XCTAssertNoThrow(try VTTPreflight.validate(manifest), "committed manifest must preflight")
        for a in manifest.arms {
            XCTAssertNotNil(TextExtractionMode(rawValue: a.text_extraction),
                            "arm '\(a.key)' text_extraction '\(a.text_extraction)' must map to a TextExtractionMode")
        }
        XCTAssertEqual(Set(manifest.queries.map { $0.id }).count, manifest.queries.count, "query ids must be unique")
        XCTAssertFalse(manifest.queries.isEmpty)
        // E11 exists to compare raw vs vtt-v1; both arms must be present.
        XCTAssertTrue(manifest.arms.contains { $0.text_extraction == "raw" }, "manifest must declare a raw arm")
        XCTAssertTrue(manifest.arms.contains { $0.text_extraction == "vtt-v1" }, "manifest must declare a vtt-v1 arm")
        if let expected = manifest.corpus?.expected_vtt_files {
            XCTAssertGreaterThan(expected, 0, "expected_vtt_files must be positive")
        }
    }

    func testScratchChildIsOwnedNotCaller() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("vec-e11-owntest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let child = VTTScratch.uniqueChild(under: base)
        XCTAssertNotEqual(child.standardizedFileURL, base.standardizedFileURL, "scratch child must differ from the caller dir")
        XCTAssertEqual(child.deletingLastPathComponent().standardizedFileURL, base.standardizedFileURL,
                       "scratch child must live UNDER the caller dir so teardown never deletes the caller dir")
    }

    // MARK: Noise-regex behavior (the E11-specific measurement)

    func testTimestampLineRegex() {
        // Real cue timing lines, including settings and indentation.
        XCTAssertTrue(VTTNoiseDetector.hasTimestampLine("00:00:01.000 --> 00:00:04.000"))
        XCTAssertTrue(VTTNoiseDetector.hasTimestampLine("00:00:01.000 --> 00:00:04.000 align:start position:50%"))
        XCTAssertTrue(VTTNoiseDetector.hasTimestampLine("01:02:03.400 --> 01:02:05.000"))   // with hours
        XCTAssertTrue(VTTNoiseDetector.hasTimestampLine("   00:00:01.000 --> 00:00:04.000"))   // indented
        // A timing line embedded among prose lines is still detected.
        XCTAssertTrue(VTTNoiseDetector.hasTimestampLine("Some prose here\n00:00:01.000 --> 00:00:04.000\nmore prose"))
        // Ordinary prose that merely mentions numbers or a time is NOT a line.
        XCTAssertFalse(VTTNoiseDetector.hasTimestampLine("We met at 3:00 and left by 4."))
        XCTAssertFalse(VTTNoiseDetector.hasTimestampLine("The count reached 1,575 defendants."))
        XCTAssertFalse(VTTNoiseDetector.hasTimestampLine("00:00:01.000 to 00:00:04.000"))   // no arrow
        XCTAssertFalse(VTTNoiseDetector.hasTimestampLine("normal clean transcript prose"))
    }

    func testInlineTagRegex() {
        XCTAssertTrue(VTTNoiseDetector.hasInlineTag("<v Roger>Hello there</v>"))
        XCTAssertTrue(VTTNoiseDetector.hasInlineTag("<c.loud>LOUD</c>"))
        XCTAssertTrue(VTTNoiseDetector.hasInlineTag("plain <i>italic</i> word"))
        XCTAssertTrue(VTTNoiseDetector.hasInlineTag("<br>"))
        XCTAssertTrue(VTTNoiseDetector.hasInlineTag("word<00:00:05.000>continues"))   // inline timestamp tag
        XCTAssertTrue(VTTNoiseDetector.hasInlineTag("word<00:05.000>continues"))      // mm:ss.fff form
        // Ordinary prose comparisons must NOT count as tags.
        XCTAssertFalse(VTTNoiseDetector.hasInlineTag("if a < b and c > d then stop"))
        XCTAssertFalse(VTTNoiseDetector.hasInlineTag("5 < 10 > 3 is nonsense"))
        XCTAssertFalse(VTTNoiseDetector.hasInlineTag("temperature < 0 degrees"))
        XCTAssertFalse(VTTNoiseDetector.hasInlineTag("clean transcript prose with no markup"))
    }

    func testNoiseBucketCounts() {
        // whole + two passages: one passage has a timing line, one is clean,
        // the whole chunk carries both a timing line and a tag.
        let chunks = [
            TextChunk(text: "00:00:01.000 --> 00:00:04.000\n<v A>hi</v> there\nclean tail", type: .whole),
            TextChunk(text: "00:00:01.000 --> 00:00:04.000\nsome words", type: .chunk),
            TextChunk(text: "perfectly clean prose", type: .chunk),
        ]
        let stats = VTTNoiseDetector.stats(for: chunks)
        XCTAssertEqual(stats.all_chunks.chunk_count, 3)
        XCTAssertEqual(stats.all_chunks.timestamp_chunks, 2)
        XCTAssertEqual(stats.all_chunks.inline_tag_chunks, 1)   // only the whole chunk has a tag
        XCTAssertEqual(stats.all_chunks.noisy_chunks, 2)        // union: whole + first passage
        XCTAssertEqual(stats.all_chunks.noisy_share, 2.0 / 3.0, accuracy: 1e-9)
        // passage-only excludes the whole chunk.
        XCTAssertEqual(stats.passage_chunks.chunk_count, 2)
        XCTAssertEqual(stats.passage_chunks.timestamp_chunks, 1)
        XCTAssertEqual(stats.passage_chunks.inline_tag_chunks, 0)
        XCTAssertEqual(stats.passage_chunks.noisy_chunks, 1)
        XCTAssertEqual(stats.passage_chunks.noisy_share, 0.5, accuracy: 1e-9)
    }

    func testNoiseSumMatchesPerFile() {
        // Aggregation must be the exact sum of per-file buckets so the Python
        // scorer can re-derive the arm total by summing per-file counts.
        let a = VTTNoiseDetector.stats(for: [
            TextChunk(text: "00:00:01.000 --> 00:00:02.000\nx", type: .whole),
            TextChunk(text: "<i>y</i>", type: .chunk),
        ])
        let b = VTTNoiseDetector.stats(for: [
            TextChunk(text: "clean", type: .whole),
            TextChunk(text: "00:00:03.000 --> 00:00:04.000\nz", type: .chunk),
        ])
        let sum = VTTNoiseDetector.sum([a.all_chunks, b.all_chunks])
        XCTAssertEqual(sum.chunk_count, a.all_chunks.chunk_count + b.all_chunks.chunk_count)
        XCTAssertEqual(sum.timestamp_chunks, a.all_chunks.timestamp_chunks + b.all_chunks.timestamp_chunks)
        XCTAssertEqual(sum.inline_tag_chunks, a.all_chunks.inline_tag_chunks + b.all_chunks.inline_tag_chunks)
        XCTAssertEqual(sum.noisy_chunks, a.all_chunks.noisy_chunks + b.all_chunks.noisy_chunks)
        XCTAssertEqual(sum.noisy_share, Double(sum.noisy_chunks) / Double(sum.chunk_count), accuracy: 1e-9)
    }

    func testEmptyNoiseBucketShareIsZero() {
        let stats = VTTNoiseDetector.stats(for: [])
        XCTAssertEqual(stats.all_chunks.chunk_count, 0)
        XCTAssertEqual(stats.all_chunks.noisy_share, 0)
        XCTAssertEqual(stats.passage_chunks.noisy_share, 0)
    }

    // MARK: Sample-manifest anti-drift verification

    private func frozen(_ path: String, _ bytes: Int, _ sha: String) -> VTTFrozenFile {
        VTTFrozenFile(path: path, bytes: bytes, sha256: sha)
    }
    private func sampleFile(_ path: String, _ bytes: Int, _ sha: String) -> VTTSampleManifest.File {
        VTTSampleManifest.File(path: path, bytes: bytes, sha256: sha)
    }

    func testSampleManifestMatches() {
        let snap = [frozen("a.vtt", 10, "aa"), frozen("b.vtt", 20, "bb")]
        let sample = VTTSampleManifest(files: [sampleFile("b.vtt", 20, "BB"), sampleFile("a.vtt", 10, "aa")],
                                       real_files: 1, synthetic_files: 1)
        // sha compare is case-insensitive; order does not matter.
        XCTAssertNoThrow(try VTTSampleManifestCheck.verify(sample: sample, against: snap))
    }

    func testSampleManifestByteMismatchThrows() {
        let snap = [frozen("a.vtt", 10, "aa")]
        let sample = VTTSampleManifest(files: [sampleFile("a.vtt", 11, "aa")], real_files: nil, synthetic_files: nil)
        XCTAssertThrowsError(try VTTSampleManifestCheck.verify(sample: sample, against: snap))
    }

    func testSampleManifestHashMismatchThrows() {
        let snap = [frozen("a.vtt", 10, "aa")]
        let sample = VTTSampleManifest(files: [sampleFile("a.vtt", 10, "zz")], real_files: nil, synthetic_files: nil)
        XCTAssertThrowsError(try VTTSampleManifestCheck.verify(sample: sample, against: snap))
    }

    func testSampleManifestExtraSnapshotFileThrows() {
        let snap = [frozen("a.vtt", 10, "aa"), frozen("b.vtt", 20, "bb")]
        let sample = VTTSampleManifest(files: [sampleFile("a.vtt", 10, "aa")], real_files: nil, synthetic_files: nil)
        XCTAssertThrowsError(try VTTSampleManifestCheck.verify(sample: sample, against: snap))
    }

    func testSampleManifestMissingSnapshotFileThrows() {
        let snap = [frozen("a.vtt", 10, "aa")]
        let sample = VTTSampleManifest(files: [sampleFile("a.vtt", 10, "aa"), sampleFile("b.vtt", 20, "bb")],
                                       real_files: nil, synthetic_files: nil)
        XCTAssertThrowsError(try VTTSampleManifestCheck.verify(sample: sample, against: snap))
    }

    func testSampleManifestCountMismatchThrows() {
        let snap = [frozen("a.vtt", 10, "aa"), frozen("b.vtt", 20, "bb")]
        // Files match exactly, but real+synthetic (1+2) != 2 files.
        let sample = VTTSampleManifest(files: [sampleFile("a.vtt", 10, "aa"), sampleFile("b.vtt", 20, "bb")],
                                       real_files: 1, synthetic_files: 2)
        XCTAssertThrowsError(try VTTSampleManifestCheck.verify(sample: sample, against: snap))
    }

    func testSampleManifestIgnoresExtraFields() throws {
        // Extra top-level and per-file metadata fields must decode cleanly.
        let json = """
        {
          "schema_version": 1, "experiment": "E11-vtt-extraction",
          "frozen_at": "2026-09-07T00:00:00Z", "real_source": "/somewhere",
          "real_files": 1, "synthetic_files": 1, "scope": "WebVTT-only (*.vtt)",
          "files": [
            {"path": "a.vtt", "bytes": 10, "sha256": "aa", "origin": "real", "cue_count": 42, "duration_s": 12.5},
            {"path": "b.vtt", "bytes": 20, "sha256": "bb", "origin": "synthetic", "cue_count": 7}
          ]
        }
        """
        let m = try JSONDecoder().decode(VTTSampleManifest.self, from: Data(json.utf8))
        XCTAssertEqual(m.files.count, 2)
        XCTAssertEqual(m.real_files, 1)
        XCTAssertEqual(m.synthetic_files, 1)
        XCTAssertEqual(m.files.first?.path, "a.vtt")
    }
}

// MARK: - Preflight + scratch (file-scope so the cheap tests can exercise them)

enum VTTPreflight {
    static func validate(_ m: VTTRubricManifest) throws {
        guard !m.arms.isEmpty else { throw VTTHarnessError("manifest has no arms") }
        var armKeys = Set<String>()
        for a in m.arms {
            guard TextExtractionMode(rawValue: a.text_extraction) != nil else {
                throw VTTHarnessError("arm '\(a.key)': text_extraction '\(a.text_extraction)' is not a valid TextExtractionMode (valid: \(TextExtractionMode.allCases.map { $0.rawValue }.joined(separator: ", ")))")
            }
            guard isSafeKey(a.key) else { throw VTTHarnessError("arm key '\(a.key)' is not filename-safe") }
            guard armKeys.insert(a.key).inserted else { throw VTTHarnessError("duplicate arm key '\(a.key)'") }
        }
        guard !m.queries.isEmpty else { throw VTTHarnessError("manifest has no queries") }
        var ids = Set<String>()
        for q in m.queries {
            guard isSafeKey(q.id) else { throw VTTHarnessError("query id '\(q.id)' is not filename-safe") }
            guard ids.insert(q.id).inserted else { throw VTTHarnessError("duplicate query id '\(q.id)'") }
            if q.primary_file == nil {
                guard q.relevant_files.isEmpty else { throw VTTHarnessError("query '\(q.id)': no-answer query must have empty relevant_files") }
            } else if let p = q.primary_file, !q.relevant_files.contains(p) {
                throw VTTHarnessError("query '\(q.id)': primary_file must be listed in relevant_files")
            }
        }
    }
    static func isSafeKey(_ s: String) -> Bool {
        !s.isEmpty && s != "." && s != ".." && s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
    }
}

enum VTTScratch {
    /// A unique child directory under `base`. The harness owns and deletes
    /// only this child, never `base` itself.
    static func uniqueChild(under base: URL) -> URL {
        base.appendingPathComponent("vec-e11-scratch-\(UUID().uuidString)", isDirectory: true)
    }
}

/// Verifies the parent-written sample manifest against the frozen snapshot.
/// File-scope so the cheap tests can exercise it without the heavy gate.
enum VTTSampleManifestCheck {
    /// Requires EXACT set equality on {path, bytes, sha256}: every manifest
    /// file must exist in the snapshot with the same size and hash, and the
    /// snapshot must contain no file the manifest omits. Any missing/extra
    /// path or any byte/hash mismatch throws, so the fixed rubric labels can
    /// never be scored against a drifted sample. If both `real_files` and
    /// `synthetic_files` are present they must sum to the file count.
    static func verify(sample: VTTSampleManifest, against frozen: [VTTFrozenFile]) throws {
        var sampleByPath: [String: VTTSampleManifest.File] = [:]
        for f in sample.files {
            guard sampleByPath.updateValue(f, forKey: f.path) == nil else {
                throw VTTHarnessError("sample manifest has duplicate path '\(f.path)'")
            }
        }
        let frozenPaths = Set(frozen.map { $0.path })
        let samplePaths = Set(sampleByPath.keys)
        let missing = samplePaths.subtracting(frozenPaths)   // listed but not on disk
        let extra = frozenPaths.subtracting(samplePaths)     // on disk but not listed
        guard missing.isEmpty else {
            throw VTTHarnessError("sample manifest lists file(s) absent from the frozen snapshot: \(missing.sorted().joined(separator: ", "))")
        }
        guard extra.isEmpty else {
            throw VTTHarnessError("frozen snapshot contains file(s) not in the sample manifest: \(extra.sorted().joined(separator: ", "))")
        }
        for f in frozen {
            let s = sampleByPath[f.path]!   // safe: path sets are equal
            guard s.bytes == f.bytes else {
                throw VTTHarnessError("sample manifest byte mismatch for '\(f.path)': manifest \(s.bytes) != snapshot \(f.bytes)")
            }
            guard s.sha256.lowercased() == f.sha256.lowercased() else {
                throw VTTHarnessError("sample manifest sha256 mismatch for '\(f.path)': manifest \(s.sha256) != snapshot \(f.sha256)")
            }
        }
        if let real = sample.real_files, let synth = sample.synthetic_files, real + synth != frozen.count {
            throw VTTHarnessError("sample manifest real_files (\(real)) + synthetic_files (\(synth)) != frozen file count (\(frozen.count))")
        }
    }
}

// MARK: - Scaffolding-noise detection (file-scope so the cheap tests exercise it)

/// Syntactic detector for residual WebVTT scaffolding in an extracted chunk.
/// It runs on the FULL extracted chunk text (raw for the raw arm, normalized
/// for vtt-v1), BEFORE E5's 2000-char cap and the tokenizer's 512-token
/// truncation, so it is an UPPER-BOUND heuristic for how much cue scaffolding
/// could reach the vectors (content past the cap or token limit — notably in
/// the whole-document chunk and the tail of a long chunk — may never be
/// embedded) — the point of comparing the two arms.
///
/// Two independent signals, defined precisely so the counts are reproducible:
///
///  * **timestamp LINE** — a full cue timing line: an `HH:MM:SS.fff` (or
///    `MM:SS.fff`) clock, the `-->` arrow, a second clock, then optional cue
///    settings. Anchored to a line (`^…$` with `.anchorsMatchLines`), leading
///    whitespace allowed (real exporters indent). Anchoring on the arrow is
///    what keeps ordinary prose that merely mentions a time or a number from
///    counting. This mirrors `VTTTextNormalizer`'s private `timing` pattern;
///    if that pattern ever changes, update this one in step.
///
///  * **inline tag** — a narrow WebVTT cue tag: `<` (optionally `/`) followed
///    by EITHER an ASCII-letter-led element name (`<v …>`, `</v>`, `<c.loud>`,
///    `<i>`, `<lang en>`, `<ruby>`, `<br>`, …) OR an inline `<HH:MM:SS.fff>`
///    timestamp. Requiring a letter or a timestamp immediately after `<`
///    means ordinary prose comparisons — `a < b`, `5 < 10 > 3` — never count.
///    Known heuristic edge: a spaceless `a<b>c` and a DECODED literal `<i>`
///    that appears in genuine prose (e.g. from `&lt;i&gt;`) both count as
///    syntactic noise. These are rare and intentionally left in; the metric
///    measures residual angle-bracket markup shape, not semantics.
///
/// A chunk is "noisy" if it has ≥1 timestamp line OR ≥1 inline tag. The
/// per-signal counts may overlap; `noisy_chunks` counts the union once.
enum VTTNoiseDetector {
    // Fixed, programmer-authored expressions. No input is compiled as regex.
    static let timestampLine = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:[0-9]{2,}:)?[0-9]{2}:[0-9]{2}\.[0-9]{3}[ \t]+-->[ \t]+(?:[0-9]{2,}:)?[0-9]{2}:[0-9]{2}\.[0-9]{3}(?:[ \t].*)?$"#,
        options: [.anchorsMatchLines])
    static let inlineTag = try! NSRegularExpression(
        pattern: #"</?(?:[A-Za-z][^<>\r\n]*|(?:[0-9]{2,}:)?[0-9]{2}:[0-9]{2}\.[0-9]{3})>"#)

    static func hasTimestampLine(_ s: String) -> Bool { firstMatch(timestampLine, s) }
    static func hasInlineTag(_ s: String) -> Bool { firstMatch(inlineTag, s) }

    private static func firstMatch(_ re: NSRegularExpression, _ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    static func bucket(texts: [String]) -> VTTNoiseBucket {
        var ts = 0, tag = 0, noisy = 0
        for t in texts {
            let hasTS = hasTimestampLine(t)
            let hasTag = hasInlineTag(t)
            if hasTS { ts += 1 }
            if hasTag { tag += 1 }
            if hasTS || hasTag { noisy += 1 }
        }
        let count = texts.count
        return VTTNoiseBucket(chunk_count: count, timestamp_chunks: ts, inline_tag_chunks: tag,
                              noisy_chunks: noisy, noisy_share: count > 0 ? Double(noisy) / Double(count) : 0)
    }

    static func stats(for chunks: [TextChunk]) -> VTTNoiseStats {
        VTTNoiseStats(
            all_chunks: bucket(texts: chunks.map { $0.text }),
            passage_chunks: bucket(texts: chunks.filter { $0.type != .whole }.map { $0.text }))
    }

    /// Aggregate = the exact sum of per-file buckets (share recomputed from
    /// the summed counts), so a scorer can re-derive an arm total by summing.
    static func sum(_ buckets: [VTTNoiseBucket]) -> VTTNoiseBucket {
        let count = buckets.reduce(0) { $0 + $1.chunk_count }
        let ts = buckets.reduce(0) { $0 + $1.timestamp_chunks }
        let tag = buckets.reduce(0) { $0 + $1.inline_tag_chunks }
        let noisy = buckets.reduce(0) { $0 + $1.noisy_chunks }
        return VTTNoiseBucket(chunk_count: count, timestamp_chunks: ts, inline_tag_chunks: tag,
                              noisy_chunks: noisy, noisy_share: count > 0 ? Double(noisy) / Double(count) : 0)
    }
}

// MARK: - Manifest decoding

struct VTTRubricManifest: Codable {
    struct Corpus: Codable { let scope: String?; let expected_vtt_files: Int? }
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

/// The parent's `freeze-sample.py` output (`<corpus>/manifest.json`). Only the
/// fields the harness verifies are decoded; every extra metadata field
/// (schema_version, experiment, frozen_at, real_source, scope, per-file
/// origin/cue_count/inventory, …) is ignored on decode.
struct VTTSampleManifest: Codable {
    struct File: Codable { let path: String; let bytes: Int; let sha256: String }
    let files: [File]
    let real_files: Int?
    let synthetic_files: Int?
}

// MARK: - Archive models
//
// These mirror the E10 archive schema field-for-field (identical JSON keys),
// so the E11 scorer can be adapted from E10's with minimal change. The Swift
// type names are `VTT`-prefixed only to avoid colliding with E10's file-scope
// types in the same test target; the emitted JSON keys are unchanged. The
// only additive change is `noise_stats` on the arm summary and on each
// per-file entry.

struct VTTFrozenFile: Codable { let path: String; let bytes: Int; let sha256: String }

struct VTTFrozenSettings: Codable {
    let profile_identity: String; let embedder: String; let dimension: Int
    let chunk_chars: Int; let chunk_overlap: Int; let concurrency: Int
    let batch_size: Int; let bucket_width: Int; let compute_policy: String
    let search_limit: Int; let coalesce_limit: Int; let raw_fetch_limit: Int
}

struct VTTBuildIdentity: Codable {
    let configuration: String; let os_version: String; let active_processor_count: Int; let host_name: String
    let swift_version: String?; let git_head: String?; let git_dirty: Bool?; let package_resolved_sha256: String?
}

struct VTTNormalizationFile: Codable { let path: String; let raw_chars: Int; let normalized_chars: Int; let reduction_ratio: Double }
struct VTTNormalization: Codable {
    let per_file: [VTTNormalizationFile]; let total_raw_chars: Int; let total_normalized_chars: Int; let total_reduction_ratio: Double
}

struct VTTFrozenInputManifest: Codable {
    let experiment: String; let run_identity: String; let frozen_at: String
    let corpus_source: String; let corpus_scope: String
    let files: [VTTFrozenFile]; let file_count: Int
    let query_manifest_path: String; let query_manifest_sha256: String; let query_count: Int
    let sample_manifest_path: String; let sample_manifest_sha256: String
    let model_directory: String; let model_revision: String?; let model_files: [VTTFrozenFile]
    let build: VTTBuildIdentity; let settings: VTTFrozenSettings; let normalization: VTTNormalization
}

struct VTTArchivedMatch: Codable {
    let score: Double; let distance: Double; let chunk_type: String
    let line_start: Int?; let line_end: Int?; let chunk_ordinal: Int?
}
struct VTTArchivedGroup: Codable {
    let rank: Int; let file: String; let best_score: Double; let match_count: Int; let matches: [VTTArchivedMatch]
}

struct VTTCriterionResult: Codable {
    let type: String; let value: String
    /// Matched in the PRE-TOKENIZER model input reconstructed BY ORDINAL from
    /// the arm's extractor via `E5BaseEmbedder.normalizeInputs` (the
    /// "passage: " prefix prepended, then the combined string capped at the E5
    /// char limit — prefix-then-cap, shared by E5's single and batch document
    /// paths under the current-main parity fix). For vtt-v1 this is the
    /// reflowed normalized text that was actually embedded. The tokenizer
    /// truncates further to 512 tokens, so this is necessary-but-not-sufficient
    /// evidence.
    let matched_in_pre_tokenizer_input: Bool
    /// Matched in the chunk's RAW source line range (a superset that still
    /// carries cue scaffolding). Advisory.
    let matched_in_source_range: Bool
}
struct VTTPrimaryAudit: Codable {
    let file_rank: Int; let best_score: Double; let distance: Double; let chunk_type: String
    let line_start: Int?; let line_end: Int?; let chunk_ordinal: Int?
    /// Length of the pre-tokenizer input string audited (content + prefix).
    let input_chars: Int
    let criteria: [VTTCriterionResult]; let all_criteria_met: Bool
}

struct VTTQueryResult: Codable {
    let arm: String; let id: String; let text: String; let categories: [String]
    let is_no_answer: Bool; let primary_file: String?; let relevant_files: [String]
    let file_rank: Int?; let hit_at_1: Bool; let hit_at_3: Bool; let hit_at_5: Bool
    let reciprocal_rank: Double; let overfetch_distinct_files: Int; let search_seconds: Double
    let groups: [VTTArchivedGroup]; let primary_audit: VTTPrimaryAudit?
}

/// One "bucket" of noise counts over a set of chunks. `noisy_chunks` is the
/// union (timestamp OR tag, counted once); `timestamp_chunks` and
/// `inline_tag_chunks` may overlap. `noisy_share = noisy_chunks / chunk_count`
/// (0 when there are no chunks).
struct VTTNoiseBucket: Codable {
    let chunk_count: Int; let timestamp_chunks: Int; let inline_tag_chunks: Int
    let noisy_chunks: Int; let noisy_share: Double
}
/// Noise over all chunks and, separately, over the passage chunks only
/// (every chunk except the `.whole` document chunk).
struct VTTNoiseStats: Codable { let all_chunks: VTTNoiseBucket; let passage_chunks: VTTNoiseBucket }

struct VTTPerFileChunks: Codable { let path: String; let chunks: Int; let noise_stats: VTTNoiseStats }
struct VTTArmMetrics: Codable {
    let answered_queries: Int; let rank1_rate: Double; let top3_rate: Double; let top5_rate: Double
    let mean_reciprocal_rank: Double; let passage_all_met_rate: Double
}
struct VTTNoAnswerProbe: Codable { let id: String; let top_file: String?; let top_score: Double? }
struct VTTArmSummary: Codable {
    let arm: String; let text_extraction: String; let file_count: Int; let indexed_count: Int
    let total_chunks: Int; let per_file_chunks: [VTTPerFileChunks]
    let index_seconds: Double; let extract_seconds: Double; let embed_span_seconds: Double
    let db_seconds: Double; let search_seconds: Double
    let rss_before_index_bytes: UInt64; let rss_after_index_bytes: UInt64
    let metrics: VTTArmMetrics; let noise_stats: VTTNoiseStats; let no_answer_probes: [VTTNoAnswerProbe]
}

struct VTTComparisonCell: Codable {
    let file_rank: Int?; let reciprocal_rank: Double; let all_criteria_met: Bool?
    let top_file: String?; let top_score: Double?
}
struct VTTComparisonRow: Codable { let id: String; let is_no_answer: Bool; let arms: [String: VTTComparisonCell] }
struct VTTComparison: Codable { let arms: [String]; let per_query: [VTTComparisonRow]; let aggregate: [String: VTTArmMetrics] }

/// Hard-failure error for setup problems that must abort the benchmark.
struct VTTHarnessError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
