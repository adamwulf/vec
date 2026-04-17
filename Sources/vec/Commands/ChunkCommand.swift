import Foundation
import ArgumentParser
import VecKit

struct ChunkCommand: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "chunk",
        abstract: "Print the content of a single indexed chunk by 1-based position"
    )

    @Option(name: .shortAndLong, help: "Name of the database (stored in ~/.vec/<name>/). Omit to resolve from current directory.")
    var db: String?

    @Argument(help: "1-based chunk index within the file (ordered by insertion)")
    var index: Int

    @Argument(help: "Path to the indexed file")
    var path: String

    func run() async throws {
        guard index >= 1 else {
            print("Error: chunk index must be 1-based (>= 1).")
            throw ExitCode.failure
        }

        let (dbDir, _, sourceDir) = try db != nil
            ? DatabaseLocator.resolve(db!)
            : DatabaseLocator.resolveFromCurrentDirectory()

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let filePath = URL(fileURLWithPath: path, relativeTo: cwd).standardized

        guard filePath.path.hasPrefix(sourceDir.path + "/") else {
            print("Error: Path must be within the source directory (\(sourceDir.path)).")
            throw ExitCode.failure
        }

        let relativePath = PathUtilities.relativePath(of: filePath.path, in: sourceDir.path)

        let database = VectorDatabase(databaseDirectory: dbDir, sourceDirectory: sourceDir)
        try await database.open()

        let total = try await database.chunkCount(filePath: relativePath)
        guard total > 0 else {
            print("No chunks found for \(relativePath).")
            throw ExitCode.failure
        }

        guard let chunk = try await database.fetchChunk(filePath: relativePath, index: index) else {
            print("Chunk \(index) out of range — \(relativePath) has \(total) chunk\(total == 1 ? "" : "s").")
            throw ExitCode.failure
        }

        let locationDescription: String
        if chunk.chunkType == .image {
            locationDescription = "OCR"
        } else if chunk.chunkType == .whole {
            locationDescription = "whole file"
        } else if let start = chunk.lineStart, let end = chunk.lineEnd {
            locationDescription = "lines \(start)-\(end)"
        } else if let page = chunk.pageNumber {
            locationDescription = "page \(page)"
        } else {
            locationDescription = "chunk \(index)"
        }

        print("\(relativePath)  (chunk \(index)/\(total), \(locationDescription))")
        if let preview = chunk.contentPreview {
            print(preview)
        }
    }
}
