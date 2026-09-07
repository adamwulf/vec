import XCTest
import Foundation
import Darwin
import CryptoKit
@testable import VecKit

/// E12 — reproducible image-OCR benchmarks.
///
/// Two heavy, opt-in benchmarks plus always-on cheap guards.
///
/// 1. `testImageOCRRetrievalBenchmark` — retrieval quality of OCR-indexed
///    images. Compares two arms against ONE frozen image snapshot, the real
///    `e5-base-v2` embedder pinned at `e5-base@1200/0`, identical geometry
///    and batch/bucket, through the PRODUCTION path (real `FileScanner`, real
///    `IndexingPipeline`, real `TextExtractor`):
///      - `raw`          — the production scanner in `.raw` mode indexes ZERO
///                         images (the true, un-faked baseline: image text is
///                         invisible without OCR);
///      - `image-ocr-v1` — the scanner discovers every image and the pipeline
///                         OCRs and indexes it.
///    Only the extraction mode differs; no inference change is introduced.
///
/// 2. `testImageOCRThroughputBenchmark` — OCR cost. Drives `ImageOCRCache`
///    directly (real `ImageOCR` recognizer) at 1/4/8 concurrent jobs, cold
///    (fresh cache) then warm (fresh cache instance over the populated
///    directory → disk-sidecar hits), recording authoritative
///    `ImageOCRCacheStatistics` (hits/misses/ocrCalls), wall-clock,
///    sampled + peak RSS, and a linear extrapolation to a 325k-image corpus.
///
/// HEAVY, opt-in: both are skipped unless `VEC_E12_BENCHMARK=1`. The retrieval
/// benchmark additionally loads the pinned E5 bundle from
/// `VEC_E12_MODEL_DIRECTORY` (default: the same pinned E5 bundle E10/E11 used)
/// and NEVER downloads. The throughput benchmark needs no model.
///
///     VEC_E12_BENCHMARK=1 \
///     VEC_E12_MODEL_DIRECTORY=/private/tmp/vec-e10-model/<rev> \
///     swift test --disable-sandbox --disable-swift-testing -c release -j 4 \
///       --filter VecKitTests.ImageOCRRetrievalExperimentTests
///
/// See `experiments/E12-image-ocr/harness-notes.md`.
///
/// Invariants carried over from E10/E11 unchanged: freeze (hash all inputs +
/// model files) BEFORE any ranking; preflight every arm/query BEFORE any work;
/// refuse to reuse a non-empty output dir; rebuild an interrupted arm rather
/// than trust partial data; fail immediately on any skipped / partial-failed
/// file; snapshot bodies stay scratch-only and are removed on teardown (no
/// corpus body committed into the archive — only hashes, counts, and metrics).
///
/// E12-specific:
/// - the frozen corpus is images (`ImageOCR.supportedExtensions`), discovered
///   recursively; a corpus-count mismatch FAILS the run (fixed committed
///   sample), as in E11;
/// - the raw arm is EXPECTED to index zero images — the production scanner's
///   `.raw` mode excludes them — so its aggregate is an honest 0% floor, not
///   a bug;
/// - the passage audit reconstructs the retrieved chunk BY ORDINAL from the
///   arm's own extractor (which resolves through the SAME OCR cache the
///   pipeline used, so re-extraction is a cache hit and matches the embedded
///   text) and checks the criteria against `E5BaseEmbedder.normalizeInputs`
///   pre-tokenizer input.
final class ImageOCRRetrievalExperimentTests: XCTestCase {

    private enum Env {
        static let enable = "VEC_E12_BENCHMARK"
        static let modelDirectory = "VEC_E12_MODEL_DIRECTORY"
        static let modelRevision = "VEC_E12_MODEL_REVISION"
        static let corpusDirectory = "VEC_E12_CORPUS_DIRECTORY"
        static let outputDirectory = "VEC_E12_OUTPUT_DIRECTORY"
        static let scratchDirectory = "VEC_E12_SCRATCH_DIRECTORY"
        static let concurrency = "VEC_E12_CONCURRENCY"
        static let ocrConcurrency = "VEC_E12_OCR_CONCURRENCY"
        static let manifest = "VEC_E12_MANIFEST"
        // Throughput-only knobs.
        static let ocrCorpusDirectory = "VEC_E12_OCR_CORPUS_DIRECTORY"
        static let ocrOutputDirectory = "VEC_E12_OCR_OUTPUT_DIRECTORY"
        static let ocrJobs = "VEC_E12_OCR_JOBS"
        static let targetCount = "VEC_E12_TARGET_COUNT"
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
    private static let defaultTargetCount = 325_000
    private static let defaultJobs = [1, 4, 8]

    private var scratchRoot: URL!

    override func tearDown() {
        // Remove only the unique child we own; never the caller's override.
        if let scratchRoot {
            try? FileManager.default.removeItem(at: scratchRoot)
        }
        super.tearDown()
    }

    // MARK: - Retrieval benchmark

    func testImageOCRRetrievalBenchmark() async throws {
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
            throw E12HarnessError("model directory \(modelDirRaw) is not an existing directory. The benchmark must not download the model; point \(Env.modelDirectory) at the pinned e5-base-v2 bundle.")
        }
        let modelRevision = env[Env.modelRevision] ?? modelDir.lastPathComponent

        let corpusDir = resolvedURL(env[Env.corpusDirectory] ?? Self.defaultCorpusDirectory().path)
        guard FileManager.default.fileExists(atPath: corpusDir.path) else {
            throw E12HarnessError("Corpus directory \(corpusDir.path) does not exist (override with \(Env.corpusDirectory)).")
        }

        let concurrency = try positiveIntEnv(env[Env.concurrency], name: Env.concurrency, fallback: IndexingPipeline.defaultConcurrency)
        // OCR concurrency for the production path. Correctness is independent
        // of this; it only affects extract-stage speed. Default 4.
        let ocrConcurrency = try positiveIntEnv(env[Env.ocrConcurrency], name: Env.ocrConcurrency, fallback: 4)

        let outputDir = try prepareOutputDirectory(env[Env.outputDirectory], prefix: "vec-e12-out")
        logLine("[e12] output/archive directory: \(outputDir.path)")

        scratchRoot = try makeScratchRoot(env[Env.scratchDirectory])
        let snapshotRoot = scratchRoot.appendingPathComponent("snapshot", isDirectory: true)

        // Load + PREFLIGHT the fixed manifest before any work.
        let manifestURL = try locateManifest(env)
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(E12RubricManifest.self, from: manifestData)
        let manifestSHA = sha256Hex(manifestData)
        try E12Preflight.validate(manifest)
        logLine("[e12] preflight OK: \(manifest.arms.count) arms, \(manifest.queries.count) queries")

        // ===== FREEZE (before any ranking) =====
        let frozenFiles = try freezeImageSnapshot(from: corpusDir, to: snapshotRoot)
        logLine("[e12] froze \(frozenFiles.count) image file(s)")
        XCTAssertGreaterThan(frozenFiles.count, 0, "Snapshot must contain at least one image")
        // E12 FAILS on drift: the sample is a fixed committed corpus.
        if let expected = manifest.corpus?.expected_image_files, frozenFiles.count != expected {
            throw E12HarnessError("frozen image file count \(frozenFiles.count) != manifest expected_image_files \(expected). The E12 sample is a fixed committed corpus; a mismatch means the sample is wrong. E12 fails on drift; it does not warn.")
        }
        try validateLabeledFilesExist(manifest: manifest, snapshotRoot: snapshotRoot)

        // ===== SAMPLE MANIFEST (anti-drift) =====
        let sampleManifestURL = corpusDir.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: sampleManifestURL.path) else {
            throw E12HarnessError("sample manifest not found at \(sampleManifestURL.path). freeze-sample.py writes it next to the image sample; the benchmark refuses to run without it.")
        }
        let sampleManifestData = try Data(contentsOf: sampleManifestURL)
        let sampleManifest = try JSONDecoder().decode(E12SampleManifest.self, from: sampleManifestData)
        let sampleManifestSHA = sha256Hex(sampleManifestData)
        try E12SampleManifestCheck.verify(sample: sampleManifest, against: frozenFiles)
        try sampleManifestData.write(to: outputDir.appendingPathComponent("sample-manifest.json"))
        logLine("[e12] sample manifest verified against snapshot (\(sampleManifest.files.count) files) and archived")

        let modelFiles = try hashDirectoryFiles(modelDir)
        XCTAssertGreaterThan(modelFiles.count, 0, "Model directory must contain files to hash")

        let settings = E12FrozenSettings(
            profile_identity: Self.profileIdentity, embedder: "e5-base-v2", dimension: 768,
            chunk_chars: Self.chunkChars, chunk_overlap: Self.chunkOverlap, concurrency: concurrency,
            ocr_concurrency: ocrConcurrency, batch_size: IndexingPipeline.defaultBatchSize,
            bucket_width: IndexingPipeline.defaultBucketWidth, compute_policy: "default(nil)",
            search_limit: Self.searchLimit, coalesce_limit: Self.coalesceLimit, raw_fetch_limit: Self.rawFetchLimit,
            ocr_recognizer_version: ImageOCR.version, ocr_request_revision: ImageOCR.requestRevision,
            ocr_max_pixel_dimension: ImageOCR.maxPixelDimension)
        let runIdentity = computeRunIdentity(files: frozenFiles, modelFiles: modelFiles,
                                             manifestSHA: manifestSHA, sampleManifestSHA: sampleManifestSHA,
                                             settings: settings)

