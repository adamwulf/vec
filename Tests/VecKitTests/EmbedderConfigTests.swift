import XCTest
@testable import VecKit

/// Unit tests for the pluggable-embedder wiring that don't require
/// loading a real model:
///
/// - `DatabaseConfig` round-trips `embedder: EmbedderRecord?` through
///   JSON in both present and nil forms, and decodes pre-refactor
///   config.json files (no `embedder` key) with nil — the backward-
///   compat contract documented on `DatabaseConfig.embedder`.
/// - `EmbedderFactory` resolves "nomic" / "nl" to the expected
///   canonical names and dimensions, round-trips an alias through
///   `canonicalName(forAlias:)` + `alias(forCanonicalName:)`, and
///   throws `VecError.unknownEmbedder` for an unrecognized alias.
final class EmbedderConfigTests: XCTestCase {

    // MARK: - DatabaseConfig round-trip

    private func makeEncoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return enc
    }

    private func makeDecoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }

    func testDatabaseConfigRoundTripsWithEmbedderRecord() throws {
        let original = DatabaseConfig(
            sourceDirectory: "/tmp/source",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            embedder: .init(name: "nomic-v1.5-768", dimension: 768)
        )

        let data = try makeEncoder().encode(original)
        let decoded = try makeDecoder().decode(DatabaseConfig.self, from: data)

        XCTAssertEqual(decoded.sourceDirectory, original.sourceDirectory)
        XCTAssertEqual(decoded.createdAt, original.createdAt)
        XCTAssertEqual(decoded.embedder, original.embedder)
    }

    func testDatabaseConfigRoundTripsWithNilEmbedder() throws {
        let original = DatabaseConfig(
            sourceDirectory: "/tmp/source",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            embedder: nil
        )

        let data = try makeEncoder().encode(original)
        let decoded = try makeDecoder().decode(DatabaseConfig.self, from: data)

        XCTAssertNil(decoded.embedder)
        XCTAssertEqual(decoded.sourceDirectory, original.sourceDirectory)
    }

    /// Pre-refactor DBs have config.json without an "embedder" key.
    /// Those must decode with `embedder == nil` so existing users
    /// don't get hard failures the first time they upgrade.
    func testDatabaseConfigDecodesPreRefactorJSONWithNilEmbedder() throws {
        let legacyJSON = """
        {
          "createdAt" : "2024-01-01T00:00:00Z",
          "sourceDirectory" : "/tmp/legacy"
        }
        """
        let data = Data(legacyJSON.utf8)

        let decoded = try makeDecoder().decode(DatabaseConfig.self, from: data)

        XCTAssertNil(decoded.embedder)
        XCTAssertEqual(decoded.sourceDirectory, "/tmp/legacy")
    }

    // MARK: - EmbedderFactory alias mapping

    func testEmbedderFactoryKnownAliasesResolveToCanonicalNamesAndDims() throws {
        let nomic = try EmbedderFactory.make(alias: "nomic")
        XCTAssertEqual(nomic.name, "nomic-v1.5-768")
        XCTAssertEqual(nomic.dimension, 768)

        let nl = try EmbedderFactory.make(alias: "nl")
        XCTAssertEqual(nl.name, "nl-en-512")
        XCTAssertEqual(nl.dimension, 512)
    }

    func testEmbedderFactoryCanonicalNameRoundTripsThroughAlias() throws {
        for alias in EmbedderFactory.knownAliases {
            let canonical = try EmbedderFactory.canonicalName(forAlias: alias)
            let roundTripped = EmbedderFactory.alias(forCanonicalName: canonical)
            XCTAssertEqual(roundTripped, alias,
                           "alias '\(alias)' should round-trip through canonical name '\(canonical)'")
        }
    }

    func testEmbedderFactoryAliasForUnknownCanonicalNameIsNil() {
        XCTAssertNil(EmbedderFactory.alias(forCanonicalName: "not-a-real-embedder"))
    }

    func testEmbedderFactoryUnknownAliasThrowsUnknownEmbedder() {
        XCTAssertThrowsError(try EmbedderFactory.make(alias: "does-not-exist")) { error in
            guard case VecError.unknownEmbedder(let alias) = error else {
                XCTFail("expected VecError.unknownEmbedder, got \(error)")
                return
            }
            XCTAssertEqual(alias, "does-not-exist")
        }
    }

    func testEmbedderFactoryDefaultAliasIsKnown() {
        XCTAssertTrue(EmbedderFactory.knownAliases.contains(EmbedderFactory.defaultAlias),
                      "defaultAlias '\(EmbedderFactory.defaultAlias)' must be in knownAliases")
    }
}
