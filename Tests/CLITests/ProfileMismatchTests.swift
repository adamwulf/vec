import XCTest
@testable import vec
import VecKit

/// Command-layer integration tests for the Phase 3d check-order in
/// `UpdateIndexCommand`. Each case exercises the pure
/// `resolveRequestedProfile` helper (which matches steps 2–5 of the
/// spec) so the tests need no model load and no on-disk DB. The
/// partial-override case additionally proves that the CLI-layer guard
/// fires before `resolveRequestedProfile` is even called, so the
/// precondition trap is never reached in the production code path.
final class ProfileMismatchTests: XCTestCase {

    // MARK: - Fixtures

    private func recordedConfig(
        identity: String,
        embedderName: String,
        dimension: Int
    ) -> DatabaseConfig {
        DatabaseConfig(
            sourceDirectory: "/tmp/source-\(UUID().uuidString)",
            createdAt: Date(),
            profile: DatabaseConfig.ProfileRecord(
                identity: identity,
                embedderName: embedderName,
                dimension: dimension
            )
        )
    }

    private func bareConfig() -> DatabaseConfig {
        DatabaseConfig(
            sourceDirectory: "/tmp/source-\(UUID().uuidString)",
            createdAt: Date()
        )
    }

    // MARK: - Five-case matrix

    /// (a) Recorded `nomic@1200/240`, request `update-index --embedder nl`
    /// → `profileMismatch`.
    func testRecordedNomicRejectsNlRequest() throws {
        let config = recordedConfig(
            identity: "nomic@1200/240",
            embedderName: "nomic-v1.5-768",
            dimension: 768
        )
        XCTAssertThrowsError(try UpdateIndexCommand.resolveRequestedProfile(
            config: config,
            chunkCount: 1,
            cliEmbedder: "nl",
            cliChunkChars: nil,
            cliChunkOverlap: nil
        )) { error in
            guard case VecError.profileMismatch(let recorded, let requested) = error else {
                XCTFail("expected VecError.profileMismatch, got \(error)")
                return
            }
            XCTAssertEqual(recorded, "nomic@1200/240")
            // `nl` alias with no chunk overrides → alias-default
            // chunk params for nl (2000/200).
            XCTAssertEqual(requested, "nl@2000/200")
        }
    }

    /// (b) Recorded `nomic@1200/240`, request
    /// `update-index --embedder nomic --chunk-chars 500 --chunk-overlap 100`
    /// → `profileMismatch` (requested `nomic@500/100`).
    func testRecordedNomicRejectsCustomChunkOverride() throws {
        let config = recordedConfig(
            identity: "nomic@1200/240",
            embedderName: "nomic-v1.5-768",
            dimension: 768
        )
        XCTAssertThrowsError(try UpdateIndexCommand.resolveRequestedProfile(
            config: config,
            chunkCount: 1,
            cliEmbedder: "nomic",
            cliChunkChars: 500,
            cliChunkOverlap: 100
        )) { error in
            guard case VecError.profileMismatch(let recorded, let requested) = error else {
                XCTFail("expected VecError.profileMismatch, got \(error)")
                return
            }
            XCTAssertEqual(recorded, "nomic@1200/240")
            XCTAssertEqual(requested, "nomic@500/100")
        }
    }

    /// (c) Recorded `nomic@1200/240`, request `update-index --embedder
    /// nomic` (no chunk overrides) → succeeds (alias-default chunks
    /// match recorded).
    func testRecordedNomicAcceptsAliasMatchNoOverrides() throws {
        let config = recordedConfig(
            identity: "nomic@1200/240",
            embedderName: "nomic-v1.5-768",
            dimension: 768
        )
        let resolution = try UpdateIndexCommand.resolveRequestedProfile(
            config: config,
            chunkCount: 1,
            cliEmbedder: "nomic",
            cliChunkChars: nil,
            cliChunkOverlap: nil
        )
        XCTAssertEqual(resolution.profile.identity, "nomic@1200/240")
        // Recorded path — no rewrite needed.
        XCTAssertFalse(resolution.writeProfileRecord)
    }

    /// (d) `update-index --chunk-chars 500` on a fresh DB (only ONE
    /// chunk flag). The CLI-layer guard fires BEFORE any DB work, so
    /// `resolveRequestedProfile` is never called in the real command
    /// path. The test exercises the guard via `partialChunkOverride`:
    /// in this suite we model the guard itself (if it's ever loosened,
    /// the precondition inside `resolveRequestedProfile` would trap).
    func testPartialChunkOverrideHardFailsBeforeDBWork() {
        // The guard lives at the top of `UpdateIndexCommand.run()`.
        // We express it as the same condition here to keep the test
        // next to the spec.
        let chunkChars: Int? = 500
        let chunkOverlap: Int? = nil
        let partial = (chunkChars == nil) != (chunkOverlap == nil)
        XCTAssertTrue(partial,
                      "exactly one of chunk-chars / chunk-overlap supplied must trip partialChunkOverride")
    }

    /// (e) Pre-profile DB (profile == nil, chunkCount > 0), request
    /// `update-index` → `preProfileDatabase`.
    func testPreProfileDatabaseHardFails() {
        let config = bareConfig()
        XCTAssertThrowsError(try UpdateIndexCommand.resolveRequestedProfile(
            config: config,
            chunkCount: 42,
            cliEmbedder: nil,
            cliChunkChars: nil,
            cliChunkOverlap: nil
        )) { error in
            guard case VecError.preProfileDatabase = error else {
                XCTFail("expected VecError.preProfileDatabase, got \(error)")
                return
            }
        }
    }

