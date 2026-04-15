import Foundation
import ArgumentParser
import VecKit

struct InitCommand: AsyncParsableCommand {

    static var configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Initialize a vector database in the current directory"
    )

    @Flag(name: .long, help: "Overwrite existing database if present")
    var force: Bool = false

    @Flag(name: .long, help: "Include hidden files and folders")
    var allowHidden: Bool = false

    func run() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let vecDir = directory.appendingPathComponent(".vec")

        if FileManager.default.fileExists(atPath: vecDir.path) && !force {
            print("Error: .vec/ already exists. Use --force to reinitialize.")
            throw ExitCode.failure
        }

        print("Initializing vector database in \(directory.path)...")

        let database = VectorDatabase(directory: directory)
        try database.initialize()

        let scanner = FileScanner(directory: directory, includeHiddenFiles: allowHidden)
        let files = try scanner.scan()

        print("Found \(files.count) files to index.")

        let embedder = EmbeddingService()
        let extractor = TextExtractor()

        var indexed = 0
        var skippedUnreadable = 0
        var skippedEmbedFailures = 0
        for file in files {
            let chunks = try extractor.extract(from: file)
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
            } else {
                indexed += 1
            }
            print("  [\(indexed + skippedEmbedFailures)/\(files.count - skippedUnreadable)] \(file.relativePath)")
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
            print("Indexed \(indexed) files (\(skipped) skipped: \(details.joined(separator: ", "))). Database ready at .vec/index.db")
        } else {
            print("Indexed \(indexed) files. Database ready at .vec/index.db")
        }
    }
}