        let frozen = E12FrozenInputManifest(
            experiment: "E12-image-ocr", run_identity: runIdentity,
            frozen_at: ISO8601DateFormatter().string(from: Date()),
            corpus_source: corpusDir.path,
            corpus_scope: manifest.corpus?.scope ?? "Image-only; discovered recursively via ImageOCR.supportedExtensions.",
            files: frozenFiles, file_count: frozenFiles.count,
            query_manifest_path: relativeToRepo(manifestURL), query_manifest_sha256: manifestSHA,
            query_count: manifest.queries.count,
            sample_manifest_path: sampleManifestURL.path, sample_manifest_sha256: sampleManifestSHA,
            model_directory: modelDir.path, model_revision: modelRevision, model_files: modelFiles,
            build: buildIdentity(), settings: settings)
        try writeJSON(frozen, to: outputDir.appendingPathComponent("frozen-input-manifest.json"))
        try writeExecutionCommand([
            "command (representative):",
            "  VEC_E12_BENCHMARK=1 \\",
            "  VEC_E12_MODEL_DIRECTORY=\(modelDir.path) \\",
            "  VEC_E12_MODEL_REVISION=\(modelRevision) \\",
            "  VEC_E12_CORPUS_DIRECTORY=\(corpusDir.path) \\",
            "  VEC_E12_CONCURRENCY=\(concurrency) VEC_E12_OCR_CONCURRENCY=\(ocrConcurrency) \\",
            "  VEC_E12_OUTPUT_DIRECTORY=\(outputDir.path) \\",
            "  swift test --disable-sandbox --disable-swift-testing -c release -j 4 \\",
            "    --filter VecKitTests.ImageOCRRetrievalExperimentTests/testImageOCRRetrievalBenchmark",
            "",
            "run_identity: \(runIdentity)",
            "git_head: \(frozen.build.git_head ?? "?")  git_dirty: \(String(describing: frozen.build.git_dirty))",
            "package_resolved_sha256: \(frozen.build.package_resolved_sha256 ?? "?")",
            "os_version: \(frozen.build.os_version)  cores: \(frozen.build.active_processor_count)  host: \(frozen.build.host_name)",
            "swift: \(frozen.build.swift_version ?? "?")",
            "model_directory: \(modelDir.path)  revision: \(modelRevision)  model_files_hashed: \(modelFiles.count)",
            "settings: \(Self.profileIdentity), chunk \(Self.chunkChars)/\(Self.chunkOverlap), concurrency \(concurrency), ocrConcurrency \(ocrConcurrency), batch \(IndexingPipeline.defaultBatchSize), bucket \(IndexingPipeline.defaultBucketWidth)",
            "ocr: ImageOCR v\(ImageOCR.version), requestRevision \(ImageOCR.requestRevision), maxPixelDimension \(ImageOCR.maxPixelDimension)",
            "memory scope: process-wide RSS via task_info, before/after indexing only (NOT OCR-isolated).",
        ], to: outputDir.appendingPathComponent("execution-command.txt"))
        logLine("[e12] freeze complete — run_identity=\(runIdentity). Ranking begins now.")

        // ===== ARMS (each into a fresh DB) =====
        var armSummaries: [E12ArmSummary] = []
        var perArm: [String: [String: E12QueryResult]] = [:]
        for arm in manifest.arms {
            let mode = TextExtractionMode(rawValue: arm.text_extraction)!   // validated in preflight
            logLine("[e12] === arm '\(arm.key)' (textExtraction=\(mode.rawValue)) ===")
            let (summary, results) = try await runArm(arm: arm, mode: mode, snapshotRoot: snapshotRoot,
                                                      modelDir: modelDir, concurrency: concurrency,
                                                      ocrConcurrency: ocrConcurrency, manifest: manifest,
                                                      outputDir: outputDir)
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
        logLine("[e12] retrieval done. Archive at \(outputDir.path)")
    }

    // MARK: - One retrieval arm

