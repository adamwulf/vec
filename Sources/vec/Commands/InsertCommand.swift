import Foundation
import ArgumentParser
import VecKit

struct InsertCommand: AsyncParsableCommand {

    static var configuration = CommandConfiguration(
        commandName: "insert",
        abstract: "Add or update a specific file in the vector index"
    )

    @Option(name: .shortAndLong, help: "Name of the database (stored in ~/.vec/<name>/). Omit to resolve from current directory.")
    var db: String?

    @Argument(help: "Path to the file to index")
    var path: String

    func run() async throws {
        let (dbDir, _, sourceDir) = try db != nil
            ? DatabaseLocator.resolve(db!)
            : DatabaseLocator.resolveFromCurrentDirectory()

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

        let database = VectorDatabase(databaseDirectory: dbDir, sourceDirectory: sourceDir)
        try await database.open()

        let fileInfo = try FileScanner.fileInfo(for: filePath, relativeTo: sourceDir)

        // Use the pipeline for single-file indexing — still benefits from
        // parallel chunk embedding for large files.
        let pipeline = IndexingPipeline()
        let results = try await pipeline.run(
            workItems: [(file: fileInfo, label: "Updated")],
            extractor: TextExtractor(),
            database: database
        )

        let relativePath = fileInfo.relativePath
        if let result = results.first {
            switch result {
            case .indexed:
                // Count chunks from the pipeline result
                print("Indexed \(relativePath)")
            case .skippedUnreadable:
                print("Warning: could not read \(relativePath)")
            case .skippedEmbedFailure:
                print("Warning: chunks extracted but none could be embedded from \(relativePath)")
            }
        }
    }
}
