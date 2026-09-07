import XCTest
import ArgumentParser
import VecKit
@testable import vec

final class TextExtractionModeTests: XCTestCase {
    /// Every non-raw mode. `raw` is the default and is exercised separately;
    /// these are the modes a user must explicitly opt into.
    private static let optInModes: [TextExtractionMode] = TextExtractionMode.allCases.filter { $0 != .raw }

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
        // Every versioned mode is opt-in on a fresh DB and is persisted
        // (writeProfileRecord) so later updates/inserts inherit it.
        for mode in Self.optInModes {
            let normalized = try resolve(config(), requested: mode)
            XCTAssertEqual(normalized.textExtraction, mode)
            XCTAssertTrue(normalized.writeProfileRecord, "\(mode.rawValue) should persist on first index")
        }
    }

    func testRecordedModeIsInheritedOnUpdatesAndReturnedForInsert() throws {
        // Every recorded mode (including raw) is inherited on updates when
        // --text-extraction is omitted, and returned unchanged for inserts.
        for mode in TextExtractionMode.allCases {
            let recorded = config(mode: mode)
            let update = try resolve(recorded, chunks: 42)
            XCTAssertEqual(update.textExtraction, mode)
            XCTAssertFalse(update.writeProfileRecord, "recorded \(mode.rawValue) must not rewrite the profile")
            XCTAssertEqual(
                try ProfileChecks.requireRecordedProfile(config: recorded, chunkCount: 42).textExtraction,
                mode,
                "insert must reuse recorded \(mode.rawValue)")
        }
    }

    func testExplicitlyRequestingTheRecordedModeIsNotAMismatch() throws {
        // Passing --text-extraction that matches the recorded mode is a
        // no-op inherit, not a mismatch, for every mode.
        for mode in TextExtractionMode.allCases {
            let update = try resolve(config(mode: mode), requested: mode, chunks: 42)
            XCTAssertEqual(update.textExtraction, mode)
            XCTAssertFalse(update.writeProfileRecord)
        }
    }

    func testEveryModeChangeRequiresResetEvenWhenNoChunksSurvived() throws {
        // Exhaustively cover every ordered (recorded, requested) pair of
        // distinct modes. The mismatch guard fires before the profile
        // identity check, so it holds regardless of chunk count — including
        // the 0-chunk case where a prior index extracted nothing.
        for chunks in [0, 42] {
            for recordedMode in TextExtractionMode.allCases {
                for requestedMode in TextExtractionMode.allCases where requestedMode != recordedMode {
                    XCTAssertThrowsError(
                        try resolve(config(mode: recordedMode), requested: requestedMode, chunks: chunks),
                        "expected mismatch for recorded=\(recordedMode.rawValue) requested=\(requestedMode.rawValue) chunks=\(chunks)"
                    ) { error in
                        guard case TextExtractionError.mismatch(let recorded, let requested) = error else {
                            return XCTFail("Unexpected error: \(error)")
                        }
                        XCTAssertEqual(recorded, recordedMode)
                        XCTAssertEqual(requested, requestedMode)
                    }
                }
            }
        }
    }

    func testCLIParsesEveryModeAndRejectsUnknownVersion() throws {
        // Each versioned mode string round-trips through argument parsing to
        // its TextExtractionMode.
        let expected: [String: TextExtractionMode] = [
            "raw": .raw,
            "markdown-v1": .markdownV1,
            "vtt-v1": .vttV1,
            "markdown-v1+vtt-v1": .markdownV1VttV1,
            "image-ocr-v1": .imageOCRV1,
            "markdown-v1+image-ocr-v1": .markdownV1ImageOCRV1,
            "vtt-v1+image-ocr-v1": .vttV1ImageOCRV1,
            "markdown-v1+vtt-v1+image-ocr-v1": .markdownV1VttV1ImageOCRV1,
        ]
        for (raw, mode) in expected {
            let command = try XCTUnwrap(
                UpdateIndexCommand.parseAsRoot(["--text-extraction", raw]) as? UpdateIndexCommand)
            XCTAssertEqual(command.textExtraction?.mode, mode, "parsing \(raw)")
        }
        // Unknown / mis-versioned strings are rejected at parse time, before
        // any DB work.
        for bad in ["markdown-v2", "vtt-v2", "vtt", "markdown", "markdown-v1+vtt-v2", "image-ocr-v2", "image-ocr-v1+raw", "image-ocr-v1+image-ocr-v1", "image-ocr-v1+vtt-v1"] {
            XCTAssertThrowsError(try UpdateIndexCommand.parseAsRoot(["--text-extraction", bad]),
                                 "\(bad) should be rejected")
        }
        let defaultCommand = try XCTUnwrap(UpdateIndexCommand.parseAsRoot([]) as? UpdateIndexCommand)
        XCTAssertNil(defaultCommand.textExtraction)
    }

    func testOCRConcurrencyParsingAndValidation() throws {
        let defaults = try XCTUnwrap(UpdateIndexCommand.parseAsRoot([]) as? UpdateIndexCommand)
        XCTAssertEqual(defaults.ocrConcurrency, 1)
        for count in [1, 4, 8] {
            let command = try XCTUnwrap(UpdateIndexCommand.parseAsRoot(["--ocr-concurrency", String(count)]) as? UpdateIndexCommand)
            XCTAssertEqual(command.ocrConcurrency, count)
        }
        for invalid in ["0", "-1", "abc"] {
            XCTAssertThrowsError(try UpdateIndexCommand.parseAsRoot(["--ocr-concurrency", invalid]))
        }
    }

    func testCLIOptionMapsOneToOneWithEveryPersistedMode() {
        // Guards against a CLI/VecKit drift: every persisted TextExtractionMode
        // must have a corresponding CLI option whose `.mode` maps back to it,
        // and vice versa.
        XCTAssertEqual(Set(TextExtractionOption.allCases.map(\.mode)),
                       Set(TextExtractionMode.allCases))
        for option in TextExtractionOption.allCases {
            XCTAssertEqual(option.rawValue, option.mode.rawValue,
                           "CLI and persisted raw values must match for \(option.rawValue)")
        }
    }

    func testLegacyRecordDefaultsToRawAndUnknownModeFailsDecoding() throws {
        let old = Data(#"{"identity":"e5-base@1200/0","embedderName":"e5-base-v2","dimension":768}"#.utf8)
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(DatabaseConfig.ProfileRecord.self, from: old).textExtraction, .raw)
        let unknown = Data(#"{"identity":"e5-base@1200/0","embedderName":"e5-base-v2","dimension":768,"textExtraction":"markdown-v999"}"#.utf8)
        XCTAssertThrowsError(try decoder.decode(DatabaseConfig.ProfileRecord.self, from: unknown))
    }

    func testEveryModeRoundTripsThroughConfigFile() throws {
        for mode in TextExtractionMode.allCases {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let original = config(mode: mode)
            try DatabaseLocator.writeConfig(original, to: root)
            let decoded = try DatabaseLocator.readConfig(from: root)
            XCTAssertEqual(decoded.profile, original.profile, "\(mode.rawValue) profile round-trip")
            XCTAssertEqual(try resolve(decoded).textExtraction, mode, "\(mode.rawValue) resolve after round-trip")
        }
    }
}
