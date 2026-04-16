import Foundation
import ArgumentParser
import VecKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Thread-safe renderer for a single-line rolling progress display in verbose mode.
///
/// The `IndexingPipeline` calls `handle(_:)` from multiple concurrent workers
/// plus the DB-writer task. A lock (not an actor) serializes counter updates
/// and stdout writes so the synchronous `@Sendable` progress callback doesn't
/// need to await.
///
/// Counters it maintains:
/// - `filesDone` (from `.fileFinished`/`.fileSkipped`)
/// - `chunksDone` (from `.batchEmbedded(chunks:)`)
/// - `nonEnglishCount` (from `.nonEnglishDetected`)
/// - `busyWorkers` (from balanced `.workerBusy`/`.workerIdle` pairs on the
///   same task — decoupled from file-lifecycle events so the counter is
///   correct even on the DB-writer empty-records skip path)
/// - a 5-second sliding window of `(timestamp, chunks)` for a live ch/s
///   reading that responds to the current throughput rather than cumulative.
///
/// A first-batch latency line is printed once, the moment the first
/// `.batchEmbedded` event arrives, diagnosing the "workers all stuck in
/// extract" startup stall directly.
private final class ProgressRenderer: @unchecked Sendable {
    private let lock = NSLock()
    private let totalFiles: Int
    private let totalWorkers: Int
    private let startTime: Date

    private var filesDone = 0
    private var chunksDone = 0
    private var nonEnglishCount = 0
    private var busyWorkers = 0
    /// Ring of recent batch completions for sliding-window ch/s. Entries
    /// older than `windowSeconds` are trimmed on each render.
    private var recentBatches: [(time: Date, chunks: Int)] = []
    private let windowSeconds: TimeInterval = 5.0

    private var finished = false
    private var everRendered = false
    /// Last render's visible length. Each render pads to at least this
    /// length so busy-counter shrinking doesn't leave stale characters.
    private var lastRenderedLen = 0
    /// Whether the "first embed batch" startup line has been printed yet.
    private var firstBatchPrinted = false

    init(totalFiles: Int, totalWorkers: Int) {
        self.totalFiles = totalFiles
        self.totalWorkers = totalWorkers
        self.startTime = Date()
    }

