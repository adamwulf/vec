import Foundation
import ArgumentParser
import VecKit

struct InsertCommand: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "insert",
        abstract: "Add or update a specific file in the vector index"
    )

    @Option(name: .shortAndLong, help: "Name of the database (stored in ~/.vec/<name>/). Omit to resolve from current directory.")
    var db: String?

    @Argument(help: "Path to the file to index")
    var path: String

    func run() async throws {
        let (dbDir, rawConfig, sourceDir) = try db != nil
            ? DatabaseLocator.resolve(db!)
            : DatabaseLocator.resolveFromCurrentDirectory()

        // Pre-refactor DBs: stamp nomic on the config if vectors exist
        // but no embedder was recorded — see SearchCommand for the same
        // migration.
        let config: DatabaseConfig
        do {
            let probe = VectorDatabase(databaseDirectory: dbDir, sourceDirectory: sourceDir)
            try await probe.open()
            let chunkCount = try await probe.totalChunkCount()
            config = try DatabaseLocator.migratePreRefactorEmbedderRecord(
                config: rawConfig, chunkCount: chunkCount, dbDir: dbDir
            )
        }

        // Resolve path relative to cwd, then validate it falls within sourceDir
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let filePath = URL(fileURLWithPath: path, relativeTo: cwd).standardized

        // Validate path is within the source directory (append "/" to prevent prefix collisions)
        guard filePath.path.hasPrefix(sourceDir.path + "/") else {
            print("Error: Path must be within the source directory (\(sourceDir.path)).")
            throw ExitCode.failure
        }

        guard FileManager.default.fileExists(atPath: filePath.path) else {
            print("Error: File not found: \(path)")
            throw ExitCode.failure
        }

        // Insert doesn't take --embedder: it always uses whatever the
        // DB was indexed with. A fresh DB that has never been indexed
        // can't be inserted into piecemeal — point the user at
        // update-index so the embedder choice is explicit.
        guard let recorded = config.embedder else {
            print("Error: " + VecError.embedderNotRecorded.errorDescription!)
            throw ExitCode.failure
        }
        guard let embedderAlias = EmbedderFactory.alias(forCanonicalName: recorded.name) else {
            print("Error: " + VecError.unknownEmbedder(recorded.name).errorDescription!)
            throw ExitCode.failure
        }
        let activeEmbedder = try EmbedderFactory.make(alias: embedderAlias)

        let database = VectorDatabase(
            databaseDirectory: dbDir,
            sourceDirectory: sourceDir,
            dimension: recorded.dimension
        )
        try await database.open()

        let fileInfo = try FileScanner.fileInfo(for: filePath, relativeTo: sourceDir)

        // Use the pipeline for single-file indexing — still benefits from
        // parallel chunk embedding for large files.
        let pipeline = IndexingPipeline(embedder: activeEmbedder)
        let (results, _) = try await pipeline.run(
            workItems: [(file: fileInfo, label: "Updated")],
            extractor: TextExtractor(),
            database: database
        )

        let relativePath = fileInfo.relativePath
        if let result = results.first {
            switch result {
            case .indexed(_, _, let chunkCount):
                print("Indexed \(chunkCount) chunks from \(relativePath)")
            case .skippedUnreadable:
                print("Warning: could not read \(relativePath)")
            case .skippedEmbedFailure:
                print("Warning: chunks extracted but none could be embedded from \(relativePath)")
            }
        }
    }
}
