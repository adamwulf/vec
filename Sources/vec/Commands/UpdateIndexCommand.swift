import Foundation
import ArgumentParser
import CoreML
import VecKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// CLI-facing compute-policy enum. `auto` preserves the current
/// per-embedder default (no explicit `withMLTensorComputePolicy` call
/// except where the embedder has its own hardcoded override, e.g.
/// `NomicEmbedder`'s batched-path `.cpuOnly` pin for the macOS 26.3+
/// ANE-fp16 incompatibility). `cpu` / `ane` / `gpu` map to the
/// corresponding `MLComputePolicy` values for the E6 speed/ANE-feasibility
/// probe chain.
enum ComputePolicyOption: String, ExpressibleByArgument, CaseIterable {
    case auto, cpu, ane, gpu

    /// `nil` means "preserve current per-embedder default behavior".
    /// Non-nil values thread into `IndexingProfileFactory.make` via
    /// the `computePolicy` argument and reach every Bert-family
    /// embedder's `withMLTensorComputePolicy(...)` scope.
    ///
    /// `MLComputePolicy` only exposes `.cpuOnly` and `.cpuAndGPU`
    /// as static-var factories on macOS 15 / iOS 18; the `ane` and
    /// (full-three-device) mapping has to go through the
    /// `MLComputePolicy(_ computeUnits: MLComputeUnits)` initializer.
    /// `.ane` → `.cpuAndNeuralEngine` (CPU + ANE, matches how
    /// NomicBert spells "ANE probing"); `.gpu` stays on the direct
    /// `.cpuAndGPU` spelling for readability.
    var mlPolicy: MLComputePolicy? {
        switch self {
        case .auto: return nil
        case .cpu:  return .cpuOnly
        case .ane:  return MLComputePolicy(.cpuAndNeuralEngine)
        case .gpu:  return .cpuAndGPU
        }
    }
}

/// Thread-safe writer for the per-DB PID/progress file at `<dbDir>/index.pid`.
///
/// Two-line format:
///   line 1: PID of the running `vec update-index` process
///   line 2: `<filesDone>/<totalFiles>` — updated after every file finishes
///
/// External tools tail this file to track indexing progress without
/// attaching to the CLI's stdout. The file is removed on completion
/// (success or failure). On startup, a stale file left behind by a
/// crashed run is detected via `kill(pid, 0)` and overwritten; a live
/// PID causes `update-index` to refuse to start.
private final class PIDProgressFile: @unchecked Sendable {
    private let url: URL
    private let pid: Int32
    private let totalFiles: Int
    private let lock = NSLock()
    private var filesDone = 0
    private var removed = false

    init(url: URL, totalFiles: Int) {
        self.url = url
        self.pid = getpid()
        self.totalFiles = totalFiles
    }

    /// Writes the initial `pid` + `0/<total>` content. Throws if the
    /// file can't be written (permissions, missing directory).
    func writeInitial() throws {
        try writeContents(filesDone: 0)
    }

    /// Bumps the `filesDone` counter and rewrites line 2. Safe to call
    /// from multiple concurrent stages — the underlying file write is
    /// guarded by `lock` and uses atomic-replace semantics so a
    /// concurrent reader never sees a partial line.
    func recordFileFinished() {
        lock.lock()
        let snapshotDone: Int
        let alreadyRemoved: Bool
        filesDone += 1
        snapshotDone = filesDone
        alreadyRemoved = removed
        lock.unlock()
        guard !alreadyRemoved else { return }
        // Best-effort: a transient write error shouldn't kill the whole
        // index. The next file's update will retry.
        try? writeContents(filesDone: snapshotDone)
    }

    /// Idempotent: safe to call from both the success and error paths.
    func remove() {
        lock.lock()
        defer { lock.unlock() }
        guard !removed else { return }
        removed = true
        try? FileManager.default.removeItem(at: url)
    }

    private func writeContents(filesDone: Int) throws {
        let body = "\(pid)\n\(filesDone)/\(totalFiles)\n"
        try body.data(using: .utf8)!.write(to: url, options: .atomic)
    }