    func handle(_ event: ProgressEvent) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }

        switch event {
        case .workerBusy:
            busyWorkers += 1
        case .workerIdle:
            // Defensive: clamp to zero so a dropped event never corrupts the
            // display. Balanced pairs from the same task make this
            // theoretically unnecessary, but a visible bad counter is worse
            // than a silent clamp.
            if busyWorkers > 0 { busyWorkers -= 1 }
        case .fileFinished:
            filesDone += 1
        case .fileSkipped:
            filesDone += 1
        case .nonEnglishDetected:
            nonEnglishCount += 1
        case .batchEmbedded(_, let chunks):
            chunksDone += chunks
            let now = Date()
            recentBatches.append((time: now, chunks: chunks))
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

        // Sliding-window ch/s. Use the actual span covered by retained
        // entries (not the full window) so a partial window during startup
        // reports the real rate, not an underestimate. Fall back to
        // elapsed-since-start if we have fewer than 2 entries.
        let chunksPerSec: Double
        if recentBatches.count >= 2,
           let first = recentBatches.first,
           let last = recentBatches.last {
            let span = last.time.timeIntervalSince(first.time)
            let chunks = recentBatches.reduce(0) { $0 + $1.chunks }
            chunksPerSec = span > 0.01 ? Double(chunks) / span : 0
        } else if let only = recentBatches.first {
            let span = Date().timeIntervalSince(only.time)
            chunksPerSec = span > 0.01 ? Double(only.chunks) / span : 0
        } else {
            chunksPerSec = 0
        }

        // Compact format to stay under 80 cols even at 5-digit files /
        // 6-digit chunks: drop the word "busy" and use "c/s" instead of
        // "ch/s". Pipe separators keep fields visually distinct without
        // adding the width of "• ".
        let elapsed = Date().timeIntervalSince(startTime)
        let line = "Indexing: \(filesDone)/\(totalFiles) | \(chunksDone) ch | \(nonEnglishCount) non-en | \(busyWorkers)/\(totalWorkers) | \(Self.formatSeconds(elapsed)) | \(String(format: "%.0f", chunksPerSec)) c/s"

        // Pad to previous length: busy counter can shrink, so the monotonic
        // length invariant from the original design no longer holds.
        var padded = line
        if line.count < lastRenderedLen {
            padded += String(repeating: " ", count: lastRenderedLen - line.count)
        }
        lastRenderedLen = line.count
        everRendered = true
        FileHandle.standardOutput.write(Data(("\r" + padded).utf8))
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

    static var configuration = CommandConfiguration(
        commandName: "update-index",
        abstract: "Update the vector index with new or modified files"
    )

    @Option(name: .shortAndLong, help: "Name of the database (stored in ~/.vec/<name>/). Omit to resolve from current directory.")
    var db: String?

    @Flag(name: .long, help: "Include hidden files and folders")
    var allowHidden: Bool = false

    @Flag(name: .shortAndLong, help: "Show a rolling stats line while indexing")
    var verbose: Bool = false

    func run() async throws {
        let (dbDir, _, sourceDir) = try db != nil
            ? DatabaseLocator.resolve(db!)
            : DatabaseLocator.resolveFromCurrentDirectory()

        let database = VectorDatabase(databaseDirectory: dbDir, sourceDirectory: sourceDir)
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
        // if the default ever changes.
        let pipeline = IndexingPipeline()
        let workerCount = pipeline.workerCount

        // Wire up the rolling progress renderer when verbose and attached to a TTY.
        // Piped/redirected stdout skips progress — the final summary still prints.
        let stdoutIsTTY = isatty(FileHandle.standardOutput.fileDescriptor) != 0
        let renderer: ProgressRenderer?
        let progress: ProgressHandler?
        if verbose && stdoutIsTTY && !workItems.isEmpty {
            let r = ProgressRenderer(totalFiles: workItems.count, totalWorkers: workerCount)
            renderer = r
            progress = { event in r.handle(event) }
        } else {
            renderer = nil
            progress = nil
        }

        let results: [IndexResult]
        let stats: IndexingStats
        let pipelineStart = Date()
        do {
            (results, stats) = try await pipeline.run(
                workItems: workItems,
                extractor: TextExtractor(),
                database: database,
                progress: progress
            )
            renderer?.finish()
        } catch {
            renderer?.finish()
            throw error
        }
        let wallSeconds = Date().timeIntervalSince(pipelineStart)

        // Tally results
        var added = 0
        var updated = 0
        var skippedUnreadable = 0
        var skippedEmbedFailures = 0

        for result in results {
            switch result {
            case .indexed(_, let wasUpdate, _):
                if wasUpdate {
                    updated += 1
                } else {
                    added += 1
                }
            case .skippedUnreadable:
                skippedUnreadable += 1
            case .skippedEmbedFailure:
                skippedEmbedFailures += 1
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

        let skipped = skippedUnreadable + skippedEmbedFailures
        var summary = "Update complete: \(added) added, \(updated) updated, \(removed) removed"
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

        if verbose && !workItems.isEmpty {
            printTimingFooter(stats: stats, wallSeconds: wallSeconds, workerCount: workerCount, filesIndexed: added + updated)
        }
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

        // Pool utilization: total embed seconds across batches / wall-seconds
        // * N workers. 100% means every worker was busy embedding every
        // second; <100% means workers were extract-bound, db-bound, or
        // idle between files.
        let maxPossibleEmbedSeconds = wallSeconds * Double(workerCount)
        let poolUtilization = maxPossibleEmbedSeconds > 0
            ? stats.totalBatchEmbedSeconds / maxPossibleEmbedSeconds * 100
            : 0

        print("")
        print("Timing (wall: \(formatSeconds(wallSeconds)), \(workerCount) workers)")
        print("  extract: \(formatSeconds(stats.extractSeconds)) (\(String(format: "%.0f", extractPct))%)  embed: \(formatSeconds(stats.embedSeconds)) (\(String(format: "%.0f", embedPct))%)  db: \(formatSeconds(stats.dbSeconds)) (\(String(format: "%.0f", dbPct))%)")
        print("  throughput: \(String(format: "%.1f", chunksPerSec)) ch/s (\(stats.totalChunksEmbedded) chunks)  \(String(format: "%.1f", filesPerSec)) files/s  pool util: \(String(format: "%.0f", poolUtilization))%")
        let meanBatchSize = stats.totalBatches > 0
            ? Double(stats.totalBatchChunks) / Double(stats.totalBatches)
            : 0
        print("  per-file embed: p50 \(formatSeconds(stats.p50EmbedSeconds)) • p95 \(formatSeconds(stats.p95EmbedSeconds))  batches: \(stats.totalBatches) (mean \(String(format: "%.1f", meanBatchSize)) ch)")
        if let first = stats.firstBatchLatencySeconds {
            print("  first embed batch: \(formatSeconds(first)) after start")
        }
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
            "batches=\(stats.totalBatches)",
            "mean_batch=\(String(format: "%.1f", meanBatchSize))",
            "wall=\(String(format: "%.2f", wallSeconds))s",
            "extract=\(String(format: "%.2f", stats.extractSeconds))s",
            "embed=\(String(format: "%.2f", stats.embedSeconds))s",
            "db=\(String(format: "%.2f", stats.dbSeconds))s",
            "chps=\(String(format: "%.1f", chunksPerSec))",
            "fps=\(String(format: "%.2f", filesPerSec))",
            "util=\(String(format: "%.0f", poolUtilization))%",
            "p50_embed=\(String(format: "%.3f", stats.p50EmbedSeconds))s",
            "p95_embed=\(String(format: "%.3f", stats.p95EmbedSeconds))s",
            "first_batch=\(stats.firstBatchLatencySeconds.map { String(format: "%.2f", $0) + "s" } ?? "n/a")"
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
