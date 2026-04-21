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
        // Step 1: resolve DB, open to count chunks.
        let (dbDir, config, sourceDir) = try db != nil
            ? DatabaseLocator.resolve(db!)
            : DatabaseLocator.resolveFromCurrentDirectory()

        let probeDim = config.profile?.dimension ?? 1
        let probe = VectorDatabase(
            databaseDirectory: dbDir,
            sourceDirectory: sourceDir,
            dimension: probeDim
        )
        try await probe.open()
        let chunkCount = try await probe.totalChunkCount()

        // Step 2: missing-profile split.
        let recorded = try ProfileChecks.requireRecordedProfile(
            config: config,
            chunkCount: chunkCount
        )

        // Step 3: resolve live profile.
        let profile = try IndexingProfileFactory.resolve(identity: recorded.identity)

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

        // Step 4: open DB at the recorded dim and run the pipeline with
        // the profile's splitter so single-file inserts honor the
        // recorded chunk settings (pre-3e this defaulted to the
        // splitter's hardcoded defaults regardless of what the DB was
        // indexed at).
        let database = VectorDatabase(
            databaseDirectory: dbDir,
            sourceDirectory: sourceDir,
            dimension: recorded.dimension
        )
        try await database.open()

        let fileInfo = try FileScanner.fileInfo(for: filePath, relativeTo: sourceDir)

        let pipeline = IndexingPipeline(profile: profile)
        let (results, _) = try await pipeline.run(
            workItems: [(file: fileInfo, label: "Updated")],
            extractor: TextExtractor(splitter: profile.splitter),
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
                // Same silent-failure guard as `update-index`. A single
                // insert that produces zero vectors must exit non-zero so
                // callers (scripts, editor integrations) can react rather
                // than assuming the file is now in the index.
                throw VecError.indexingProducedNoVectors(
                    filesAttempted: 1,
                    filesFailed: 1
                )
            }
        }
    }
}
