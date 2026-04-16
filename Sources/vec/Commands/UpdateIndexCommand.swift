import Foundation
import ArgumentParser
import VecKit

struct UpdateIndexCommand: AsyncParsableCommand {

    static var configuration = CommandConfiguration(
        commandName: "update-index",
        abstract: "Update the vector index with new or modified files"
    )

    @Option(name: .shortAndLong, help: "Name of the database (stored in ~/.vec/<name>/). Omit to resolve from current directory.")
    var db: String?

    @Flag(name: .long, help: "Include hidden files and folders")
    var allowHidden: Bool = false

    @Flag(name: .shortAndLong, help: "Show detailed progress for each file")
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
                    if verbose {
                        print("  Unchanged: \(file.relativePath)")
                    }
                }
            } else {
                workItems.append((file: file, label: "Added"))
            }
        }

        // Run the indexing pipeline
        let pipeline = IndexingPipeline()

        let progress: (@Sendable (String) -> Void)?
        if verbose {
            progress = { message in print(message) }
        } else {
            progress = nil
        }

        let results: [IndexResult] = try await pipeline.run(
            workItems: workItems,
            extractor: TextExtractor(),
            database: database,
            progress: progress
        )

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
                if verbose {
                    print("  Removed: \(indexedPath)")
                }
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