    private func runArm(arm: E12RubricManifest.Arm, mode: TextExtractionMode, snapshotRoot: URL,
                        modelDir: URL, concurrency: Int, ocrConcurrency: Int, manifest: E12RubricManifest,
                        outputDir: URL) async throws -> (E12ArmSummary, [E12QueryResult]) {
        let armOut = outputDir.appendingPathComponent(arm.key, isDirectory: true)
        try FileManager.default.createDirectory(at: armOut, withIntermediateDirectories: true)
        let dbDir = scratchRoot.appendingPathComponent("db-\(arm.key)", isDirectory: true)
        let ocrCacheDir = scratchRoot.appendingPathComponent("ocr-cache-\(arm.key)", isDirectory: true)

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

        // PRODUCTION scanner: `.raw` returns zero images (true baseline);
        // `.imageOCRV1` discovers every image. No harness-side filtering.
        let files = try FileScanner(directory: snapshotRoot, textExtraction: mode).scan()
        let workItems = files.map { (file: $0, label: "Added") }
        let extractor = TextExtractor(splitter: profile.splitter, textExtraction: mode, ocrCacheDirectory: ocrCacheDir)
        let pipeline = IndexingPipeline(concurrency: concurrency, ocrConcurrency: ocrConcurrency,
                                        batchSize: IndexingPipeline.defaultBatchSize,
                                        bucketWidth: IndexingPipeline.defaultBucketWidth, profile: profile)

        let rssBefore = residentBytes()
        let indexStart = DispatchTime.now()
        let (indexResults, stats) = try await pipeline.run(workItems: workItems, extractor: extractor, database: db)
        let indexSeconds = Self.elapsed(since: indexStart)
        let rssAfter = residentBytes()

        // Account for every scanned file. A text-less image (e.g. the app-icon
        // distractor) legitimately OCRs to blank -> zero chunks -> the pipeline
        // records `.skippedUnreadable`. That is NOT a failure for images, so we
        // count it as a blank rather than aborting; a GENUINE read error would
        // also surface as `.skippedUnreadable`, but the per-file re-extraction
        // loop below re-opens every scanned file and THROWS on a real read
        // error, so a true failure still aborts the run. `.skippedEmbedFailure`
        // (chunks produced but every embed failed) and any `.indexed` with a
        // failed chunk are hard failures.
        var indexedCount = 0
        var blankCount = 0
        var failures: [String] = []
        for r in indexResults {
            switch r {
            case .indexed(let p, _, _, let failed):
                indexedCount += 1
                if failed > 0 { failures.append("\(p): \(failed) chunk(s) failed to embed") }
            case .skippedUnreadable: blankCount += 1
            case .skippedEmbedFailure(let p): failures.append("\(p): skippedEmbedFailure")
            }
        }
        guard failures.isEmpty else {
            throw E12HarnessError("arm \(arm.key): index incomplete — \(failures.joined(separator: "; "))")
        }
        guard indexedCount + blankCount == files.count else {
            throw E12HarnessError("arm \(arm.key): accounted \(indexedCount) indexed + \(blankCount) blank != \(files.count) scanned")
        }
        let totalChunks = try await db.totalChunkCount()

        // OCR-cache counters AS OF THE END OF INDEXING — captured BEFORE the
        // audit re-extraction below adds cache hits, so this reflects the
        // indexing phase alone (misses/ocrCalls during the real pipeline run).
        let cacheAfterIndex = Self.cacheStats(extractor.ocrCacheStatistics)

        // Authoritative completeness guard: EVERY scanned file must be
        // recorded in the DB's indexed set, INCLUDING a zero-chunk blank
        // image (a text-less image OCRs to blank and is still markFileIndexed).
        // A transient read error does NOT mark the file indexed, so it would
        // be missing here — this catches the read-error case directly at the
        // DB, so a "blank" audit can never mask a failed read. It also rejects
        // any file indexed that was not scanned (a contaminated DB).
        let indexedSet = Set(try await db.allIndexedFiles().keys)
        let scannedSet = Set(files.map { $0.relativePath })
        let notIndexed = scannedSet.subtracting(indexedSet)
        guard notIndexed.isEmpty else {
            throw E12HarnessError("arm \(arm.key): scanned but NOT recorded as indexed (transient read error?): \(notIndexed.sorted().joined(separator: ", "))")
        }
        let unexpectedIndexed = indexedSet.subtracting(scannedSet)
        guard unexpectedIndexed.isEmpty else {
            throw E12HarnessError("arm \(arm.key): DB recorded files that were never scanned: \(unexpectedIndexed.sorted().joined(separator: ", "))")
        }

        // Re-extract each file with the arm's extractor so we can audit
        // passages by ordinal. The extractor resolves through the SAME OCR
        // cache dir the pipeline used, so re-extraction is a deterministic
        // cache hit and matches the indexed chunk set 1:1 in order.
        var chunkCache: [String: [TextChunk]] = [:]
        func extractedChunks(_ path: String) throws -> [TextChunk] {
            if let c = chunkCache[path] { return c }
            let info = try FileScanner.fileInfo(for: snapshotRoot.appendingPathComponent(path), relativeTo: snapshotRoot)
            let c = try extractor.extract(from: info).chunks
            chunkCache[path] = c
            return c
        }

        var perFileChunks: [E12PerFileChunks] = []
        for file in files {
            let dbCount = try await db.chunkCount(filePath: file.relativePath)
            let chunks = try extractedChunks(file.relativePath)
            XCTAssertEqual(chunks.count, dbCount,
                           "arm \(arm.key) \(file.relativePath): re-extracted chunk count \(chunks.count) != DB count \(dbCount); the ordinal-based audit assumes they match")
            let ocrChars = chunks.map { $0.text.count }.reduce(0, +)
            perFileChunks.append(E12PerFileChunks(path: file.relativePath, chunks: dbCount,
                                                  ocr_chars: ocrChars, is_blank: chunks.isEmpty))
        }
        perFileChunks.sort { $0.path < $1.path }
        // Cache counters AFTER the audit re-extraction (which turns every
        // indexed image into a cache hit). Kept separate from cacheAfterIndex.
        let cacheAfterAudit = Self.cacheStats(extractor.ocrCacheStatistics)
        logLine("[e12] arm \(arm.key): scanned=\(files.count) indexed=\(indexedCount) blank=\(blankCount) chunks=\(totalChunks) index=\(fmt2(indexSeconds))s extract=\(fmt2(stats.extractSeconds))s embedSpan=\(fmt2(stats.embedSeconds))s db=\(fmt2(stats.dbSeconds))s rss=\(fmtMB(rssAfter)) ocrCache(afterIndex)=\(cacheAfterIndex.map { "h\($0.hits)/m\($0.misses)/o\($0.ocr_calls)" } ?? "nil")")

        // ---- Search (persist each query immediately) ----
        var results: [E12QueryResult] = []
        var ordinalsCache: [String: [Int64: Int]] = [:]
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

            var archivedGroups: [E12ArchivedGroup] = []
            for (i, g) in groups.enumerated() {
                let ords = try await ordinals(g.filePath)
                let matches = g.matches.map { m in
                    E12ArchivedMatch(score: max(0, 1 - m.distance), distance: m.distance,
                                     chunk_type: m.chunkType.rawValue, line_start: m.lineStart,
                                     line_end: m.lineEnd, chunk_ordinal: ords[m.chunkId])
                }
                archivedGroups.append(E12ArchivedGroup(rank: i + 1, file: g.filePath,
                                                       best_score: g.bestScore, match_count: g.matches.count, matches: matches))
            }

            let isNoAnswer = (q.primary_file == nil)
            var fileRank: Int? = nil
            var reciprocal = 0.0
            var audit: E12PrimaryAudit? = nil

            if let primary = q.primary_file, let idx = groups.firstIndex(where: { $0.filePath == primary }) {
                fileRank = idx + 1
                reciprocal = 1.0 / Double(idx + 1)
                let best = groups[idx].matches.first!
                let ords = try await ordinals(primary)
                let ordinal = ords[best.chunkId]

                // Pre-tokenizer model input for the retrieved chunk: the string
                // the E5 document path feeds the tokenizer (the "passage: "
                // prefix prepended, then capped at the E5 char limit — the
                // shared `E5BaseEmbedder.normalizeInputs` helper). Reconstructed
                // BY ORDINAL from the arm's own extractor so it is the actual
                // OCR text embedded (resolved via the same cache). Advisory: the
                // tokenizer truncates further to 512 tokens, so a match here is
                // necessary but NOT sufficient, and it does not gate file rank.
                var preTokenizerInput = ""
                if let ordinal, ordinal >= 1 {
                    let chunks = try extractedChunks(primary)
                    if ordinal <= chunks.count {
                        preTokenizerInput = E5BaseEmbedder.normalizeInputs(
                            [chunks[ordinal - 1].text], prefix: "passage: ").liveInputs.first ?? ""
                    }
                }

                var crits: [E12CriterionResult] = []
                for c in q.passage_criteria {
                    crits.append(E12CriterionResult(type: c.type, value: c.value,
                                                    matched_in_ocr_text: matches(c, in: preTokenizerInput)))
                }
                audit = E12PrimaryAudit(
                    file_rank: idx + 1, best_score: groups[idx].bestScore, distance: best.distance,
                    chunk_type: best.chunkType.rawValue, chunk_ordinal: ordinal,
                    input_chars: preTokenizerInput.count, criteria: crits,
                    all_criteria_met: !crits.isEmpty && crits.allSatisfy { $0.matched_in_ocr_text })
            }

            let result = E12QueryResult(
                arm: arm.key, id: q.id, text: q.text, categories: q.categories,
                origin: originForPrimary(q.primary_file),
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
        let metrics = E12ArmMetrics(
            answered_queries: answered.count,
            rank1_rate: rate(answered, over: answered) { $0.hit_at_1 },
            top3_rate: rate(answered, over: answered) { $0.hit_at_3 },
            top5_rate: rate(answered, over: answered) { $0.hit_at_5 },
            mean_reciprocal_rank: mrr(answered, over: answered),
            passage_all_met_rate: rate(answered, over: answered) { $0.primary_audit?.all_criteria_met == true },
            real_answered: answered.filter { $0.origin == "real" }.count,
            real_rank1_rate: rate(answered.filter { $0.origin == "real" }, over: answered.filter { $0.origin == "real" }) { $0.hit_at_1 },
            real_mrr: mrr(answered.filter { $0.origin == "real" }, over: answered.filter { $0.origin == "real" }),
            synthetic_answered: answered.filter { $0.origin == "synthetic" }.count,
            synthetic_rank1_rate: rate(answered.filter { $0.origin == "synthetic" }, over: answered.filter { $0.origin == "synthetic" }) { $0.hit_at_1 },
            synthetic_mrr: mrr(answered.filter { $0.origin == "synthetic" }, over: answered.filter { $0.origin == "synthetic" }))
        let summary = E12ArmSummary(
            arm: arm.key, text_extraction: mode.rawValue, file_count: files.count, indexed_count: indexedCount,
            blank_count: blankCount, total_chunks: totalChunks, per_file_chunks: perFileChunks, index_seconds: indexSeconds,
            extract_seconds: stats.extractSeconds, embed_span_seconds: stats.embedSeconds, db_seconds: stats.dbSeconds,
            search_seconds: searchSecondsTotal, rss_before_index_bytes: rssBefore, rss_after_index_bytes: rssAfter,
            ocr_cache_after_index: cacheAfterIndex, ocr_cache_after_audit: cacheAfterAudit, metrics: metrics)
        try writeJSON(summary, to: armOut.appendingPathComponent("arm-summary.json"))
        return (summary, results)
    }

    // MARK: - Throughput / cold-warm-cache benchmark

    func testImageOCRThroughputBenchmark() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            env[Env.enable] == "1",
            "Heavy opt-in benchmark — set \(Env.enable)=1 to run (real Vision OCR; see harness-notes.md)."
        )

        let corpusDir = resolvedURL(env[Env.ocrCorpusDirectory] ?? Self.defaultCorpusDirectory().path)
        guard FileManager.default.fileExists(atPath: corpusDir.path) else {
            throw E12HarnessError("OCR corpus directory \(corpusDir.path) does not exist (override with \(Env.ocrCorpusDirectory)).")
        }
        let jobsSweep = try parseJobs(env[Env.ocrJobs]) ?? Self.defaultJobs
        let targetCount = try positiveIntEnv(env[Env.targetCount], name: Env.targetCount, fallback: Self.defaultTargetCount)

        let outputDir = try prepareOutputDirectory(env[Env.ocrOutputDirectory], prefix: "vec-e12-ocr")
        scratchRoot = try makeScratchRoot(env[Env.scratchDirectory])

        // FREEZE the corpus into a sha256-pinned snapshot BEFORE any timing,
        // then OCR the SNAPSHOT — so cold and warm passes (and every job
        // count) read byte-identical inputs, and the exact bytes timed are
        // recorded in the archive.
        let snapshotRoot = scratchRoot.appendingPathComponent("ocr-snapshot", isDirectory: true)
        let frozenImages = try freezeImageSnapshot(from: corpusDir, to: snapshotRoot)
        let images = try discoverImages(in: snapshotRoot)
        guard !images.isEmpty else {
            throw E12HarnessError("no images found under \(corpusDir.path) (extensions: \(ImageOCR.supportedExtensions.sorted().joined(separator: ", ")))")
        }
        XCTAssertEqual(images.count, frozenImages.count, "frozen snapshot count must match discovered images")
        logLine("[e12-ocr] corpus=\(corpusDir.path) froze \(frozenImages.count) images jobs=\(jobsSweep) target=\(targetCount)")