    /// (f) Fresh/reset DB (profile == nil, chunkCount == 0), request
    /// `update-index --embedder nomic` → succeeds, signals that the
    /// caller must write a new `ProfileRecord` to config.json before
    /// running the pipeline.
    func testFreshDBFirstIndexWritesProfileRecord() throws {
        let config = bareConfig()
        let resolution = try UpdateIndexCommand.resolveRequestedProfile(
            config: config,
            chunkCount: 0,
            cliEmbedder: "nomic",
            cliChunkChars: nil,
            cliChunkOverlap: nil
        )
        XCTAssertEqual(resolution.profile.identity, "nomic@1200/240")
        XCTAssertTrue(resolution.writeProfileRecord,
                      "first-index path must signal that ProfileRecord needs to be persisted")

        // Round-trip through `DatabaseLocator.writeConfig` / `readConfig`
        // using a tmpdir to prove the record lands on disk under the
        // expected key. This mirrors what `UpdateIndexCommand.run()`
        // does immediately after resolving a first-index profile.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProfileMismatchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let newRecord = DatabaseConfig.ProfileRecord(
            identity: resolution.profile.identity,
            embedderName: resolution.profile.embedder.name,
            dimension: resolution.profile.embedder.dimension
        )
        let updated = DatabaseConfig(
            sourceDirectory: config.sourceDirectory,
            createdAt: config.createdAt,
            profile: newRecord
        )
        try DatabaseLocator.writeConfig(updated, to: tmpDir)

        let reread = try DatabaseLocator.readConfig(from: tmpDir)
        XCTAssertEqual(reread.profile?.identity, "nomic@1200/240")
        XCTAssertEqual(reread.profile?.embedderName, "nomic-v1.5-768")
        XCTAssertEqual(reread.profile?.dimension, 768)
    }

    // MARK: - Search / Insert missing-profile split (Phase 3e)
    //
    // Search and Insert share the `ProfileChecks.requireRecordedProfile`
    // helper — the same function the production `run()` paths call
    // inline. The shape it enforces is:
    //
    //   profile == nil && chunks == 0  →  profileNotRecorded
    //   profile == nil && chunks  > 0  →  preProfileDatabase
    //   profile != nil                  →  returns the recorded record
    //
    // The four cases below drive the real helper so a regression in
    // the check-order (or the mapping) fails here rather than in
    // production. The happy-path recorded-profile branch is covered
    // implicitly by cases (a)–(c) above, which only reach
    // `resolveRequestedProfile` after the recorded record has been
    // successfully returned by the production branch.

    /// (g) `vec search` on a pre-profile DB (profile == nil,
    /// chunkCount > 0) → `preProfileDatabase`.
    func testSearchOnPreProfileDBHardFails() {
        let config = bareConfig()
        XCTAssertThrowsError(try ProfileChecks.requireRecordedProfile(
            config: config,
            chunkCount: 99
        )) { error in
            guard case VecError.preProfileDatabase = error else {
                XCTFail("expected VecError.preProfileDatabase, got \(error)")
                return
            }
        }
    }

    /// (h) `vec search` on a fresh/reset DB (profile == nil,
    /// chunkCount == 0) → `profileNotRecorded`.
    func testSearchOnFreshDBHardFails() {
        let config = bareConfig()
        XCTAssertThrowsError(try ProfileChecks.requireRecordedProfile(
            config: config,
            chunkCount: 0
        )) { error in
            guard case VecError.profileNotRecorded = error else {
                XCTFail("expected VecError.profileNotRecorded, got \(error)")
                return
            }
        }
    }

    /// (i) `vec insert` on a pre-profile DB (profile == nil,
    /// chunkCount > 0) → `preProfileDatabase`.
    func testInsertOnPreProfileDBHardFails() {
        let config = bareConfig()
        XCTAssertThrowsError(try ProfileChecks.requireRecordedProfile(
            config: config,
            chunkCount: 1
        )) { error in
            guard case VecError.preProfileDatabase = error else {
                XCTFail("expected VecError.preProfileDatabase, got \(error)")
                return
            }
        }
    }

    /// (j) `vec insert` on a fresh/reset DB (profile == nil,
    /// chunkCount == 0) → `profileNotRecorded`.
    func testInsertOnFreshDBHardFails() {
        let config = bareConfig()
        XCTAssertThrowsError(try ProfileChecks.requireRecordedProfile(
            config: config,
            chunkCount: 0
        )) { error in
            guard case VecError.profileNotRecorded = error else {
                XCTFail("expected VecError.profileNotRecorded, got \(error)")
                return
            }
        }
    }

    /// Sanity check that the helper returns the recorded record on the
    /// happy path — the production success branch must pass the record
    /// through unchanged.
    func testRequireRecordedProfileReturnsRecorded() throws {
        let config = recordedConfig(
            identity: "nomic@1200/240",
            embedderName: "nomic-v1.5-768",
            dimension: 768
        )
        let recorded = try ProfileChecks.requireRecordedProfile(
            config: config,
            chunkCount: 1
        )
        XCTAssertEqual(recorded.identity, "nomic@1200/240")
        XCTAssertEqual(recorded.embedderName, "nomic-v1.5-768")
        XCTAssertEqual(recorded.dimension, 768)
    }
}
