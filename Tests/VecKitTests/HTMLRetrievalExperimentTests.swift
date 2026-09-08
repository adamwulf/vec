import CryptoKit
import Foundation
import XCTest
@testable import VecKit

/// E14's opt-in synthetic retrieval comparison. The committed corpus and
/// labels are frozen before this test is run. It deliberately bypasses the
/// not-yet-shared mode dispatcher, but uses the production HTML reader,
/// e5-base-v2 embedder, and VectorDatabase. Every fixture is below the frozen
/// 1,200-character chunk size, so each arm embeds exactly the same whole-file
/// unit that TextExtractor will create once shared wiring lands.
final class HTMLRetrievalExperimentTests: XCTestCase {
    private static let modelDefault = "/private/tmp/vec-e10-model/f52bf8ec8c7124536f0efb74aca902b2995e5bcd"
    private var scratch: URL?

    override func tearDown() {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        super.tearDown()
    }

    func testSyntheticHTMLRetrievalBenchmark() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["VEC_E14_BENCHMARK"] == "1",
            "Heavy opt-in E14 retrieval benchmark"
        )

        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let experiment = repo.appendingPathComponent("experiments/E14-html-extraction")
        let sample = experiment.appendingPathComponent("sample")
        let queryURL = experiment.appendingPathComponent("queries/rubric-queries.json")
        let sampleManifestURL = sample.appendingPathComponent("manifest.json")
        let model = URL(
            fileURLWithPath: environment["VEC_E14_MODEL_DIRECTORY"] ?? Self.modelDefault,
            isDirectory: true
        )
        guard let outputRaw = environment["VEC_E14_OUTPUT_DIRECTORY"] else {
            throw E14HarnessError("VEC_E14_OUTPUT_DIRECTORY is required")
        }
        let output = URL(fileURLWithPath: outputRaw, isDirectory: true)
        try prepareEmptyDirectory(output)

        let queriesData = try Data(contentsOf: queryURL)
        let rubric = try JSONDecoder().decode(Rubric.self, from: queriesData)
        let sampleManifestData = try Data(contentsOf: sampleManifestURL)
        let sampleManifest = try JSONDecoder().decode(SampleManifest.self, from: sampleManifestData)
        try validate(rubric: rubric, sample: sampleManifest, at: sample)

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("vec-e14-\(UUID().uuidString)", isDirectory: true)
        self.scratch = scratch
        let snapshot = scratch.appendingPathComponent("snapshot", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        for file in sampleManifest.files {
            try FileManager.default.copyItem(
                at: sample.appendingPathComponent(file.path),
                to: snapshot.appendingPathComponent(file.path)
            )
        }

        let modelFiles = try hashFiles(in: model)
        guard !modelFiles.isEmpty else { throw E14HarnessError("pinned model directory is empty") }
        let packageResolved = repo.appendingPathComponent("Package.resolved")
        let provenance = FrozenProvenance(
            run_identity: sha256Hex(Data((
                sha256Hex(queriesData) + sha256Hex(sampleManifestData) +
                modelFiles.map(\.sha256).joined()
            ).utf8)),
            frozen_at: ISO8601DateFormatter().string(from: Date()),
            git_head: try commandOutput("/usr/bin/git", ["rev-parse", "HEAD"], at: repo),
            git_dirty: !(try commandOutput("/usr/bin/git", ["status", "--porcelain"], at: repo)).isEmpty,
            package_resolved_sha256: sha256Hex(try Data(contentsOf: packageResolved)),
            query_manifest_sha256: sha256Hex(queriesData),
            sample_manifest_sha256: sha256Hex(sampleManifestData),
            settings: [
                "profile_identity": "e5-base@1200/0",
                "embedder": "e5-base-v2",
                "chunk_chars": "1200",
                "chunk_overlap": "0",
                "search_limit": "7",
                "harness": "direct whole-document parity path",
            ],
            model_files: modelFiles
        )
        try writeJSON(provenance, to: output.appendingPathComponent("frozen-input-manifest.json"))

        let embedder = E5BaseEmbedder(modelDirectory: model)
        for arm in rubric.arms {
            try await run(
                arm: arm,
                rubric: rubric,
                snapshot: snapshot,
                output: output.appendingPathComponent(arm.key, isDirectory: true),
                scratch: scratch.appendingPathComponent("db-\(arm.key)", isDirectory: true),
                embedder: embedder
            )
        }
    }

    private func run(
        arm: Rubric.Arm,
        rubric: Rubric,
        snapshot: URL,
        output: URL,
        scratch: URL,
        embedder: E5BaseEmbedder
    ) async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let db = VectorDatabase(databaseDirectory: scratch, sourceDirectory: snapshot, dimension: embedder.dimension)
        try await db.initialize()
        var extracted: [String: String] = [:]

        for file in rubric.corpusFiles.sorted() {
            let url = snapshot.appendingPathComponent(file)
            let html = try String(contentsOf: url, encoding: .utf8)
            let text: String
            switch arm.text_extraction {
            case "raw":
                text = html
            case "html-v1":
                let options = try HTMLExtractionOptions(
                    maximumInputBytes: 16 * 1_024 * 1_024,
                    maximumElementCount: 250_000
                )
                text = try HTMLReadableContentExtractor.extract(
                    html,
                    sourceURL: url,
                    options: options
                ).renderedText()
            default:
                throw E14HarnessError("unsupported arm mode \(arm.text_extraction)")
            }
            extracted[file] = text
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let embedding = try await embedder.embedDocument(text)
            guard embedding.count == embedder.dimension else {
                throw E14HarnessError("empty/wrong embedding for \(arm.key)/\(file)")
            }
            try await db.insert(
                filePath: file,
                lineStart: nil,
                lineEnd: nil,
                chunkType: .whole,
                pageNumber: nil,
                fileModifiedAt: Date(timeIntervalSince1970: 0),
                contentPreview: text,
                embedding: embedding
            )
        }

        for query in rubric.queries {
            let queryEmbedding = try await embedder.embedQuery(query.text)
            let matches = try await db.search(embedding: queryEmbedding, limit: 7)
            let groups = matches.enumerated().map { index, match in
                E14ArchivedGroup(
                    rank: index + 1,
                    file: match.filePath,
                    best_score: 1 - match.distance,
                    matches: [E14ArchivedMatch(score: 1 - match.distance, distance: match.distance)]
                )
            }
            let fileRank = query.primary_file.flatMap { primary in
                groups.firstIndex { $0.file == primary }.map { $0 + 1 }
            }
            let result = E14ArchivedResult(
                groups: groups,
                file_rank: fileRank,
                primary_text: query.primary_file.flatMap { extracted[$0] } ?? ""
            )
            try writeJSON(result, to: output.appendingPathComponent("\(query.id).json"))
        }
    }

    private func validate(rubric: Rubric, sample: SampleManifest, at root: URL) throws {
        guard rubric.schema_version == 1, rubric.experiment == "E14-html-extraction" else {
            throw E14HarnessError("unsupported rubric")
        }
        guard Set(rubric.arms.map(\.key)) == Set(["raw", "html-v1"]) else {
            throw E14HarnessError("rubric arms must be raw and html-v1")
        }
        let files = sample.files.map(\.path).sorted()
        guard files.count == 7, Set(files) == Set(rubric.corpusFiles) else {
            throw E14HarnessError("sample/rubric file inventory mismatch")
        }
        for entry in sample.files {
            let data = try Data(contentsOf: root.appendingPathComponent(entry.path))
            guard data.count == entry.bytes, sha256Hex(data) == entry.sha256 else {
                throw E14HarnessError("frozen fixture drift: \(entry.path)")
            }
        }
        let known = Set(files)
        for query in rubric.queries {
            if let primary = query.primary_file, !known.contains(primary) {
                throw E14HarnessError("query \(query.id) references missing \(primary)")
            }
        }
    }

    private func prepareEmptyDirectory(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let contents = try FileManager.default.contentsOfDirectory(atPath: url.path)
            guard contents.isEmpty else { throw E14HarnessError("output directory must be empty") }
        } else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private func hashFiles(in directory: URL) throws -> [HashedFile] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [HashedFile] = []
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let relative = String(url.path.dropFirst(directory.path.count + 1))
            let hashed = try hashFile(url)
            files.append(.init(path: relative, bytes: hashed.bytes, sha256: hashed.sha256))
        }
        return files.sorted { $0.path < $1.path }
    }

    private func commandOutput(_ executable: String, _ arguments: [String], at directory: URL) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw E14HarnessError("command failed: \(executable)") }
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func hashFile(_ url: URL) throws -> (bytes: Int, sha256: String) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var bytes = 0
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty {
            bytes += data.count
            hasher.update(data: data)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (bytes, digest)
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

private struct E14HarnessError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private struct Rubric: Decodable {
    struct Corpus: Decodable { let expected_html_files: Int }
    struct Arm: Decodable { let key: String; let text_extraction: String }
    struct Query: Decodable { let id: String; let text: String; let primary_file: String? }
    let schema_version: Int
    let experiment: String
    let corpus: Corpus
    let arms: [Arm]
    let queries: [Query]
    var corpusFiles: [String] {
        ["article.html", "executable-only.html", "malformed.html", "navigation-directory.html",
         "navigation-heavy.html", "reference.html", "structural.html"]
    }
}

private struct SampleManifest: Decodable {
    struct File: Decodable { let path: String; let bytes: Int; let sha256: String }
    let files: [File]
}

private struct HashedFile: Codable {
    let path: String
    let bytes: Int
    let sha256: String
}

private struct FrozenProvenance: Encodable {
    let run_identity: String
    let frozen_at: String
    let git_head: String
    let git_dirty: Bool
    let package_resolved_sha256: String
    let query_manifest_sha256: String
    let sample_manifest_sha256: String
    let settings: [String: String]
    let model_files: [HashedFile]
}

private struct E14ArchivedMatch: Encodable {
    let score: Double
    let distance: Double
}

private struct E14ArchivedGroup: Encodable {
    let rank: Int
    let file: String
    let best_score: Double
    let matches: [E14ArchivedMatch]
}

private struct E14ArchivedResult: Encodable {
    let groups: [E14ArchivedGroup]
    let file_rank: Int?
    let primary_text: String
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