        var jobResults: [E12ThroughputJobResult] = []
        for jobs in jobsSweep {
            // COLD: a fresh cache directory + a fresh cache instance.
            let coldDir = scratchRoot.appendingPathComponent("ocr-cold-\(jobs)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: coldDir, withIntermediateDirectories: true)
            let coldCache = ImageOCRCache(directory: coldDir)
            let cold = try runOCRPass(cache: coldCache, images: images, jobs: jobs, targetCount: targetCount)
            logLine("[e12-ocr] jobs=\(jobs) COLD wall=\(fmt2(cold.wall_seconds))s rate=\(fmt2(cold.images_per_second))/s ok=\(cold.images_succeeded)/\(cold.images_attempted) fail=\(cold.images_failed) hits=\(cold.cache_hits) misses=\(cold.cache_misses) ocrCalls=\(cold.ocr_calls) peakRSS=\(fmtMB(cold.rss_peak_bytes))")

            // WARM: the SAME directory read by a FRESH cache instance whose
            // resident LRU starts empty, so every result is served from the
            // disk sidecar. This measures the disk-hit path only — it does NOT
            // reset process RSS or Vision's internal caches (see notes).
            let warmCache = ImageOCRCache(directory: coldDir)
            let warm = try runOCRPass(cache: warmCache, images: images, jobs: jobs, targetCount: targetCount)
            logLine("[e12-ocr] jobs=\(jobs) WARM wall=\(fmt2(warm.wall_seconds))s rate=\(fmt2(warm.images_per_second))/s ok=\(warm.images_succeeded)/\(warm.images_attempted) fail=\(warm.images_failed) hits=\(warm.cache_hits) misses=\(warm.cache_misses) ocrCalls=\(warm.ocr_calls) peakRSS=\(fmtMB(warm.rss_peak_bytes))")

            // Truth checks: for N distinct-byte images, cold does N OCR calls
            // and warm (fresh instance) does zero. Only assert when the corpus
            // is the frozen sample (an override corpus may contain byte-dupes
            // that single-flight/de-dupe, so we log instead of assert there).
            if env[Env.ocrCorpusDirectory] == nil {
                XCTAssertEqual(cold.ocr_calls, images.count, "cold pass must OCR every distinct image once")
                XCTAssertEqual(cold.cache_hits, 0, "cold pass over a fresh cache has no hits")
                XCTAssertEqual(warm.ocr_calls, 0, "warm pass (populated dir) must skip Vision entirely")
                XCTAssertEqual(warm.cache_hits, images.count, "warm pass must serve every image from cache")
            }
            jobResults.append(E12ThroughputJobResult(jobs: jobs, cold: cold, warm: warm))
        }

        let archive = E12ThroughputArchive(
            experiment: "E12-image-ocr", frozen_at: ISO8601DateFormatter().string(from: Date()),
            corpus_source: corpusDir.path, image_count: images.count, frozen_images: frozenImages,
            recognizer_version: ImageOCR.version, request_revision: ImageOCR.requestRevision,
            max_pixel_dimension: ImageOCR.maxPixelDimension,
            os_version: ProcessInfo.processInfo.operatingSystemVersionString,
            jobs_sweep: jobsSweep, target_estimate_count: targetCount, build: buildIdentity(),
            results: jobResults, notes: Self.throughputNotes)
        try writeJSON(archive, to: outputDir.appendingPathComponent("ocr-throughput.json"))
        try writeThroughputMarkdown(archive, to: outputDir.appendingPathComponent("ocr-throughput.md"))
        try writeExecutionCommand([
            "command (representative):",
            "  VEC_E12_BENCHMARK=1 \\",
            "  VEC_E12_OCR_CORPUS_DIRECTORY=\(corpusDir.path) \\",
            "  VEC_E12_OCR_JOBS=\(jobsSweep.map(String.init).joined(separator: ",")) VEC_E12_TARGET_COUNT=\(targetCount) \\",
            "  VEC_E12_OCR_OUTPUT_DIRECTORY=\(outputDir.path) \\",
            "  swift test --disable-sandbox --disable-swift-testing -c release -j 4 \\",
            "    --filter VecKitTests.ImageOCRRetrievalExperimentTests/testImageOCRThroughputBenchmark",
            "",
            "corpus: \(corpusDir.path)  images: \(images.count)",
            "git_head: \(archive.build.git_head ?? "?")  git_dirty: \(String(describing: archive.build.git_dirty))",
            "package_resolved_sha256: \(archive.build.package_resolved_sha256 ?? "?")",
            "os_version: \(archive.build.os_version)  cores: \(archive.build.active_processor_count)  host: \(archive.build.host_name)",
            "swift: \(archive.build.swift_version ?? "?")",
            "recognizer_version: \(archive.recognizer_version)  request_revision: \(archive.request_revision)  max_pixel_dimension: \(archive.max_pixel_dimension)  jobs: \(jobsSweep)",
            "frozen images: \(archive.image_count) (sha256-pinned snapshot; both passes read identical bytes)",
            "cache mode: cold = fresh dir + fresh cache instance; warm = same dir + FRESH ImageOCRCache instance (resident LRU empty -> disk-sidecar reads). NOT a fresh process: RSS + Vision caches persist across cold/warm/jobs.",
            "memory scope: process-wide RSS sampled on a background thread every 20 ms; peak = max(before, sampledPeak, after); includes Vision's own caches, NOT an OCR-only allocation figure. Jobs run sequentially (order bias); N is tiny by default.",
        ], to: outputDir.appendingPathComponent("execution-command.txt"))
        logLine("[e12-ocr] done. Archive at \(outputDir.path)")
    }

    private static let throughputNotes = [
        "Wall-clock and RSS are on the OCR recognizer only (ImageOCRCache + ImageOCR), driven by the harness at the stated job count; they do NOT include embedding or DB writes. All passes OCR a frozen, sha256-pinned snapshot (see frozen_images), so the bytes timed are provable and identical across cold, warm, and every job count.",
        "Cold = a fresh cache directory + a fresh ImageOCRCache instance. Warm = the SAME directory read by a FRESH ImageOCRCache instance whose resident LRU starts empty, so every result is served from the on-disk sidecar. This measures ONLY the disk-cache-hit path; it is NOT a fresh OS process. Process RSS and Vision's own internal caches PERSIST across the cold pass, the warm pass, and every job count within this single test process — so warm RSS is not a cold-start figure and cross-pass RSS deltas are not independent.",
        "Job counts run SEQUENTIALLY (1, then 4, then 8) in one process, so later iterations benefit from Vision/ANE warmup and OS file caches primed by earlier ones — a sequential-order bias that flatters higher job counts. With the tiny default corpus (18 frozen images) each pass is short and the rate is noisy; point VEC_E12_OCR_CORPUS_DIRECTORY at a larger frozen corpus for a stabler rate.",
        "RSS is process-wide (the whole test process, including Vision's caches and any resident OCR-cache entries), sampled on a background thread every ~20 ms; the reported peak is the max of the sampled peak and the immediate before/after reads, so a spike shorter than the sample interval can still be under-reported. It is a coarse proxy, not an OCR-only allocation figure.",
        "The target-count estimate is a LINEAR extrapolation of the measured images/second and assumes the frozen sample's image mix is representative — it is not (see the retrieval selection-bias note). Real-corpus images vary widely in size and text density, and ANE/Vision contention changes with scale, so treat the estimate as order-of-magnitude only.",
        "ImageOCR downscales any image whose largest side exceeds maxPixelDimension (4096) before recognition; small text in a very large image can be lost. This throughput number does not measure that fidelity loss.",
    ]

    /// One cold or warm pass: OCR every image at `jobs` concurrent OS threads,
    /// sampling RSS on a background thread. Tracks per-image success/failure
    /// and THROWS if any recognizer call errored (a blank OCR result is a
    /// SUCCESS, not a failure) — so a swallowed error can never inflate the
    /// rate. Returns wall-clock, throughput over succeeded images,
    /// authoritative cache statistics, RSS, and the target-count extrapolation.
    private func runOCRPass(cache: ImageOCRCache, images: [URL], jobs: Int, targetCount: Int) throws -> E12ThroughputPass {
        let sampler = E12RSSSampler(intervalMillis: 20)
        let rssBefore = residentBytes()
        sampler.start()
        let queue = DispatchQueue(label: "e12.ocr.jobs", attributes: .concurrent)
        let sem = DispatchSemaphore(value: jobs)
        let group = DispatchGroup()
        let lock = NSLock()
        var succeeded = 0
        var failures: [String] = []
        let start = DispatchTime.now()
        for url in images {
            sem.wait()
            group.enter()
            queue.async {
                defer { sem.signal(); group.leave() }
                do {
                    _ = try cache.recognizeText(in: url)
                    lock.lock(); succeeded += 1; lock.unlock()
                } catch {
                    lock.lock(); failures.append("\(url.lastPathComponent): \(error)"); lock.unlock()
                }
            }
        }
        group.wait()
        let wall = Self.elapsed(since: start)
        let rss = sampler.stop()
        let rssAfter = residentBytes()
        guard failures.isEmpty else {
            throw E12HarnessError("OCR pass (jobs=\(jobs)) had \(failures.count) recognizer failure(s) of \(images.count): \(failures.prefix(5).joined(separator: "; "))")
        }
        let imagesPerSec = wall > 0 ? Double(succeeded) / wall : 0
        let estimate = imagesPerSec > 0 ? Double(targetCount) / imagesPerSec : 0
        let stats = cache.statistics
        // Peak is the max of the sampled peak and the immediate before/after
        // reads, so a spike missed between samples is still bounded below by
        // the endpoints.
        let peak = max(rssBefore, max(rss.peak, rssAfter))
        return E12ThroughputPass(
            images_attempted: images.count, images_succeeded: succeeded, images_failed: failures.count,
            jobs: jobs, wall_seconds: wall, images_per_second: imagesPerSec,
            cache_hits: stats.hits, cache_misses: stats.misses, ocr_calls: stats.ocrCalls,
            rss_before_bytes: rssBefore, rss_peak_bytes: peak, rss_after_bytes: rssAfter,
            rss_sample_count: rss.count, rss_mean_bytes: rss.mean,
            estimate_target_seconds: estimate, estimate_target_count: targetCount)
    }

    // MARK: - Freeze helpers

    private func freezeImageSnapshot(from corpusDir: URL, to snapshotRoot: URL) throws -> [E12FrozenFile] {
        let fm = FileManager.default
        try fm.createDirectory(at: snapshotRoot, withIntermediateDirectories: true)
        var frozen: [E12FrozenFile] = []
        guard let en = fm.enumerator(at: corpusDir, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw VecError.cannotScanDirectory(corpusDir.path)
        }
        while let url = en.nextObject() as? URL {
            guard ImageOCR.supportedExtensions.contains(url.pathExtension.lowercased()) else { continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let rel = PathUtilities.relativePath(of: url.path, in: corpusDir.path)
            let dest = snapshotRoot.appendingPathComponent(rel)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: url, to: dest)
            let (bytes, hex) = try sha256File(dest)
            frozen.append(E12FrozenFile(path: rel, bytes: bytes, sha256: hex))
        }
        frozen.sort { $0.path < $1.path }
        return frozen
    }

