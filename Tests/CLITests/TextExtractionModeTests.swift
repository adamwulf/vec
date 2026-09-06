import XCTest
import ArgumentParser
import VecKit
@testable import vec

final class TextExtractionModeTests: XCTestCase {
    private func config(mode: TextExtractionMode? = nil) -> DatabaseConfig {
        DatabaseConfig(sourceDirectory: "/tmp/source", createdAt: Date(), profile: mode.map {
            .init(identity: "e5-base@1200/0", embedderName: "e5-base-v2", dimension: 768, textExtraction: $0)
        })
    }

    private func resolve(_ config: DatabaseConfig, requested: TextExtractionMode? = nil,
                         chunks: Int = 0) throws -> UpdateIndexCommand.ProfileResolution {
        try UpdateIndexCommand.resolveRequestedProfile(
            config: config, chunkCount: chunks,
            cliEmbedder: nil, cliChunkChars: nil, cliChunkOverlap: nil,
            cliTextExtraction: requested)
    }

    func testNewDatabaseDefaultsToRawAndCanOptIn() throws {
        XCTAssertEqual(try resolve(config()).textExtraction, .raw)
        let normalized = try resolve(config(), requested: .markdownV1)
        XCTAssertEqual(normalized.textExtraction, .markdownV1)
        XCTAssertTrue(normalized.writeProfileRecord)
    }

    func testRecordedModeIsInheritedOnUpdatesAndReturnedForInsert() throws {
        let recorded = config(mode: .markdownV1)
        let update = try resolve(recorded, chunks: 42)
        XCTAssertEqual(update.textExtraction, .markdownV1)
        XCTAssertFalse(update.writeProfileRecord)
        XCTAssertEqual(try ProfileChecks.requireRecordedProfile(config: recorded, chunkCount: 42).textExtraction, .markdownV1)
    }

    func testModeChangesRequireResetEvenWhenNoChunksSurvived() throws {
        for count in [0, 42] {
            for mode in TextExtractionMode.allCases {
                let other: TextExtractionMode = mode == .raw ? .markdownV1 : .raw
                XCTAssertThrowsError(try resolve(config(mode: mode), requested: other, chunks: count)) { error in
                    guard case TextExtractionError.mismatch(let recorded, let requested) = error else {
                        return XCTFail("Unexpected error: \(error)")
                    }
                    XCTAssertEqual(recorded, mode)
                    XCTAssertEqual(requested, other)
                }
            }
        }
    }

    func testCLIParsesExplicitModeAndRejectsUnknownVersion() throws {
        let command = try XCTUnwrap(UpdateIndexCommand.parseAsRoot(["--text-extraction", "markdown-v1"]) as? UpdateIndexCommand)
        XCTAssertEqual(command.textExtraction?.mode, .markdownV1)
        XCTAssertThrowsError(try UpdateIndexCommand.parseAsRoot(["--text-extraction", "markdown-v2"]))
        let defaultCommand = try XCTUnwrap(UpdateIndexCommand.parseAsRoot([]) as? UpdateIndexCommand)
        XCTAssertNil(defaultCommand.textExtraction)
    }

    func testLegacyRecordDefaultsToRawAndUnknownModeFailsDecoding() throws {
        let old = Data(#"{"identity":"e5-base@1200/0","embedderName":"e5-base-v2","dimension":768}"#.utf8)
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(DatabaseConfig.ProfileRecord.self, from: old).textExtraction, .raw)
        let unknown = Data(#"{"identity":"e5-base@1200/0","embedderName":"e5-base-v2","dimension":768,"textExtraction":"markdown-v999"}"#.utf8)
        XCTAssertThrowsError(try decoder.decode(DatabaseConfig.ProfileRecord.self, from: unknown))
    }

    func testNormalizedModeRoundTripsThroughConfigFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = config(mode: .markdownV1)
        try DatabaseLocator.writeConfig(original, to: root)
        let decoded = try DatabaseLocator.readConfig(from: root)
        XCTAssertEqual(decoded.profile, original.profile)
        XCTAssertEqual(try resolve(decoded).textExtraction, .markdownV1)
    }
}
