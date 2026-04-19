import XCTest
@testable import VecKit

/// Unit tests for `DatabaseConfig` persistence and embedder-alias
/// resolution that don't require loading a real model. Covers both
/// the legacy `embedder: EmbedderRecord?` path (kept through Phase 3d)
/// and the new `profile: ProfileRecord?` path added in Phase 3c.
final class IndexingProfileConfigTests: XCTestCase {

    // MARK: - JSON helpers

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

    // MARK: - Legacy embedder-field round-trip (still required through 3d)

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
        XCTAssertNil(decoded.profile)
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
        XCTAssertNil(decoded.profile)
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
        XCTAssertNil(decoded.profile)
        XCTAssertEqual(decoded.sourceDirectory, "/tmp/legacy")
    }

    // MARK: - New profile-field round-trip (Phase 3c)

    func testDatabaseConfigRoundTripsWithProfileRecord() throws {
        let original = DatabaseConfig(
            sourceDirectory: "/tmp/source",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            embedder: nil,
            profile: .init(
                identity: "nomic@1200/240",
                embedderName: "nomic-v1.5-768",
                dimension: 768
            )
        )

        let data = try makeEncoder().encode(original)
        let decoded = try makeDecoder().decode(DatabaseConfig.self, from: data)

        XCTAssertEqual(decoded.sourceDirectory, original.sourceDirectory)
        XCTAssertEqual(decoded.createdAt, original.createdAt)
        XCTAssertNil(decoded.embedder)
        XCTAssertEqual(decoded.profile, original.profile)
        XCTAssertEqual(decoded.profile?.identity, "nomic@1200/240")
        XCTAssertEqual(decoded.profile?.embedderName, "nomic-v1.5-768")
        XCTAssertEqual(decoded.profile?.dimension, 768)
    }

    func testDatabaseConfigRoundTripsWithNilProfile() throws {
        let original = DatabaseConfig(
            sourceDirectory: "/tmp/source",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            embedder: nil,
            profile: nil
        )

        let data = try makeEncoder().encode(original)
        let decoded = try makeDecoder().decode(DatabaseConfig.self, from: data)

        XCTAssertNil(decoded.embedder)
        XCTAssertNil(decoded.profile)
        XCTAssertEqual(decoded.sourceDirectory, original.sourceDirectory)
    }

    /// Coexistence case: both legacy `embedder` and new `profile` keys
    /// present in the same config. Both fields must round-trip verbatim
    /// — this is the shape written during the 3d→3e transition.
    func testDatabaseConfigRoundTripsWithBothEmbedderAndProfile() throws {
        let original = DatabaseConfig(
            sourceDirectory: "/tmp/source",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            embedder: .init(name: "nomic-v1.5-768", dimension: 768),
            profile: .init(
                identity: "nomic@1200/240",
                embedderName: "nomic-v1.5-768",
                dimension: 768
            )
        )

        let data = try makeEncoder().encode(original)
        let decoded = try makeDecoder().decode(DatabaseConfig.self, from: data)

        XCTAssertEqual(decoded.embedder, original.embedder)
        XCTAssertEqual(decoded.profile, original.profile)
    }

    /// Factory alias round-trip: a `ProfileRecord` built from a live
    /// `IndexingProfile` (via `IndexingProfileFactory.make(alias:)`)
    /// persists through `DatabaseLocator.writeConfig` / `readConfig`
    /// and the decoded identity equals the factory-made profile identity.
    func testDatabaseConfigRoundTripsProfileRecordFromFactoryAlias() throws {
        let profile = try IndexingProfileFactory.make(alias: "nomic")
        let record = DatabaseConfig.ProfileRecord(
            identity: profile.identity,
            embedderName: profile.embedder.name,
            dimension: profile.embedder.dimension
        )

        let original = DatabaseConfig(
            sourceDirectory: "/tmp/source",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            embedder: nil,
            profile: record
        )

        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vec-cfg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try DatabaseLocator.writeConfig(original, to: tmpDir)
        let decoded = try DatabaseLocator.readConfig(from: tmpDir)

        XCTAssertEqual(decoded.profile?.identity, profile.identity)
        XCTAssertEqual(decoded.profile?.identity, "nomic@1200/240")
        XCTAssertEqual(decoded.profile?.embedderName, profile.embedder.name)
        XCTAssertEqual(decoded.profile?.dimension, profile.embedder.dimension)
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

    func testEmbedderFactoryUnknownAliasThrowsUnknownProfile() {
        XCTAssertThrowsError(try EmbedderFactory.make(alias: "does-not-exist")) { error in
            guard case VecError.unknownProfile(let alias) = error else {
                XCTFail("expected VecError.unknownProfile, got \(error)")
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