    private func discoverImages(in dir: URL) throws -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw VecError.cannotScanDirectory(dir.path)
        }
        var urls: [URL] = []
        while let url = en.nextObject() as? URL {
            guard ImageOCR.supportedExtensions.contains(url.pathExtension.lowercased()) else { continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            urls.append(url)
        }
        return urls.sorted { $0.path < $1.path }
    }

    private func validateLabeledFilesExist(manifest: E12RubricManifest, snapshotRoot: URL) throws {
        var wanted = Set<String>()
        for q in manifest.queries {
            if let p = q.primary_file { wanted.insert(p) }
            for f in q.relevant_files { wanted.insert(f) }
        }
        let missing = wanted.filter { !FileManager.default.fileExists(atPath: snapshotRoot.appendingPathComponent($0).path) }
        guard missing.isEmpty else {
            throw E12HarnessError("labeled files missing from frozen snapshot: \(missing.sorted().joined(separator: ", "))")
        }
    }

    private func hashDirectoryFiles(_ dir: URL) throws -> [E12FrozenFile] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out: [E12FrozenFile] = []
        while let u = en.nextObject() as? URL {
            guard (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let (bytes, hex) = try sha256File(u)
            out.append(E12FrozenFile(path: PathUtilities.relativePath(of: u.path, in: dir.path), bytes: bytes, sha256: hex))
        }
        out.sort { $0.path < $1.path }
        return out
    }

    private func buildIdentity() -> E12BuildIdentity {
        #if DEBUG
        let config = "debug"
        #else
        let config = "release"
        #endif
        let repo = Self.repoRoot()
        let head = runCommand("/usr/bin/git", ["rev-parse", "HEAD"], cwd: repo)
        let dirty = runCommand("/usr/bin/git", ["status", "--porcelain", "-uno"], cwd: repo).map { !$0.isEmpty }
        let resolved = repo.appendingPathComponent("Package.resolved")
        let resolvedSHA = FileManager.default.fileExists(atPath: resolved.path) ? (try? sha256File(resolved).hex) : nil
        return E12BuildIdentity(
            configuration: config,
            os_version: ProcessInfo.processInfo.operatingSystemVersionString,
            active_processor_count: ProcessInfo.processInfo.activeProcessorCount,
            host_name: ProcessInfo.processInfo.hostName,
            swift_version: runCommand("/usr/bin/env", ["swift", "--version"]),
            git_head: head, git_dirty: dirty, package_resolved_sha256: resolvedSHA)
    }

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

    // MARK: - Audit + metric helpers

    private func matches(_ c: E12RubricManifest.Criterion, in haystack: String) -> Bool {
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

    private func originForPrimary(_ primary: String?) -> String {
        guard let p = primary else { return "none" }
        if p.hasPrefix("real/") { return "real" }
        if p.hasPrefix("synthetic/") { return "synthetic" }
        return "other"
    }

    /// Rate of a predicate over `subset`, using `denominator` for the divisor
    /// (so an empty subset yields 0 rather than a divide-by-zero).
    private func rate(_ subset: [E12QueryResult], over denominator: [E12QueryResult],
                      _ predicate: (E12QueryResult) -> Bool) -> Double {
        guard !denominator.isEmpty else { return 0 }
        return Double(subset.filter(predicate).count) / Double(denominator.count)
    }
    private func mrr(_ subset: [E12QueryResult], over denominator: [E12QueryResult]) -> Double {
        guard !denominator.isEmpty else { return 0 }
        return subset.map { $0.reciprocal_rank }.reduce(0, +) / Double(denominator.count)
    }

    // MARK: - Comparison + summary

    private func buildComparison(manifest: E12RubricManifest, perArm: [String: [String: E12QueryResult]],
                                 arms: [E12ArmSummary]) -> E12Comparison {
        let keys = manifest.arms.map { $0.key }
        var rows: [E12ComparisonRow] = []
        for q in manifest.queries {
            var byArm: [String: E12ComparisonCell] = [:]
            for k in keys {
                if let r = perArm[k]?[q.id] {
                    byArm[k] = E12ComparisonCell(file_rank: r.file_rank, reciprocal_rank: r.reciprocal_rank,
                                                 all_criteria_met: r.primary_audit?.all_criteria_met,
                                                 top_file: r.groups.first?.file, top_score: r.groups.first?.best_score)
                }
            }
            rows.append(E12ComparisonRow(id: q.id, origin: originForPrimary(q.primary_file),
                                         is_no_answer: q.primary_file == nil, arms: byArm))
        }
        return E12Comparison(arms: keys, per_query: rows,
                             aggregate: Dictionary(uniqueKeysWithValues: arms.map { ($0.arm, $0.metrics) }))
    }

    private func writeSummaryMarkdown(frozen: E12FrozenInputManifest, arms: [E12ArmSummary],
                                      comparison: E12Comparison, to url: URL) throws {
        var s = "# E12 image-OCR retrieval benchmark\n\n"
        s += "Run identity: `\(frozen.run_identity)`  \nFrozen at: \(frozen.frozen_at)\n\n"
        s += "Corpus: `\(frozen.corpus_source)` — \(frozen.file_count) image(s). "
        s += "Manifest sha256 `\(frozen.query_manifest_sha256.prefix(12))…` (\(frozen.query_count) queries). "
        s += "Model files hashed: \(frozen.model_files.count). Build: \(frozen.build.configuration), OS \(frozen.build.os_version). "
        s += "OCR recognizer v\(frozen.settings.ocr_recognizer_version), requestRevision \(frozen.settings.ocr_request_revision), maxPixelDim \(frozen.settings.ocr_max_pixel_dimension).\n\n"
        s += "Settings: `\(frozen.settings.profile_identity)`, chunk \(frozen.settings.chunk_chars)/\(frozen.settings.chunk_overlap), "
        s += "concurrency \(frozen.settings.concurrency), ocrConcurrency \(frozen.settings.ocr_concurrency), batch \(frozen.settings.batch_size), bucket \(frozen.settings.bucket_width).\n\n"

        s += "## Aggregate (answered queries only)\n\n"
        s += "| arm | rank1 | top3 | top5 | MRR | real rank1 | real MRR | synth rank1 | synth MRR | passage-met | scanned | indexed | chunks | index s | search s | RSS after |\n"
        s += "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|\n"
        for a in arms {
            let m = a.metrics
            s += "| \(a.arm) | \(pct(m.rank1_rate)) | \(pct(m.top3_rate)) | \(pct(m.top5_rate)) | \(fmt3(m.mean_reciprocal_rank)) | "
            s += "\(pct(m.real_rank1_rate)) | \(fmt3(m.real_mrr)) | \(pct(m.synthetic_rank1_rate)) | \(fmt3(m.synthetic_mrr)) | "
            s += "\(pct(m.passage_all_met_rate)) | \(a.file_count) | \(a.indexed_count) | \(a.total_chunks) | "
            s += "\(fmt2(a.index_seconds)) | \(fmt2(a.search_seconds)) | \(fmtMB(a.rss_after_index_bytes)) |\n"
        }
        s += "\n> File rank is authoritative. The `raw` arm indexes ZERO images by design (the production scanner excludes them), so its aggregate is an honest 0% floor, not a bug — it quantifies that image text is unreachable without OCR. `passage-met` is an advisory, case-insensitive check of the criteria against the PRE-TOKENIZER OCR input reconstructed by ordinal via `E5BaseEmbedder.normalizeInputs`; the tokenizer truncates further to 512 tokens, so a match is necessary but NOT sufficient, and it never gates file rank.\n\n"

        let keys = comparison.arms
        s += "## Per-query file rank (answered)\n\n| query | origin | " + keys.map { "\($0) rank" }.joined(separator: " | ") + " |\n"
        s += "|---|---|" + keys.map { _ in "---" }.joined(separator: "|") + "|\n"
        for row in comparison.per_query where !row.is_no_answer {
            let cells = keys.map { k -> String in row.arms[k]?.file_rank.map(String.init) ?? "—" }
            s += "| \(row.id) | \(row.origin) | " + cells.joined(separator: " | ") + " |\n"
        }
        s += "\nSee `comparison.json`, per-arm `arm-summary.json` (incl. per-file OCR chars), and per-query `<arm>/q*.json` (full ordered groups) for detail.\n\n"
        s += "### Caveats\n\n"
        s += "- Synthetic images are tiny, high-contrast, distinct-topic renders — an easy OCR + retrieval task, so the synthetic subset inflates the aggregate.\n"
        s += "- Real targets were hand-picked for legible, text-dominant content (a chart, two diagrams, a title thumbnail); this is NOT representative of the real thumbnail/photo-heavy image corpus.\n"
        s += "- Queries target what each image SAYS; no image assertion was fact-checked externally.\n"
        s += "- The raw baseline is an empty index; a raw-vs-OCR file-rank comparison is therefore trivially one-sided by construction.\n"
        try s.data(using: .utf8)!.write(to: url)
    }

    private func writeThroughputMarkdown(_ a: E12ThroughputArchive, to url: URL) throws {
        var s = "# E12 image-OCR throughput / cold-warm-cache benchmark\n\n"
        s += "Frozen at: \(a.frozen_at)  \nCorpus: `\(a.corpus_source)` — \(a.image_count) frozen (sha256-pinned) image(s). "
        s += "Recognizer v\(a.recognizer_version), requestRevision \(a.request_revision), maxPixelDim \(a.max_pixel_dimension). "
        s += "OS: \(a.os_version). Build: \(a.build.configuration), \(a.build.active_processor_count) cores. "
        s += "Target extrapolation: \(a.target_estimate_count) images.\n\n"
        s += "| jobs | pass | ok/att | fail | wall s | img/s | hits | misses | ocrCalls | peak RSS | mean RSS | est. \(a.target_estimate_count) |\n"
        s += "|---|---|---|---|---|---|---|---|---|---|---|---|\n"
        for r in a.results {
            for (label, p) in [("cold", r.cold), ("warm", r.warm)] {
                s += "| \(r.jobs) | \(label) | \(p.images_succeeded)/\(p.images_attempted) | \(p.images_failed) | "
                s += "\(fmt2(p.wall_seconds)) | \(fmt2(p.images_per_second)) | "
                s += "\(p.cache_hits) | \(p.cache_misses) | \(p.ocr_calls) | \(fmtMB(p.rss_peak_bytes)) | "
                s += "\(fmtMB(p.rss_mean_bytes)) | \(fmtHours(p.estimate_target_seconds)) |\n"
            }
        }
        s += "\n### Notes\n\n"
        for n in a.notes { s += "- \(n)\n" }
        try s.data(using: .utf8)!.write(to: url)
    }

    private func writeExecutionCommand(_ lines: [String], to url: URL) throws {
        let text = (["# E12 execution command + resolved provenance"] + lines).joined(separator: "\n") + "\n"
        try text.data(using: .utf8)!.write(to: url)
    }

    // MARK: - Directory / path helpers

    private func prepareOutputDirectory(_ raw: String?, prefix: String) throws -> URL {
        let fm = FileManager.default
        if let raw, !raw.isEmpty {
            let url = URL(fileURLWithPath: raw, isDirectory: true)
            if fm.fileExists(atPath: url.path) {
                let contents = ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).filter { $0 != ".DS_Store" }
                if !contents.isEmpty {
                    throw E12HarnessError("REFUSING to reuse non-empty output directory \(url.path). Point it at a fresh path; interrupted runs are rebuilt, not resumed.")
                }
            } else {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            }
            return url
        }
        let url = fm.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
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
        let child = E12Scratch.uniqueChild(under: base)
        try fm.createDirectory(at: child, withIntermediateDirectories: true)
        return resolvedURL(child.path)
    }

    private func locateManifest(_ env: [String: String]) throws -> URL {
        if let p = env[Env.manifest], !p.isEmpty { return URL(fileURLWithPath: p) }
        let url = Self.repoRoot().appendingPathComponent("experiments/E12-image-ocr/queries/rubric-queries.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw E12HarnessError("Query manifest not found at \(url.path); set \(Env.manifest).")
        }
        return url
    }

    private static func defaultCorpusDirectory() -> URL {
        repoRoot().appendingPathComponent("experiments/E12-image-ocr/sample", isDirectory: true)
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

    private func positiveIntEnv(_ raw: String?, name: String, fallback: Int) throws -> Int {
        guard let raw else { return fallback }
        guard let n = Int(raw), n >= 1 else {
            throw E12HarnessError("\(name) = '\(raw)' must be a positive integer.")
        }
        return n
    }

    private func parseJobs(_ raw: String?) throws -> [Int]? {
        guard let raw, !raw.isEmpty else { return nil }
        var out: [Int] = []
        for piece in raw.split(separator: ",") {
            guard let n = Int(piece.trimmingCharacters(in: .whitespaces)), n >= 1 else {
                throw E12HarnessError("\(Env.ocrJobs) = '\(raw)' must be a comma-separated list of positive integers.")
            }
            out.append(n)
        }
        return out.isEmpty ? nil : out
    }

    private func computeRunIdentity(files: [E12FrozenFile], modelFiles: [E12FrozenFile], manifestSHA: String,
                                    sampleManifestSHA: String, settings: E12FrozenSettings) -> String {
        var parts = files.map { "corpus:\($0.path):\($0.sha256)" }
        parts += modelFiles.map { "model:\($0.path):\($0.sha256)" }
        parts.append("manifest:\(manifestSHA)")
        parts.append("sample_manifest:\(sampleManifestSHA)")
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

    /// Maps the engine's (non-Codable) statistics snapshot into our Codable
    /// archive shape. nil when the extractor had no OCR cache configured.
    private static func cacheStats(_ s: ImageOCRCacheStatistics?) -> E12CacheStats? {
        guard let s else { return nil }
        return E12CacheStats(hits: s.hits, misses: s.misses, ocr_calls: s.ocrCalls)
    }

    private func residentBytes() -> UInt64 { E12Memory.residentBytes() }

    private func logLine(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
    private static func elapsed(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000_000
    }
    private func fmt2(_ d: Double) -> String { String(format: "%.2f", d) }
    private func fmt3(_ d: Double) -> String { String(format: "%.3f", d) }
    private func pct(_ d: Double) -> String { String(format: "%.0f%%", d * 100) }
    private func fmtMB(_ b: UInt64) -> String { String(format: "%.0f MB", Double(b) / 1_048_576) }
    private func fmtHours(_ s: Double) -> String {
        if s <= 0 { return "—" }
        if s < 90 { return String(format: "%.0f s", s) }
        if s < 5400 { return String(format: "%.1f min", s / 60) }
        return String(format: "%.1f h", s / 3600)
    }
}

// MARK: - Cheap, always-on validation (NOT behind the heavy gate)

/// Guards against manifest/enum drift, the scratch-ownership bug, the
/// ImageOCR extension set, and the OCR-cache hit/miss accounting — all without
/// the heavy gate, a model, a corpus, or real Vision. The committed manifest
/// may not exist yet, so its check SKIPS when absent rather than failing.
final class ImageOCRBenchmarkManifestTests: XCTestCase {

    private static func committedManifestURL() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("experiments/E12-image-ocr/queries/rubric-queries.json")
    }

    func testCommittedManifestPreflights() throws {
        let url = Self.committedManifestURL()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path),
                          "E12 rubric manifest not committed yet.")
        let data = try Data(contentsOf: url)
        let manifest = try JSONDecoder().decode(E12RubricManifest.self, from: data)
        XCTAssertNoThrow(try E12Preflight.validate(manifest), "committed manifest must preflight")
        for a in manifest.arms {
            XCTAssertNotNil(TextExtractionMode(rawValue: a.text_extraction),
                            "arm '\(a.key)' text_extraction '\(a.text_extraction)' must map to a TextExtractionMode")
        }
        XCTAssertEqual(Set(manifest.queries.map { $0.id }).count, manifest.queries.count, "query ids must be unique")
        XCTAssertFalse(manifest.queries.isEmpty)
        // E12 exists to compare raw vs image-ocr-v1; both arms must be present.
        XCTAssertTrue(manifest.arms.contains { $0.text_extraction == "raw" }, "manifest must declare a raw arm")
        XCTAssertTrue(manifest.arms.contains { $0.text_extraction == "image-ocr-v1" }, "manifest must declare an image-ocr-v1 arm")
        if let expected = manifest.corpus?.expected_image_files {
            XCTAssertGreaterThan(expected, 0, "expected_image_files must be positive")
        }
    }

    func testImageOCRSupportedExtensions() {
        // The nine fixed extensions the engine froze (avif is runtime-conditional
        // and NOT asserted; heif/svg/svgz are deliberately excluded).
        for ext in ["jpg", "jpeg", "png", "webp", "gif", "heic", "tiff", "tif", "bmp"] {
            XCTAssertTrue(ImageOCR.supportedExtensions.contains(ext), "ImageOCR must support .\(ext)")
        }
        XCTAssertFalse(ImageOCR.supportedExtensions.contains("heif"), "heif is not in the frozen set")
        XCTAssertFalse(ImageOCR.supportedExtensions.contains("svg"), "svg is rejected (XML, not OCR)")
        XCTAssertFalse(ImageOCR.supportedExtensions.contains("svgz"), "svgz is rejected")
        // The committed sample uses only png + jpg — both must be supported.
        XCTAssertTrue(ImageOCR.supportedExtensions.isSuperset(of: ["png", "jpg"]))
    }

    func testScratchChildIsOwnedNotCaller() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("vec-e12-owntest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let child = E12Scratch.uniqueChild(under: base)
        XCTAssertNotEqual(child.standardizedFileURL, base.standardizedFileURL, "scratch child must differ from the caller dir")
        XCTAssertEqual(child.deletingLastPathComponent().standardizedFileURL, base.standardizedFileURL,
                       "scratch child must live UNDER the caller dir so teardown never deletes the caller dir")
    }

    // MARK: OCR-cache accounting via an injected counting recognizer (no Vision)

    func testCacheAccountingColdThenWarmSameInstance() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vec-e12-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (a, b) = try Self.makeTwoDistinctImageFiles(in: dir)

        let fake = E12CountingRecognizer(text: "counting recognizer output")
        let cache = ImageOCRCache(directory: dir, recognizer: fake)
        // Cold: two distinct images → two OCR calls, no hits.
        _ = try cache.recognizeText(in: a)
        _ = try cache.recognizeText(in: b)
        XCTAssertEqual(fake.callCount, 2, "each distinct image invokes the recognizer once")
        var stats = cache.statistics
        XCTAssertEqual(stats.ocrCalls, 2)
        XCTAssertEqual(stats.misses, 2)
        XCTAssertEqual(stats.hits, 0)
        // Warm (same instance, resident LRU): re-read both → hits, no new calls.
        _ = try cache.recognizeText(in: a)
        _ = try cache.recognizeText(in: b)
        XCTAssertEqual(fake.callCount, 2, "resident cache serves repeats without new recognizer calls")
        stats = cache.statistics
        XCTAssertEqual(stats.ocrCalls, 2)
        XCTAssertEqual(stats.hits, 2)
    }

    func testCacheDiskSidecarReusedByFreshInstance() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vec-e12-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (a, b) = try Self.makeTwoDistinctImageFiles(in: dir)

        let coldFake = E12CountingRecognizer(text: "disk sidecar content")
        let cold = ImageOCRCache(directory: dir, recognizer: coldFake)
        _ = try cold.recognizeText(in: a)
        _ = try cold.recognizeText(in: b)
        XCTAssertEqual(coldFake.callCount, 2)

        // A FRESH instance over the SAME directory has an empty resident LRU;
        // it must serve both from the disk sidecars and NOT call the recognizer.
        let warmFake = E12CountingRecognizer(text: "should never be called")
        let warm = ImageOCRCache(directory: dir, recognizer: warmFake)
        let ra = try warm.recognizeText(in: a)
        let rb = try warm.recognizeText(in: b)
        XCTAssertEqual(warmFake.callCount, 0, "a fresh instance must reuse the disk sidecar, never re-OCR")
        let stats = warm.statistics
        XCTAssertEqual(stats.ocrCalls, 0)
        XCTAssertEqual(stats.hits, 2)
        XCTAssertEqual(stats.misses, 0)
        // The cached text is the cold recognizer's output, proving disk reuse.
        XCTAssertEqual(ra.text, "disk sidecar content")
        XCTAssertEqual(rb.text, "disk sidecar content")
    }

    /// Writes two files with DISTINCT bytes (distinct sha256) so the cache
    /// treats them as separate entries. The bytes need not be valid images —
    /// the counting recognizer ignores content and the cache keys on bytes.
    private static func makeTwoDistinctImageFiles(in dir: URL) throws -> (URL, URL) {
        let a = dir.appendingPathComponent("a.png")
        let b = dir.appendingPathComponent("b.png")
        try Data("first distinct image bytes".utf8).write(to: a)
        try Data("second distinct image bytes".utf8).write(to: b)
        return (a, b)
    }

    // MARK: Sample-manifest anti-drift verification

    private func frozen(_ path: String, _ bytes: Int, _ sha: String) -> E12FrozenFile {
        E12FrozenFile(path: path, bytes: bytes, sha256: sha)
    }
    private func sampleFile(_ path: String, _ bytes: Int, _ sha: String) -> E12SampleManifest.File {
        E12SampleManifest.File(path: path, bytes: bytes, sha256: sha)
    }

    func testSampleManifestMatches() {
        let snap = [frozen("real/a.png", 10, "aa"), frozen("synthetic/b.png", 20, "bb")]
        let sample = E12SampleManifest(files: [sampleFile("synthetic/b.png", 20, "BB"), sampleFile("real/a.png", 10, "aa")],
                                       real_files: 1, synthetic_files: 1)
        XCTAssertNoThrow(try E12SampleManifestCheck.verify(sample: sample, against: snap))
    }

    func testSampleManifestByteMismatchThrows() {
        let snap = [frozen("real/a.png", 10, "aa")]
        let sample = E12SampleManifest(files: [sampleFile("real/a.png", 11, "aa")], real_files: nil, synthetic_files: nil)
        XCTAssertThrowsError(try E12SampleManifestCheck.verify(sample: sample, against: snap))
    }

    func testSampleManifestHashMismatchThrows() {
        let snap = [frozen("real/a.png", 10, "aa")]
        let sample = E12SampleManifest(files: [sampleFile("real/a.png", 10, "zz")], real_files: nil, synthetic_files: nil)
        XCTAssertThrowsError(try E12SampleManifestCheck.verify(sample: sample, against: snap))
    }

    func testSampleManifestExtraSnapshotFileThrows() {
        let snap = [frozen("real/a.png", 10, "aa"), frozen("synthetic/b.png", 20, "bb")]
        let sample = E12SampleManifest(files: [sampleFile("real/a.png", 10, "aa")], real_files: nil, synthetic_files: nil)
        XCTAssertThrowsError(try E12SampleManifestCheck.verify(sample: sample, against: snap))
    }

    func testSampleManifestMissingSnapshotFileThrows() {
        let snap = [frozen("real/a.png", 10, "aa")]
        let sample = E12SampleManifest(files: [sampleFile("real/a.png", 10, "aa"), sampleFile("synthetic/b.png", 20, "bb")],
                                       real_files: nil, synthetic_files: nil)
        XCTAssertThrowsError(try E12SampleManifestCheck.verify(sample: sample, against: snap))
    }

    func testSampleManifestCountMismatchThrows() {
        let snap = [frozen("real/a.png", 10, "aa"), frozen("synthetic/b.png", 20, "bb")]
        let sample = E12SampleManifest(files: [sampleFile("real/a.png", 10, "aa"), sampleFile("synthetic/b.png", 20, "bb")],
                                       real_files: 1, synthetic_files: 2)
        XCTAssertThrowsError(try E12SampleManifestCheck.verify(sample: sample, against: snap))
    }

    func testSampleManifestIgnoresExtraFields() throws {
        let json = """
        {
          "schema_version": 1, "experiment": "E12-image-ocr",
          "frozen_at": "2026-09-07T00:00:00Z", "real_source": "/somewhere",
          "real_files": 1, "synthetic_files": 1, "target_files": 2, "scope": "images",
          "files": [
            {"path": "real/a.png", "bytes": 10, "sha256": "aa", "origin": "real", "role": "target", "source_path": "/x"},
            {"path": "synthetic/b.png", "bytes": 20, "sha256": "bb", "origin": "synthetic", "role": "target"}
          ]
        }
        """
        let m = try JSONDecoder().decode(E12SampleManifest.self, from: Data(json.utf8))
        XCTAssertEqual(m.files.count, 2)
        XCTAssertEqual(m.real_files, 1)
        XCTAssertEqual(m.synthetic_files, 1)
        XCTAssertEqual(m.files.first?.path, "real/a.png")
    }
}