    /// Returns true if a process with the given PID is currently alive.
    /// `kill(pid, 0)` performs the permission/existence check without
    /// actually sending a signal: returns 0 if the process exists,
    /// `errno == ESRCH` if it doesn't, `errno == EPERM` if it exists
    /// but we lack permission to signal it (still alive — treat as
    /// running).
    static func isProcessAlive(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    /// Inspects an existing PID file at `url`. Returns the live PID if
    /// the file exists, parses cleanly, and the recorded process is
    /// still running. Returns `nil` for "no file", "malformed file",
    /// or "stale PID" — all three mean it's safe to overwrite.
    static func livePID(at url: URL) -> Int32? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        guard let pid = Int32(firstLine.trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        return isProcessAlive(pid: pid) ? pid : nil
    }
}

/// Thread-safe renderer for a single-line rolling progress display in verbose mode.
///
/// The `IndexingPipeline` calls `handle(_:)` from multiple concurrent stages
/// (extract, per-chunk embed tasks, the per-file accumulator, and the DB
/// writer). A lock (not an actor) serializes counter updates and stdout
/// writes so the synchronous `@Sendable` progress callback doesn't need
/// to await.
///
/// Post-H7 the renderer surfaces two queue depths and a pool-occupancy
/// gauge instead of one "workers busy" gauge:
/// - **extract q**: files extracted but not yet handed to the embed
///   stream. Always 0 or 1 in practice — extract is single-threaded.
/// - **pool**: embedders currently held by running embed calls. Pinned at
///   `totalWorkers` under saturation means embed is the bottleneck.
/// - **save q**: files embedded but not yet written. Growth here means
///   DB is the bottleneck (rare).
private final class ProgressRenderer: @unchecked Sendable {
    private let lock = NSLock()
    private let totalFiles: Int
    private let totalWorkers: Int
    private let startTime: Date

    private var filesDone = 0
    private var chunksDone = 0
    private var nonEnglishCount = 0
    /// Files currently in extract (pulled off the input queue, not yet
    /// handed off). Single-threaded extract → expected to be 0 or 1.
    private var extractQueueDepth = 0
    /// Embedders currently held by a running embed call. Pinned at
    /// `totalWorkers` under steady-state saturation; any dip is a real
    /// idle pool slot. This is the true "embed utilization" gauge.
    private var poolBusy = 0
    /// Files currently buffered in the save stream, waiting for the DB
    /// writer. enqueued - dequeued; growing queue means DB is the
    /// bottleneck, persistent zero means embed/extract is.
    private var saveQueueDepth = 0
    private var recentBatches: [(time: Date, chunks: Int)] = []
    private let windowSeconds: TimeInterval = 30.0

    private var finished = false
    private var everRendered = false
    /// Last render's visible length. Each render pads to at least this
    /// length so busy-counter shrinking doesn't leave stale characters.
    private var lastRenderedLen = 0
    private var firstBatchPrinted = false
    /// Periodically commit the current rolling line to scrollback so the
    /// verbose output reads as a sparse time-series instead of a single
    /// ever-overwritten line.
    private var lastTrailSnapshot: Date
    private let trailInterval: TimeInterval = 10.0

    init(totalFiles: Int, totalWorkers: Int) {
        self.totalFiles = totalFiles
        self.totalWorkers = totalWorkers
        self.startTime = Date()
        self.lastTrailSnapshot = Date()
    }

    func handle(_ event: ProgressEvent) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }

        switch event {
        case .extractEnqueued:
            extractQueueDepth += 1
        case .extractDequeued:
            // Defensive clamp — same rationale as save/pool below.
            if extractQueueDepth > 0 { extractQueueDepth -= 1 }
        case .fileFinished:
            filesDone += 1
        case .fileSkipped:
            filesDone += 1
        case .nonEnglishDetected:
            nonEnglishCount += 1
            // In verbose mode, the rolling line's non-en counter is the
            // primary signal; the per-file stderr line would just clutter
            // the TTY, so we swallow it here.
        case .saveEnqueued:
            saveQueueDepth += 1
        case .saveDequeued:
            if saveQueueDepth > 0 { saveQueueDepth -= 1 }
        case .poolAcquired:
            poolBusy += 1
        case .poolReleased:
            if poolBusy > 0 { poolBusy -= 1 }
        case .poolWarmed:
            break
        case .chunkEmbedded:
            chunksDone += 1
            let now = Date()
            recentBatches.append((time: now, chunks: 1))
            // Fire the one-time startup diagnostic as soon as the first
            // batch lands. Terminate the rolling line's partial (if any)
            // with a clean newline so the startup line prints on its own
            // row, then the next render() redraws the rolling line fresh.
            if !firstBatchPrinted {
                firstBatchPrinted = true
                let elapsed = now.timeIntervalSince(startTime)
                let prefix = everRendered ? "\n" : ""
                let line = prefix + "First embed batch completed \(Self.formatSeconds(elapsed)) after start\n"
                FileHandle.standardOutput.write(Data(line.utf8))
                // Force a full-width re-render so the rolling line
                // re-establishes itself on the next row.
                lastRenderedLen = 0
                everRendered = false
            }
        }

