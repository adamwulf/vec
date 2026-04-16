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
/// The `IndexingPipeline` calls `handle(_:)` from multiple concurrent workers.
/// A lock (not an actor) serializes counter updates and stdout writes so the
/// synchronous `@Sendable` progress callback doesn't need to await.
private final class ProgressRenderer: @unchecked Sendable {
    private let lock = NSLock()
    private let totalFiles: Int
    private var filesDone = 0
    private var chunksDone = 0
    private var nonEnglishCount = 0
    private var lastRenderedLen = 0
    private var finished = false
    private var everRendered = false

    init(totalFiles: Int) {
        self.totalFiles = totalFiles
    }

    func handle(_ event: ProgressEvent) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }

        switch event {
        case .fileFinished:
            filesDone += 1
        case .fileSkipped:
            filesDone += 1
        case .nonEnglishDetected:
            nonEnglishCount += 1
        case .chunksEmbedded(let count):
            chunksDone += count
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
        let line = "Indexing: \(filesDone)/\(totalFiles) files • \(chunksDone) chunks • \(nonEnglishCount) non-English"
        var padded = "\r" + line
        if line.count < lastRenderedLen {
            padded += String(repeating: " ", count: lastRenderedLen - line.count)
        }
        lastRenderedLen = line.count
        everRendered = true
        FileHandle.standardOutput.write(Data(padded.utf8))
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

        // Wire up the rolling progress renderer when verbose and attached to a TTY.
        // Piped/redirected stdout skips progress — the final summary still prints.
        let stdoutIsTTY = isatty(FileHandle.standardOutput.fileDescriptor) != 0
        let renderer: ProgressRenderer?
        let progress: ProgressHandler?
        if verbose && stdoutIsTTY && !workItems.isEmpty {
            let r = ProgressRenderer(totalFiles: workItems.count)
            renderer = r
            progress = { event in r.handle(event) }
        } else {
            renderer = nil
            progress = nil
        }

        let pipeline = IndexingPipeline()

        let results: [IndexResult]
        do {
            results = try await pipeline.run(
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
    }
}