// MARK: - Preflight + scratch + verifier (file-scope so the cheap tests use them)

enum E12Preflight {
    static func validate(_ m: E12RubricManifest) throws {
        guard !m.arms.isEmpty else { throw E12HarnessError("manifest has no arms") }
        var armKeys = Set<String>()
        for a in m.arms {
            guard TextExtractionMode(rawValue: a.text_extraction) != nil else {
                throw E12HarnessError("arm '\(a.key)': text_extraction '\(a.text_extraction)' is not a valid TextExtractionMode (valid: \(TextExtractionMode.allCases.map { $0.rawValue }.joined(separator: ", ")))")
            }
            guard isSafeKey(a.key) else { throw E12HarnessError("arm key '\(a.key)' is not filename-safe") }
            guard armKeys.insert(a.key).inserted else { throw E12HarnessError("duplicate arm key '\(a.key)'") }
        }
        guard !m.queries.isEmpty else { throw E12HarnessError("manifest has no queries") }
        var ids = Set<String>()
        for q in m.queries {
            guard isSafeKey(q.id) else { throw E12HarnessError("query id '\(q.id)' is not filename-safe") }
            guard ids.insert(q.id).inserted else { throw E12HarnessError("duplicate query id '\(q.id)'") }
            if q.primary_file == nil {
                guard q.relevant_files.isEmpty else { throw E12HarnessError("query '\(q.id)': no-answer query must have empty relevant_files") }
            } else if let p = q.primary_file, !q.relevant_files.contains(p) {
                throw E12HarnessError("query '\(q.id)': primary_file must be listed in relevant_files")
            }
        }
    }
    static func isSafeKey(_ s: String) -> Bool {
        !s.isEmpty && s != "." && s != ".." && s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
    }
}