        render()
    }

    /// Idempotent: safe to call from both the normal flow and a `defer` on error.
    /// Writes a trailing newline so the next stdout line starts fresh.
    func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        if everRendered {
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }

    /// Must be called with the lock held.
    private func render() {
        let cutoff = Date().addingTimeInterval(-windowSeconds)
        while let first = recentBatches.first, first.time < cutoff {
            recentBatches.removeFirst()
        }

        // Sliding-window ch/s over the last `windowSeconds`. Use the actual
        // span covered by retained entries (not the full window) so a
        // partial window during startup reports the real rate, not an
        // underestimate. Fall back to elapsed-since-start if we have fewer
        // than 2 entries.
        let windowChunksPerSec: Double
        if recentBatches.count >= 2,
           let first = recentBatches.first,
           let last = recentBatches.last {
            let span = last.time.timeIntervalSince(first.time)
            let chunks = recentBatches.reduce(0) { $0 + $1.chunks }
            windowChunksPerSec = span > 0.01 ? Double(chunks) / span : 0
        } else if let only = recentBatches.first {
            let span = Date().timeIntervalSince(only.time)
            windowChunksPerSec = span > 0.01 ? Double(only.chunks) / span : 0
        } else {
            windowChunksPerSec = 0
        }

        // Terminal is wide enough (~180 cols) to expose queue health and
        // both throughput rates without truncation. `extract q` (files in
        // extract — single-threaded so 0 or 1 is expected), `pool` (pool
        // occupancy — pinned at totalWorkers under saturation means embed
        // is the bottleneck), `save q` (files embedded but waiting for the
        // DB writer). `bn` (bottleneck) is a derived hint so the user
        // doesn't have to read the counters to guess which stage is
        // limiting throughput.
        let now = Date()
        let elapsed = now.timeIntervalSince(startTime)
        let lifetimeChunksPerSec = elapsed > 0.01 ? Double(chunksDone) / elapsed : 0
        // Bottleneck signal driven by pool occupancy: `poolBusy ==
        // totalWorkers` means every embedder is held, so embed is
        // rate-limiting. Save outranks embed (files piling up post-embed
        // implies DB is slower).
        let bottleneck: String
        if saveQueueDepth > totalWorkers {
            bottleneck = "db"
        } else if poolBusy >= totalWorkers {
            bottleneck = "embed"
        } else if extractQueueDepth > 0 && poolBusy == 0 {
            bottleneck = "extract"
        } else {
            bottleneck = "ok"
        }
        let line = "Indexing: \(filesDone)/\(totalFiles) | \(chunksDone) ch | \(nonEnglishCount) non-en | extract q \(extractQueueDepth) | pool \(poolBusy)/\(totalWorkers) | save q \(saveQueueDepth) | bn \(bottleneck) | \(Self.formatSeconds(elapsed)) | \(String(format: "%.0f", lifetimeChunksPerSec)) c/s avg, \(String(format: "%.0f", windowChunksPerSec)) 30s"

        // Every `trailInterval`, commit the current rolling line to
        // scrollback with a newline so the verbose session leaves a
        // sparse history of snapshots instead of a single overwritten
        // row. Reset pad tracking so the fresh line draws full-width.
        var leading = "\r"
        if everRendered && now.timeIntervalSince(lastTrailSnapshot) >= trailInterval {
            leading = "\n"
            lastRenderedLen = 0
            lastTrailSnapshot = now
        }

        // Pad to previous length: busy counter can shrink, so the monotonic
        // length invariant from the original design no longer holds.
        var padded = line
        if line.count < lastRenderedLen {
            padded += String(repeating: " ", count: lastRenderedLen - line.count)
        }
        lastRenderedLen = line.count
        everRendered = true
        FileHandle.standardOutput.write(Data((leading + padded).utf8))
    }

    fileprivate static func formatSeconds(_ seconds: Double) -> String {
        if seconds >= 1 {
            return String(format: "%.1fs", seconds)
        } else {
            return String(format: "%.0fms", seconds * 1000)
        }
    }
}

