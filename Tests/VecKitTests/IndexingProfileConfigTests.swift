import XCTest
@testable import VecKit

/// Unit tests for `DatabaseConfig` persistence on the post-Phase-3e shape:
/// only `sourceDirectory`, `createdAt`, and the new `profile: ProfileRecord?`
/// field. The legacy `embedder: EmbedderRecord?` path is gone.
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

    // MARK: - Profile-field round-trip

    func testDatabaseConfigRoundTripsWithProfileRecord() throws {
        let original = DatabaseConfig(
            sourceDirectory: "/tmp/source",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
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
        XCTAssertEqual(decoded.profile, original.profile)
        XCTAssertEqual(decoded.profile?.identity, "nomic@1200/240")
        XCTAssertEqual(decoded.profile?.embedderName, "nomic-v1.5-768")
        XCTAssertEqual(decoded.profile?.dimension, 768)
    }

    func testDatabaseConfigRoundTripsWithNilProfile() throws {
        let original = DatabaseConfig(
            sourceDirectory: "/tmp/source",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            profile: nil
        )

        let data = try makeEncoder().encode(original)
        let decoded = try makeDecoder().decode(DatabaseConfig.self, from: data)

        XCTAssertNil(decoded.profile)
        XCTAssertEqual(decoded.sourceDirectory, original.sourceDirectory)
    }

    /// Pre-profile DBs have config.json without a "profile" key (and may
    /// still carry the old "embedder" key from before phase 3e). Those
    /// must decode with `profile == nil` — the command layer distinguishes
    /// pre-profile (chunks > 0) from fresh (chunks == 0) at runtime.
    func testDatabaseConfigDecodesLegacyJSONWithNilProfile() throws {
        let legacyJSON = """
        {
          "createdAt" : "2024-01-01T00:00:00Z",
          "embedder" : { "name" : "nomic-v1.5-768", "dimension" : 768 },
          "sourceDirectory" : "/tmp/legacy"
        }
        """
        let data = Data(legacyJSON.utf8)

        let decoded = try makeDecoder().decode(DatabaseConfig.self, from: data)

        XCTAssertNil(decoded.profile)
        XCTAssertEqual(decoded.sourceDirectory, "/tmp/legacy")
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
}