enum E12Scratch {
    static func uniqueChild(under base: URL) -> URL {
        base.appendingPathComponent("vec-e12-scratch-\(UUID().uuidString)", isDirectory: true)
    }
}

/// Verifies the freeze-sample.py manifest against the frozen snapshot: EXACT
/// set equality on {path, bytes, sha256}, and — when both are present —
/// real_files + synthetic_files must sum to the file count.
enum E12SampleManifestCheck {
    static func verify(sample: E12SampleManifest, against frozen: [E12FrozenFile]) throws {
        var sampleByPath: [String: E12SampleManifest.File] = [:]
        for f in sample.files {
            guard sampleByPath.updateValue(f, forKey: f.path) == nil else {
                throw E12HarnessError("sample manifest has duplicate path '\(f.path)'")
            }
        }
        let frozenPaths = Set(frozen.map { $0.path })
        let samplePaths = Set(sampleByPath.keys)
        let missing = samplePaths.subtracting(frozenPaths)
        let extra = frozenPaths.subtracting(samplePaths)
        guard missing.isEmpty else {
            throw E12HarnessError("sample manifest lists file(s) absent from the frozen snapshot: \(missing.sorted().joined(separator: ", "))")
        }
        guard extra.isEmpty else {
            throw E12HarnessError("frozen snapshot contains file(s) not in the sample manifest: \(extra.sorted().joined(separator: ", "))")
        }
        for f in frozen {
            let s = sampleByPath[f.path]!
            guard s.bytes == f.bytes else {
                throw E12HarnessError("sample manifest byte mismatch for '\(f.path)': manifest \(s.bytes) != snapshot \(f.bytes)")
            }
            guard s.sha256.lowercased() == f.sha256.lowercased() else {
                throw E12HarnessError("sample manifest sha256 mismatch for '\(f.path)': manifest \(s.sha256) != snapshot \(f.sha256)")
            }
        }
        if let real = sample.real_files, let synth = sample.synthetic_files, real + synth != frozen.count {
            throw E12HarnessError("sample manifest real_files (\(real)) + synthetic_files (\(synth)) != frozen file count (\(frozen.count))")
        }
    }
}