struct UpdateIndexCommand: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "update-index",
        abstract: "Update the vector index with new or modified files"
    )

    /// Default alias's built-in descriptor. `defaultAlias` is guaranteed
    /// to be in `builtIns` by construction of `IndexingProfileFactory`,
    /// so the force-unwrap is safe.
    private static let defaultBuiltIn: IndexingProfileFactory.BuiltIn = {
        IndexingProfileFactory.builtIns.first {
            $0.alias == IndexingProfileFactory.defaultAlias
        }!
    }()

    @Option(name: .shortAndLong, help: "Name of the database (stored in ~/.vec/<name>/). Omit to resolve from current directory.")
    var db: String?

    @Flag(name: .long, help: "Include hidden files and folders")
    var allowHidden: Bool = false

    @Flag(name: .shortAndLong, help: "Show a rolling stats line while indexing")
    var verbose: Bool = false

    @Option(name: .long, help: "Max chunk size in characters. Pass together with --chunk-overlap (or neither). Default is the selected profile's alias-default (e.g. \(Self.defaultBuiltIn.defaultChunkSize) for \(IndexingProfileFactory.defaultAlias)).")
    var chunkChars: Int?

    @Option(name: .long, help: "Chunk overlap in characters. Must be less than --chunk-chars. Pass together with --chunk-chars (or neither). Default is the selected profile's alias-default (e.g. \(Self.defaultBuiltIn.defaultChunkOverlap) for \(IndexingProfileFactory.defaultAlias)).")
    var chunkOverlap: Int?

    @Option(name: .long, help: "Indexing profile alias (\(IndexingProfileFactory.knownAliases.joined(separator: ", "))). Default is \(IndexingProfileFactory.defaultAlias) on first index; must match the recorded profile on subsequent runs (or omit to reuse the recorded alias with its alias-default chunk params).")
    var embedder: String?

    @Option(name: .long, help: "Override embedder pool size (default: \(IndexingPipeline.defaultConcurrency), measured optimum on 10-perf-core M-series in E6.3). E6.3 indexing-speed knob.")
    var concurrency: Int?

    @Option(name: .long, help: "Override max chunks per embedDocuments batch (default: \(IndexingPipeline.defaultBatchSize), cap 32). E6.3 indexing-speed knob.")
    var batchSize: Int?

    @Option(name: .long, help: "Override length-bucket width (chars) for batch-former keying: chunk.text.count / bucket-width (default: \(IndexingPipeline.defaultBucketWidth)). E6.4 indexing-speed knob.")
    var bucketWidth: Int?

    @Option(name: .long, help: "MLTensor compute-policy placement (auto/cpu/ane/gpu; default: auto = per-embedder default). E6.2 ANE-feasibility probe for e5-base.")
    var computePolicy: ComputePolicyOption = .auto

    func run() async throws {
        // Step 1: CLI partial-override hard-fail — before any DB work.
        if (chunkChars == nil) != (chunkOverlap == nil) {
            throw VecError.partialChunkOverride
        }

        // Step 2: resolve DB.
        let (dbDir, rawConfig, sourceDir) = try db != nil
            ? DatabaseLocator.resolve(db!)
            : DatabaseLocator.resolveFromCurrentDirectory()

        // Refuse to run if another vec process is already indexing this
        // DB. A stale file (process died without cleanup) is silently
        // overwritten when we claim the lock below.
        let pidFileURL = dbDir.appendingPathComponent("index.pid")
        if let livePID = PIDProgressFile.livePID(at: pidFileURL) {
            throw VecError.indexingAlreadyRunning(pid: livePID)
        }

        // Step 3: open DB only to count chunks. The three missing-profile
        // branches split on chunk count; the probe dimension doesn't
        // matter because we only read the chunk count, but we still
        // need a valid (non-zero) dim for open() to succeed when the DB
        // is already initialized.
        let probeDim = rawConfig.profile?.dimension
            ?? Self.defaultBuiltIn.canonicalDimension
        let probe = VectorDatabase(
            databaseDirectory: dbDir,
            sourceDirectory: sourceDir,
            dimension: probeDim
        )
        try await probe.open()
        let chunkCount = try await probe.totalChunkCount()

        // Steps 4–6: resolve requested profile against recorded state.
        // Pure logic lives in a testable helper.
        let resolution = try Self.resolveRequestedProfile(
            config: rawConfig,
            chunkCount: chunkCount,
            cliEmbedder: embedder,
            cliChunkChars: chunkChars,
            cliChunkOverlap: chunkOverlap,
            cliComputePolicy: computePolicy.mlPolicy
        )
        let activeProfile = resolution.profile

        // Step 6 persist: write ProfileRecord to config.json BEFORE the
        // pipeline touches the DB. Runs only on the first-index path —
        // the recorded path by definition already has a profile and the
        // identity just proved equal.
        if resolution.writeProfileRecord {
            let newRecord = DatabaseConfig.ProfileRecord(
                identity: activeProfile.identity,
                embedderName: activeProfile.embedder.name,
                dimension: activeProfile.embedder.dimension
            )
            let updated = DatabaseConfig(
                sourceDirectory: rawConfig.sourceDirectory,
                createdAt: rawConfig.createdAt,
                profile: newRecord
            )
            try DatabaseLocator.writeConfig(updated, to: dbDir)
        }

        // Step 7: build the real DB + pipeline from the resolved profile.
        let database = VectorDatabase(
            databaseDirectory: dbDir,
            sourceDirectory: sourceDir,
            dimension: activeProfile.embedder.dimension
        )
        try await database.open()

        let scanner = FileScanner(directory: sourceDir, includeHiddenFiles: allowHidden)
        let files = try scanner.scan()
        let indexedFiles = try await database.allIndexedFiles()

        // Categorize files into work items
        var workItems: [(file: FileInfo, label: String)] = []
        var unchanged = 0

        for file in files {
            if let existingModDate = indexedFiles[file.relativePath] {
                if file.modificationDate > existingModDate {
                    workItems.append((file: file, label: "Updated"))
                } else {
                    unchanged += 1
                }
            } else {
                workItems.append((file: file, label: "Added"))
            }
        }

        // Source worker count from the pipeline so the rolling line's
        // "N/M" denominator can't silently desync from the actual pool size
        // if the default ever changes. Nil CLI overrides fall through to
        // `IndexingPipeline`'s existing defaults, so the no-flags path is
        // behavior-identical to pre-E6.1 (the E6.1 regression bar).
        let pipeline = Self.makePipeline(
            profile: activeProfile,
            concurrency: concurrency,
            batchSize: batchSize,
            bucketWidth: bucketWidth
        )
        let workerCount = pipeline.workerCount

        // Per-DB PID + progress file. Only write it when we actually
        // have files to process — a no-op `update-index` exits in
        // milliseconds and doesn't need an external progress signal.
        let pidFile: PIDProgressFile?
        if !workItems.isEmpty {
            let f = PIDProgressFile(url: pidFileURL, totalFiles: workItems.count)
            try f.writeInitial()
            pidFile = f
        } else {
            pidFile = nil
        }

        // Wire up the rolling progress renderer when verbose and attached to a TTY.
        // Piped/redirected stdout skips the rolling line, but non-verbose runs
        // still need a progress handler so non-English warnings can print to
        // stderr — the final summary and warnings are all the non-verbose user
        // sees.
        let stdoutIsTTY = isatty(FileHandle.standardOutput.fileDescriptor) != 0
        let renderer: ProgressRenderer?
        let baseProgress: ProgressHandler
        if verbose && stdoutIsTTY && !workItems.isEmpty {
            let r = ProgressRenderer(totalFiles: workItems.count, totalWorkers: workerCount)
            renderer = r
            baseProgress = { event in r.handle(event) }
        } else {
            renderer = nil
            baseProgress = { event in
                if case .nonEnglishDetected(let path, let language) = event {
                    FileHandle.standardError.write(
                        Data("Warning: non-English content detected in \(path) (detected: \(language)), embedding quality may be reduced\n".utf8)
                    )
                }
            }
        }
        let progress: ProgressHandler? = { [pidFile] event in
            baseProgress(event)
            switch event {
            case .fileFinished, .fileSkipped:
                pidFile?.recordFileFinished()
            default:
                break
            }
        }

        let results: [IndexResult]
        let stats: IndexingStats
        let pipelineStart = Date()
        do {
            (results, stats) = try await pipeline.run(
                workItems: workItems,
                extractor: TextExtractor(splitter: activeProfile.splitter),
                database: database,
                progress: progress
            )
            renderer?.finish()
            pidFile?.remove()
        } catch {
            renderer?.finish()
            pidFile?.remove()
            throw error
        }
        let wallSeconds = Date().timeIntervalSince(pipelineStart)

        // Tally results
        var added = 0
        var updated = 0
        var skippedUnreadable = 0
        var skippedEmbedFailures = 0
        var skippedUnreadablePaths: [String] = []
        var skippedEmbedFailurePaths: [String] = []
        var partialEmbedFailures: [PartialFailure] = []

        for result in results {
            switch result {
            case .indexed(let filePath, let wasUpdate, let chunkCount, let failedChunkCount):
                if wasUpdate {
                    updated += 1
                } else {
                    added += 1
                }
                if failedChunkCount > 0 {
                    partialEmbedFailures.append(PartialFailure(
                        path: filePath,
                        failedChunks: failedChunkCount,
                        totalChunks: chunkCount + failedChunkCount
                    ))
                }
            case .skippedUnreadable(let filePath):
                skippedUnreadable += 1
                skippedUnreadablePaths.append(filePath)
                if verbose {
                    print("Skipped (no chunks extracted): \(filePath)")
                }
            case .skippedEmbedFailure(let filePath):
                skippedEmbedFailures += 1
                skippedEmbedFailurePaths.append(filePath)
                if verbose {
                    print("Skipped (all chunks failed to embed): \(filePath)")
                }
            }
        }

        // Find files to remove
        var removed = 0
        let currentPaths = Set(files.map(\.relativePath))
        for indexedPath in indexedFiles.keys {
            if !currentPaths.contains(indexedPath) {
                try await database.removeEntries(forPath: indexedPath)
                removed += 1
            }
        }

        // Silent-failure detection — computed before the summary so the
        // human-readable headline matches the exit status. Fires when the
        // pipeline attempted ≥1 file and every attempt fell into
        // `.skippedEmbedFailure` (chunks extracted, zero survived
        // embedding). `.skippedUnreadable` alone is a legitimate outcome
        // (non-text files in the corpus) so it does not trip the guard.
        // The guard lives at the CLI layer rather than inside
        // `IndexingPipeline` because it needs `workItems.count` (a CLI
        // concept — filtered input after modification-date triage) and
        // the per-outcome tally (pipeline returns `[IndexResult]`, not
        // pre-bucketed counts).
        let silentFailure = !workItems.isEmpty
            && added == 0 && updated == 0
            && skippedEmbedFailures > 0

        let skipped = skippedUnreadable + skippedEmbedFailures
        let headline = silentFailure
            ? "Indexing finished with no vectors written"
            : "Update complete"
        var summary = "\(headline): \(added) added, \(updated) updated, \(removed) removed"
        if verbose {
            summary += ", \(unchanged) unchanged"
        }
        if skipped > 0 {
            var details: [String] = []
            if skippedUnreadable > 0 {
                details.append("\(skippedUnreadable) unreadable")
            }
            if skippedEmbedFailures > 0 {
                details.append("\(skippedEmbedFailures) failed to embed")
            }
            summary += " (\(skipped) skipped: \(details.joined(separator: ", ")))"
        }
        if verbose {
            summary += " (\(files.count) files scanned)"
        }
        print(summary + ".")

        // Timing footer is meaningful only when some files actually made it
        // through embed → DB. Under the silent-failure path, `filesIndexed`
        // is zero and the footer would print all-zero throughput rows that
        // add noise to the thrown error. Skip it.
        if verbose && !workItems.isEmpty && !silentFailure {
            printTimingFooter(stats: stats, wallSeconds: wallSeconds, workerCount: workerCount, filesIndexed: added + updated)
        }

        // Persist a per-run audit record before any throw. The
        // silent-failure path (every attempt → `.skippedEmbedFailure`)
        // is exactly the case operators most need to audit, so the log
        // write happens *before* the throw below. A failing log write
        // is best-effort — indexing succeeded (or failed in a way the
        // exit code already surfaces); we don't roll that back over a
        // log issue.
        let alias = (try? IndexingProfile.parseIdentity(activeProfile.identity).alias)
            ?? activeProfile.identity
        let logEntry = IndexLogEntry(
            timestamp: Date(),
            embedder: alias,
            profile: activeProfile.identity,
            wallSeconds: wallSeconds,
            filesScanned: files.count,
            added: added,
            updated: updated,
            removed: removed,
            unchanged: unchanged,
            skippedUnreadable: skippedUnreadablePaths,
            skippedEmbedFailures: skippedEmbedFailurePaths,
            partialEmbedFailures: partialEmbedFailures
        )
        do {
            try IndexLog.append(logEntry, to: dbDir)
        } catch {
            FileHandle.standardError.write(
                Data("Warning: failed to write index.log: \(error.localizedDescription)\n".utf8)
            )
        }

        if silentFailure {
            throw VecError.indexingProducedNoVectors(
                filesAttempted: workItems.count,
                filesFailed: skippedEmbedFailures
            )
        }
    }

    /// Constructs an `IndexingPipeline` honoring the E6.1 CLI knobs.
    /// Nil overrides fall back to the pipeline's own measured-and-
    /// hardcoded defaults (`defaultConcurrency`, `defaultBatchSize`,
    /// `defaultBucketWidth`). Shared between `UpdateIndexCommand` and
    /// `SweepCommand` so both see identical knob-routing semantics.
    static func makePipeline(
        profile: IndexingProfile,
        concurrency: Int?,
        batchSize: Int?,
        bucketWidth: Int?
    ) -> IndexingPipeline {
        return IndexingPipeline(
            concurrency: concurrency ?? IndexingPipeline.defaultConcurrency,
            batchSize: batchSize ?? IndexingPipeline.defaultBatchSize,
            bucketWidth: bucketWidth ?? IndexingPipeline.defaultBucketWidth,
            profile: profile
        )
    }

    /// Outcome of profile resolution on a given DB state. Lives as a
    /// small enum+struct so tests can assert both the chosen identity
    /// and whether the command is expected to write a new
    /// `ProfileRecord` to config.json.
    struct ProfileResolution {
        let profile: IndexingProfile
        /// True on the first-index path (no `profile` recorded yet) —
        /// the command must persist the resolved `ProfileRecord` before
        /// running the pipeline. False on the recorded path — the
        /// already-persisted record matches the resolved identity, so no
        /// write is needed.
        let writeProfileRecord: Bool
    }

    /// Pure check-order logic for steps 1–5 of the spec, minus the
    /// partial-override guard (which the caller runs before any DB
    /// work) and the config write (which the caller performs based on
    /// `writeProfileRecord`). Factored out so `ProfileMismatchTests`
    /// can exercise each branch without spinning up a real DB on disk.
    static func resolveRequestedProfile(
        config: DatabaseConfig,
        chunkCount: Int,
        cliEmbedder: String?,
        cliChunkChars: Int?,
        cliChunkOverlap: Int?,
        cliComputePolicy: MLComputePolicy? = nil
    ) throws -> ProfileResolution {
        // The caller must have already rejected partial overrides. Trap
        // any slip through so tests catch a regression in the check
        // order rather than silently succeeding.
        precondition(
            (cliChunkChars == nil) == (cliChunkOverlap == nil),
            "resolveRequestedProfile requires both chunk overrides or neither"
        )

        if let recorded = config.profile {
            // Step 4: recorded-profile path. Alias falls back to the
            // recorded alias when --embedder is omitted; chunk params
            // default to the *alias-default* chunk params (NOT the
            // recorded chunk params — strict no-inheritance).
            let recordedParsed = try IndexingProfile.parseIdentity(recorded.identity)
            let requestedAlias = cliEmbedder ?? recordedParsed.alias
            let requestedIdentity: String
            if let size = cliChunkChars, let overlap = cliChunkOverlap {
                requestedIdentity = "\(requestedAlias)@\(size)/\(overlap)"
            } else {
                // No chunk overrides → alias-default chunk params.
                // Resolve the alias through the factory so an unknown
                // alias surfaces as `unknownProfile` rather than a
                // mysterious mismatch.
                let builtIn = try IndexingProfileFactory.builtIn(forAlias: requestedAlias)
                requestedIdentity = "\(requestedAlias)@\(builtIn.defaultChunkSize)/\(builtIn.defaultChunkOverlap)"
            }
            guard requestedIdentity == recorded.identity else {
                throw VecError.profileMismatch(
                    recorded: recorded.identity,
                    requested: requestedIdentity
                )
            }
            // Match. Resolve the persisted identity through the
            // factory — `resolve` re-parses the identity (no shortcut
            // via `make`) so a corrupt `config.json` with a malformed
            // identity fails as `malformedProfileIdentity`. Compute
            // policy is runtime-only (not persisted), so it's threaded
            // in here rather than read from config.
            let profile = try IndexingProfileFactory.resolve(
                identity: recorded.identity,
                computePolicy: cliComputePolicy
            )
            return ProfileResolution(profile: profile, writeProfileRecord: false)
        }

        // Steps 3–5: no recorded profile. Split on chunk count.
        if chunkCount > 0 {
            throw VecError.preProfileDatabase
        }

        // Step 5: fresh/reset DB — first-index path. Build the profile
        // from CLI flags, defaulting alias to `defaultAlias`.
        let alias = cliEmbedder ?? IndexingProfileFactory.defaultAlias
        let profile = try IndexingProfileFactory.make(
            alias: alias,
            chunkSize: cliChunkChars,
            chunkOverlap: cliChunkOverlap,
            computePolicy: cliComputePolicy
        )
        return ProfileResolution(profile: profile, writeProfileRecord: true)
    }

    /// Per-stage totals are summed across N concurrent workers, so they can
    /// sum to more than wall time. The footer reports both the raw totals
    /// and CPU-time percentages (which sum to 100% and tell the user which
    /// stage dominated the work). Wall time shows how long the user waited.
    private func printTimingFooter(stats: IndexingStats, wallSeconds: Double, workerCount: Int, filesIndexed: Int) {
        let chunksPerSec = stats.embedSeconds > 0
            ? Double(stats.totalChunksEmbedded) / stats.embedSeconds
            : 0
        let filesPerSec = wallSeconds > 0 ? Double(filesIndexed) / wallSeconds : 0

        // CPU-time percentages — share of summed worker+db stage seconds.
        let stageTotal = stats.extractSeconds + stats.embedSeconds + stats.dbSeconds
        let extractPct = stageTotal > 0 ? stats.extractSeconds / stageTotal * 100 : 0
        let embedPct = stageTotal > 0 ? stats.embedSeconds / stageTotal * 100 : 0
        let dbPct = stageTotal > 0 ? stats.dbSeconds / stageTotal * 100 : 0

        // Pool utilization: summed per-chunk embed() wall-clock / (wall
        // seconds × N workers). 100% means every worker was in embed()
        // every second; <100% means workers were extract-bound, db-bound,
        // pool-waiting, or idle between files. Uses totalEmbedCallSeconds
        // (strictly bounded) rather than embedSeconds (overlapping per-file
        // spans — can exceed the denominator).
        let maxPossibleEmbedSeconds = wallSeconds * Double(workerCount)
        let poolUtilization = maxPossibleEmbedSeconds > 0
            ? stats.totalEmbedCallSeconds / maxPossibleEmbedSeconds * 100
            : 0

        print("")
        print("Timing (wall: \(formatSeconds(wallSeconds)), \(workerCount) workers)")
        print("  extract: \(formatSeconds(stats.extractSeconds)) (\(String(format: "%.0f", extractPct))%)  embed: \(formatSeconds(stats.embedSeconds)) (\(String(format: "%.0f", embedPct))%)  db: \(formatSeconds(stats.dbSeconds)) (\(String(format: "%.0f", dbPct))%)")
        print("  throughput: \(String(format: "%.1f", chunksPerSec)) ch/s (\(stats.totalChunksEmbedded) chunks)  \(String(format: "%.1f", filesPerSec)) files/s  pool util: \(String(format: "%.0f", poolUtilization))%")
        print("  per-file embed span: p50 \(formatSeconds(stats.p50EmbedSeconds)) • p95 \(formatSeconds(stats.p95EmbedSeconds))")
        if let biggest = stats.largestFile {
            print("  largest file: \(biggest.chunkCount) chunks, \(formatSeconds(biggest.totalSeconds))  \(biggest.path)")
        }

        if !stats.slowestFiles.isEmpty {
            print("Slowest files:")
            for timing in stats.slowestFiles {
                print("  \(formatSeconds(timing.totalSeconds))  [extract \(formatSeconds(timing.extractSeconds)), embed \(formatSeconds(timing.embedSeconds)), db \(formatSeconds(timing.dbSeconds)), \(timing.chunkCount) chunks]  \(timing.path)")
            }
        }

        // Copy/paste-friendly one-liner. Space-separated key=value so it
        // greps, diffs, and parses with awk/python trivially. Keep keys
        // stable across runs so trend plots work.
        let verboseStats = [
            "files=\(filesIndexed)",
            "workers=\(workerCount)",
            "chunks=\(stats.totalChunksEmbedded)",
            "wall=\(String(format: "%.2f", wallSeconds))s",
            "extract=\(String(format: "%.2f", stats.extractSeconds))s",
            "embed=\(String(format: "%.2f", stats.embedSeconds))s",
            "db=\(String(format: "%.2f", stats.dbSeconds))s",
            "chps=\(String(format: "%.1f", chunksPerSec))",
            "fps=\(String(format: "%.2f", filesPerSec))",
            "util=\(String(format: "%.0f", poolUtilization))%",
            "p50_embed=\(String(format: "%.3f", stats.p50EmbedSeconds))s",
            "p95_embed=\(String(format: "%.3f", stats.p95EmbedSeconds))s"
        ].joined(separator: " ")
        print("[verbose-stats] " + verboseStats)
    }

    private func formatSeconds(_ seconds: Double) -> String {
        if seconds >= 1 {
            return String(format: "%.2fs", seconds)
        } else {
            return String(format: "%.0fms", seconds * 1000)
        }
    }
}
