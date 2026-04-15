import Foundation
import ArgumentParser
import VecKit

struct InitCommand: AsyncParsableCommand {

    static var configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Initialize a vector database for the current directory"
    )

    @Argument(help: "Name for the database (stored in ~/.vec/<db-name>/)")
    var dbName: String

    @Flag(name: .long, help: "Overwrite existing database if present")
    var force: Bool = false

    @Flag(name: .long, help: "Include hidden files and folders")
    var allowHidden: Bool = false

    func run() async throws {
        try DatabaseLocator.validateName(dbName)

        let dbDir = DatabaseLocator.databaseDirectory(for: dbName)
        let sourceDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)

        if FileManager.default.fileExists(atPath: dbDir.path) {
            if !force {
                print("Error: Database '\(dbName)' already exists at \(dbDir.path). Use --force to reinitialize.")
                throw ExitCode.failure
            }
            try FileManager.default.removeItem(at: dbDir)
        }

        print("Initializing vector database '\(dbName)' at \(dbDir.path)...")

        // Create directory and write config.json first, so a crash during indexing
        // still leaves a valid (empty) database that can be re-initialized.
        let database = VectorDatabase(databaseDirectory: dbDir, sourceDirectory: sourceDir)
        try database.initialize()
        let config = DatabaseConfig(sourceDirectory: sourceDir.path, createdAt: Date())
        try DatabaseLocator.writeConfig(config, to: dbDir)

        let scanner = FileScanner(directory: sourceDir, includeHiddenFiles: allowHidden)
        let files = try scanner.scan()

        print("Found \(files.count) files to index.")

        let embedder = EmbeddingService()
        let extractor = TextExtractor()

        var indexed = 0
        var skippedUnreadable = 0
        var skippedEmbedFailures = 0
        for file in files {
            let chunks: [TextChunk]
            do {
                chunks = try extractor.extract(from: file)
            } catch {
                skippedUnreadable += 1
                continue
            }
            if chunks.isEmpty {
                skippedUnreadable += 1
                continue
            }
            var embedFailures = 0
            for chunk in chunks {
                guard let embedding = embedder.embed(chunk.text) else {
                    embedFailures += 1
                    continue
                }
                try database.insert(
                    filePath: file.relativePath,
                    lineStart: chunk.lineStart,
                    lineEnd: chunk.lineEnd,
                    chunkType: chunk.type,
                    pageNumber: chunk.pageNumber,
                    fileModifiedAt: file.modificationDate,
                    contentPreview: String(chunk.text.prefix(200)),
                    embedding: embedding
                )
            }
            if embedFailures == chunks.count {
                skippedEmbedFailures += 1
                print("  Skipped: \(file.relativePath) (failed to embed)")
            } else {
                indexed += 1
                print("  [\(indexed)/\(files.count - skippedUnreadable - skippedEmbedFailures)] \(file.relativePath)")
            }
        }

        let skipped = skippedUnreadable + skippedEmbedFailures
        if skipped > 0 {
            var details: [String] = []
            if skippedUnreadable > 0 {
                details.append("\(skippedUnreadable) unreadable")
            }
            if skippedEmbedFailures > 0 {
                details.append("\(skippedEmbedFailures) failed to embed")
            }
            print("Indexed \(indexed) files (\(skipped) skipped: \(details.joined(separator: ", "))). Database ready at \(dbDir.path)/index.db")
        } else {
            print("Indexed \(indexed) files. Database ready at \(dbDir.path)/index.db")
        }
    }
}