/// A deterministic `ImageTextRecognizer` for the always-on cache tests: it
/// returns fixed text and counts how many times it is actually invoked, so a
/// test can prove the cache served a hit (no call) vs a miss (one call).
final class E12CountingRecognizer: ImageTextRecognizer, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let text: String
    init(text: String) { self.text = text }
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    func recognizeText(in imageURL: URL) throws -> ImageOCRResult {
        lock.lock(); count += 1; lock.unlock()
        return ImageOCRResult(text: text, lines: [text], paragraphs: [text])
    }
}

// MARK: - Resident-memory sampler

/// Coarse process-wide RSS sampler. Reads `mach_task_basic_info` on a
/// background thread at a fixed interval while a pass runs, then reports the
/// peak, sample count, and mean. Sampling can miss a spike shorter than the
/// interval; the peak is also floored by the immediate before/after reads at
/// the call site.
final class E12RSSSampler: @unchecked Sendable {
    private let intervalMicros: UInt32
    private let lock = NSLock()
    private var running = false
    private var peak: UInt64 = 0
    private var sum: Double = 0
    private var count: Int = 0

    init(intervalMillis: UInt32) { self.intervalMicros = intervalMillis * 1000 }

    func start() {
        lock.lock(); running = true; peak = 0; sum = 0; count = 0; lock.unlock()
        Thread.detachNewThread { [weak self] in
            guard let self else { return }
            while true {
                self.lock.lock()
                let go = self.running
                self.lock.unlock()
                if !go { break }
                let rss = E12Memory.residentBytes()
                self.lock.lock()
                if rss > self.peak { self.peak = rss }
                self.sum += Double(rss); self.count += 1
                self.lock.unlock()
                usleep(self.intervalMicros)
            }
        }
    }

    func stop() -> (peak: UInt64, mean: UInt64, count: Int) {
        lock.lock(); running = false
        let p = peak, c = count, m = count > 0 ? UInt64(sum / Double(count)) : 0
        lock.unlock()
        return (p, m, c)
    }
}

enum E12Memory {
    static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var countN = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(countN)) { p in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), p, &countN)
            }
        }
        return kr == KERN_SUCCESS ? info.resident_size : 0
    }
}

// MARK: - Manifest decoding

struct E12RubricManifest: Codable {
    struct Corpus: Codable { let scope: String?; let expected_image_files: Int? }
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

/// freeze-sample.py output (`<corpus>/manifest.json`). Only the verified fields
/// are decoded; every extra metadata field (schema_version, experiment,
/// frozen_at, real_source, target_files, scope, per-file origin/role/source_path)
/// is ignored on decode.
struct E12SampleManifest: Codable {
    struct File: Codable { let path: String; let bytes: Int; let sha256: String }
    let files: [File]
    let real_files: Int?
    let synthetic_files: Int?
}

// MARK: - Archive models
//
// Keys mirror the E10/E11 archive schema where they overlap (groups, file_rank,
// hit_at_*, reciprocal_rank, primary_audit), so the scorer adapts with minimal
// change. E12 drops VTT noise stats and adds `origin` (real/synthetic) plus
// OCR-specific per-file and throughput fields.

struct E12FrozenFile: Codable { let path: String; let bytes: Int; let sha256: String }

struct E12FrozenSettings: Codable {
    let profile_identity: String; let embedder: String; let dimension: Int
    let chunk_chars: Int; let chunk_overlap: Int; let concurrency: Int; let ocr_concurrency: Int
    let batch_size: Int; let bucket_width: Int; let compute_policy: String
    let search_limit: Int; let coalesce_limit: Int; let raw_fetch_limit: Int
    let ocr_recognizer_version: Int; let ocr_request_revision: Int; let ocr_max_pixel_dimension: Int
}

struct E12BuildIdentity: Codable {
    let configuration: String; let os_version: String; let active_processor_count: Int; let host_name: String
    let swift_version: String?; let git_head: String?; let git_dirty: Bool?; let package_resolved_sha256: String?
}

struct E12FrozenInputManifest: Codable {
    let experiment: String; let run_identity: String; let frozen_at: String
    let corpus_source: String; let corpus_scope: String
    let files: [E12FrozenFile]; let file_count: Int
    let query_manifest_path: String; let query_manifest_sha256: String; let query_count: Int
    let sample_manifest_path: String; let sample_manifest_sha256: String
    let model_directory: String; let model_revision: String?; let model_files: [E12FrozenFile]
    let build: E12BuildIdentity; let settings: E12FrozenSettings
}

struct E12ArchivedMatch: Codable {
    let score: Double; let distance: Double; let chunk_type: String
    let line_start: Int?; let line_end: Int?; let chunk_ordinal: Int?
}
struct E12ArchivedGroup: Codable {
    let rank: Int; let file: String; let best_score: Double; let match_count: Int; let matches: [E12ArchivedMatch]
}

struct E12CriterionResult: Codable {
    let type: String; let value: String
    /// Matched in the PRE-TOKENIZER OCR input reconstructed by ordinal via
    /// `E5BaseEmbedder.normalizeInputs`. Advisory; necessary-but-not-sufficient.
    let matched_in_ocr_text: Bool
}
struct E12PrimaryAudit: Codable {
    let file_rank: Int; let best_score: Double; let distance: Double; let chunk_type: String
    let chunk_ordinal: Int?; let input_chars: Int
    let criteria: [E12CriterionResult]; let all_criteria_met: Bool
}

struct E12QueryResult: Codable {
    let arm: String; let id: String; let text: String; let categories: [String]
    let origin: String
    let is_no_answer: Bool; let primary_file: String?; let relevant_files: [String]
    let file_rank: Int?; let hit_at_1: Bool; let hit_at_3: Bool; let hit_at_5: Bool
    let reciprocal_rank: Double; let overfetch_distinct_files: Int; let search_seconds: Double
    let groups: [E12ArchivedGroup]; let primary_audit: E12PrimaryAudit?
}

/// Codable mirror of the engine's `ImageOCRCacheStatistics` (which is not
/// Codable) so cache counters can be archived.
struct E12CacheStats: Codable { let hits: Int; let misses: Int; let ocr_calls: Int }

struct E12PerFileChunks: Codable { let path: String; let chunks: Int; let ocr_chars: Int; let is_blank: Bool }
struct E12ArmMetrics: Codable {
    let answered_queries: Int; let rank1_rate: Double; let top3_rate: Double; let top5_rate: Double
    let mean_reciprocal_rank: Double; let passage_all_met_rate: Double
    let real_answered: Int; let real_rank1_rate: Double; let real_mrr: Double
    let synthetic_answered: Int; let synthetic_rank1_rate: Double; let synthetic_mrr: Double
}
struct E12ArmSummary: Codable {
    let arm: String; let text_extraction: String; let file_count: Int; let indexed_count: Int
    let blank_count: Int
    let total_chunks: Int; let per_file_chunks: [E12PerFileChunks]
    let index_seconds: Double; let extract_seconds: Double; let embed_span_seconds: Double
    let db_seconds: Double; let search_seconds: Double
    let rss_before_index_bytes: UInt64; let rss_after_index_bytes: UInt64
    /// OCR-cache counters at the end of indexing (before the audit re-extract)
    /// and after the audit; nil when the arm ran no OCR cache.
    let ocr_cache_after_index: E12CacheStats?
    let ocr_cache_after_audit: E12CacheStats?
    let metrics: E12ArmMetrics
}

struct E12ComparisonCell: Codable {
    let file_rank: Int?; let reciprocal_rank: Double; let all_criteria_met: Bool?
    let top_file: String?; let top_score: Double?
}
struct E12ComparisonRow: Codable { let id: String; let origin: String; let is_no_answer: Bool; let arms: [String: E12ComparisonCell] }
struct E12Comparison: Codable { let arms: [String]; let per_query: [E12ComparisonRow]; let aggregate: [String: E12ArmMetrics] }

// Throughput / cold-warm archive.
struct E12ThroughputPass: Codable {
    let images_attempted: Int; let images_succeeded: Int; let images_failed: Int
    let jobs: Int; let wall_seconds: Double; let images_per_second: Double
    let cache_hits: Int; let cache_misses: Int; let ocr_calls: Int
    let rss_before_bytes: UInt64; let rss_peak_bytes: UInt64; let rss_after_bytes: UInt64
    let rss_sample_count: Int; let rss_mean_bytes: UInt64
    let estimate_target_seconds: Double; let estimate_target_count: Int
}
struct E12ThroughputJobResult: Codable { let jobs: Int; let cold: E12ThroughputPass; let warm: E12ThroughputPass }
struct E12ThroughputArchive: Codable {
    let experiment: String; let frozen_at: String; let corpus_source: String; let image_count: Int
    /// The frozen, sha256-pinned image snapshot both the cold and warm passes
    /// read (path/bytes/sha256), so the timed bytes are provable and identical.
    let frozen_images: [E12FrozenFile]
    let recognizer_version: Int; let request_revision: Int; let max_pixel_dimension: Int
    let os_version: String
    let jobs_sweep: [Int]; let target_estimate_count: Int
    let build: E12BuildIdentity; let results: [E12ThroughputJobResult]; let notes: [String]
}

/// Hard-failure error for setup problems that must abort the benchmark.
struct E12HarnessError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
