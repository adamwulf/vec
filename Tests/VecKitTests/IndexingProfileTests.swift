import XCTest
@testable import VecKit

/// Unit tests for `IndexingProfile` — struct construction and the
/// strict identity parser. No model load; uses stub embedder + stub
/// splitter so the suite has no factory dependency.
final class IndexingProfileTests: XCTestCase {

    // MARK: - Stubs

    private struct StubEmbedder: Embedder {
        let name: String = "stub-embedder"
        let dimension: Int = 4
        func embedDocument(_ text: String) async throws -> [Float] { [0, 0, 0, 0] }
        func embedQuery(_ text: String) async throws -> [Float] { [0, 0, 0, 0] }
    }

    private struct StubSplitter: TextSplitter {
        func split(_ text: String) -> [TextChunk] { [] }
    }

    private func makeProfile(
        identity: String = "stub@1200/240",
        chunkSize: Int = 1200,
        chunkOverlap: Int = 240,
        isBuiltIn: Bool = true
    ) -> IndexingProfile {
        IndexingProfile(
            identity: identity,
            embedder: StubEmbedder(),
            splitter: StubSplitter(),
            chunkSize: chunkSize,
            chunkOverlap: chunkOverlap,
            isBuiltIn: isBuiltIn
        )
    }

    // MARK: - Struct construction

    func testConstructsWithFullOverrideFields() {
        let profile = makeProfile(
            identity: "stub@500/100",
            chunkSize: 500,
            chunkOverlap: 100,
            isBuiltIn: false
        )
        XCTAssertEqual(profile.identity, "stub@500/100")
        XCTAssertEqual(profile.chunkSize, 500)
        XCTAssertEqual(profile.chunkOverlap, 100)
        XCTAssertFalse(profile.isBuiltIn)
        XCTAssertEqual(profile.embedder.name, "stub-embedder")
        XCTAssertEqual(profile.embedder.dimension, 4)
    }

    func testConstructsWithBuiltInFlag() {
        let profile = makeProfile(
            identity: "stub@1200/240",
            chunkSize: 1200,
            chunkOverlap: 240,
            isBuiltIn: true
        )
        XCTAssertTrue(profile.isBuiltIn)
    }

    func testConstructsWithZeroOverlap() {
        // Overlap of 0 is explicitly valid — the precondition is
        // `chunkOverlap >= 0 && < chunkSize`.
        let profile = makeProfile(
            identity: "stub@10/0",
            chunkSize: 10,
            chunkOverlap: 0,
            isBuiltIn: false
        )
        XCTAssertEqual(profile.chunkOverlap, 0)
        XCTAssertEqual(profile.chunkSize, 10)
    }

    func testConstructsWithOverlapJustUnderChunkSize() {
        // Boundary: overlap == chunkSize - 1 is allowed.
        let profile = makeProfile(
            identity: "stub@100/99",
            chunkSize: 100,
            chunkOverlap: 99,
            isBuiltIn: false
        )
        XCTAssertEqual(profile.chunkSize, 100)
        XCTAssertEqual(profile.chunkOverlap, 99)
    }

    // MARK: - parseIdentity — positive cases

    func testParseIdentityBuiltInAliasDefault() throws {
        let parsed = try IndexingProfile.parseIdentity("nomic@1200/240")
        XCTAssertEqual(parsed.alias, "nomic")
        XCTAssertEqual(parsed.chunkSize, 1200)
        XCTAssertEqual(parsed.chunkOverlap, 240)
    }

    func testParseIdentityCustomOverride() throws {
        let parsed = try IndexingProfile.parseIdentity("nomic@500/100")
        XCTAssertEqual(parsed.alias, "nomic")
        XCTAssertEqual(parsed.chunkSize, 500)
        XCTAssertEqual(parsed.chunkOverlap, 100)
    }

    func testParseIdentityAllowsZeroOverlap() throws {
        // Grammar: overlap is `[0-9]+`, so "0" is valid.
        let parsed = try IndexingProfile.parseIdentity("nl@2000/0")
        XCTAssertEqual(parsed.alias, "nl")
        XCTAssertEqual(parsed.chunkSize, 2000)
        XCTAssertEqual(parsed.chunkOverlap, 0)
    }

    func testParseIdentityAllowsHyphenInAlias() throws {
        // Grammar: alias is `[a-z0-9-]+`, so hyphens are valid.
        let parsed = try IndexingProfile.parseIdentity("my-alias@100/10")
        XCTAssertEqual(parsed.alias, "my-alias")
        XCTAssertEqual(parsed.chunkSize, 100)
        XCTAssertEqual(parsed.chunkOverlap, 10)
    }

    // MARK: - parseIdentity — strict negative matrix

    func testParseIdentityRejectsGarbled() {
        assertMalformed("garbled")
    }

    func testParseIdentityRejectsBareAlias() {
        assertMalformed("nomic")
    }

    func testParseIdentityRejectsMissingOverlap() {
        assertMalformed("nomic@1200")
    }

    func testParseIdentityRejectsEmptyOverlap() {
        assertMalformed("nomic@1200/")
    }

    func testParseIdentityRejectsMissingAlias() {
        assertMalformed("@1200/240")
    }

    func testParseIdentityRejectsNonNumericSizes() {
        assertMalformed("nomic@abc/def")
    }

    func testParseIdentityRejectsLeadingSpace() {
        assertMalformed("nomic@ 1200/240")
    }

    func testParseIdentityRejectsTrailingSpace() {
        assertMalformed("nomic@1200/240 ")
    }

    func testParseIdentityRejectsLeadingZeroSize() {
        assertMalformed("nomic@01200/240")
    }

    func testParseIdentityRejectsUppercaseAlias() {
        assertMalformed("Nomic@1200/240")
    }

    func testParseIdentityRejectsExtraSegment() {
        assertMalformed("nomic@1200/240/5")
    }

    func testParseIdentityRejectsNegativeSize() {
        assertMalformed("nomic@-100/240")
    }

    func testParseIdentityRejectsEmptyString() {
        assertMalformed("")
    }

    func testParseIdentityRejectsLeadingWhitespaceOnWholeString() {
        assertMalformed(" nomic@1200/240")
    }

    // MARK: - IndexingProfileFactory — built-in alias resolution

    func testFactoryResolvesNomicBuiltIn() throws {
        let profile = try IndexingProfileFactory.make(alias: "nomic")
        XCTAssertEqual(profile.identity, "nomic@1200/240")
        XCTAssertEqual(profile.chunkSize, 1200)
        XCTAssertEqual(profile.chunkOverlap, 240)
        XCTAssertTrue(profile.isBuiltIn)
        XCTAssertEqual(profile.embedder.name, "nomic-v1.5-768")
        XCTAssertEqual(profile.embedder.dimension, 768)
    }

    func testFactoryResolvesNLBuiltIn() throws {
        let profile = try IndexingProfileFactory.make(alias: "nl")
        XCTAssertEqual(profile.identity, "nl@2000/200")
        XCTAssertEqual(profile.chunkSize, 2000)
        XCTAssertEqual(profile.chunkOverlap, 200)
        XCTAssertTrue(profile.isBuiltIn)
        XCTAssertEqual(profile.embedder.name, "nl-en-512")
        XCTAssertEqual(profile.embedder.dimension, 512)
    }

    func testFactoryDefaultAliasIsKnown() {
        XCTAssertEqual(IndexingProfileFactory.defaultAlias, "nomic")
        XCTAssertTrue(IndexingProfileFactory.knownAliases.contains(IndexingProfileFactory.defaultAlias))
    }

    func testFactoryBuiltInForAliasLookup() throws {
        let entry = try IndexingProfileFactory.builtIn(forAlias: "nomic")
        XCTAssertEqual(entry.canonicalEmbedderName, "nomic-v1.5-768")
        XCTAssertEqual(entry.canonicalDimension, 768)
        XCTAssertEqual(entry.defaultChunkSize, 1200)
        XCTAssertEqual(entry.defaultChunkOverlap, 240)
    }

    func testFactoryBuiltInForAliasLookup_bgeBase() throws {
        let entry = try IndexingProfileFactory.builtIn(forAlias: "bge-base")
        XCTAssertEqual(entry.canonicalEmbedderName, "bge-base-en-v1.5")
        XCTAssertEqual(entry.canonicalDimension, 768)
        XCTAssertEqual(entry.defaultChunkSize, 1200)
        XCTAssertEqual(entry.defaultChunkOverlap, 240)
    }

    func testFactoryResolveBGEBaseDefaultIdentity() throws {
        let profile = try IndexingProfileFactory.resolve(identity: "bge-base@1200/240")
        XCTAssertEqual(profile.identity, "bge-base@1200/240")
        XCTAssertEqual(profile.chunkSize, 1200)
        XCTAssertEqual(profile.chunkOverlap, 240)
        XCTAssertTrue(profile.isBuiltIn)
        XCTAssertEqual(profile.embedder.name, "bge-base-en-v1.5")
        XCTAssertEqual(profile.embedder.dimension, 768)
    }

    // MARK: - IndexingProfileFactory — full override composition

    func testFactoryFullOverrideProducesCustomProfile() throws {
        let profile = try IndexingProfileFactory.make(
            alias: "nomic",
            chunkSize: 500,
            chunkOverlap: 100
        )
        XCTAssertEqual(profile.identity, "nomic@500/100")
        XCTAssertEqual(profile.chunkSize, 500)
        XCTAssertEqual(profile.chunkOverlap, 100)
        XCTAssertFalse(profile.isBuiltIn)
        // The splitter should carry the overridden chunk params.
        let splitter = profile.splitter as? RecursiveCharacterSplitter
        XCTAssertEqual(splitter?.chunkSize, 500)
        XCTAssertEqual(splitter?.chunkOverlap, 100)
    }

    // MARK: - IndexingProfileFactory — resolve(identity:) round-trip

    func testFactoryResolveAliasDefaultIdentityIsBuiltIn() throws {
        // Alias-default identity round-trips with isBuiltIn == true
        // even though `resolve` calls `make` with explicit chunk params.
        // This is the key invariant — isBuiltIn is computed from
        // effective chunk params, not from caller arity.
        let profile = try IndexingProfileFactory.resolve(identity: "nomic@1200/240")
        XCTAssertEqual(profile.identity, "nomic@1200/240")
        XCTAssertEqual(profile.chunkSize, 1200)
        XCTAssertEqual(profile.chunkOverlap, 240)
        XCTAssertTrue(profile.isBuiltIn)
        XCTAssertEqual(profile.embedder.name, "nomic-v1.5-768")
    }

    func testFactoryResolveCustomIdentityIsNotBuiltIn() throws {
        let profile = try IndexingProfileFactory.resolve(identity: "nomic@500/100")
        XCTAssertEqual(profile.identity, "nomic@500/100")
        XCTAssertEqual(profile.chunkSize, 500)
        XCTAssertEqual(profile.chunkOverlap, 100)
        XCTAssertFalse(profile.isBuiltIn)
    }

    func testFactoryResolveUnknownAliasThrowsUnknownProfile() {
        // Grammar-valid identity with an unregistered alias.
        XCTAssertThrowsError(try IndexingProfileFactory.resolve(identity: "bogus@1200/240")) { error in
            guard case VecError.unknownProfile(let reported) = error else {
                XCTFail("Expected VecError.unknownProfile, got \(error)")
                return
            }
            XCTAssertEqual(reported, "bogus")
        }
    }

    func testFactoryResolveMalformedIdentityThrowsMalformed() {
        // `resolve` delegates to `parseIdentity` — the strict parser
        // is shared, so malformed input still throws the existing
        // `malformedProfileIdentity` error.
        XCTAssertThrowsError(try IndexingProfileFactory.resolve(identity: "garbled")) { error in
            guard case VecError.malformedProfileIdentity = error else {
                XCTFail("Expected VecError.malformedProfileIdentity, got \(error)")
                return
            }
        }
    }

    // MARK: - IndexingProfileFactory — error paths

    func testFactoryMakeUnknownAliasThrowsUnknownProfile() {
        XCTAssertThrowsError(try IndexingProfileFactory.make(alias: "bogus")) { error in
            guard case VecError.unknownProfile(let reported) = error else {
                XCTFail("Expected VecError.unknownProfile, got \(error)")
                return
            }
            XCTAssertEqual(reported, "bogus")
        }
    }

    func testFactoryMakeBuiltInForAliasUnknownAliasThrowsUnknownProfile() {
        XCTAssertThrowsError(try IndexingProfileFactory.builtIn(forAlias: "bogus")) { error in
            guard case VecError.unknownProfile(let reported) = error else {
                XCTFail("Expected VecError.unknownProfile, got \(error)")
                return
            }
            XCTAssertEqual(reported, "bogus")
        }
    }

    func testFactoryMakeOverlapEqualToSizeThrowsInvalidChunkParams() {
        // overlap == size violates `overlap < size`.
        XCTAssertThrowsError(
            try IndexingProfileFactory.make(alias: "nomic", chunkSize: 100, chunkOverlap: 100)
        ) { error in
            guard case VecError.invalidChunkParams = error else {
                XCTFail("Expected VecError.invalidChunkParams, got \(error)")
                return
            }
        }
    }

    func testFactoryMakeNegativeOverlapThrowsInvalidChunkParams() {
        XCTAssertThrowsError(
            try IndexingProfileFactory.make(alias: "nomic", chunkSize: 100, chunkOverlap: -1)
        ) { error in
            guard case VecError.invalidChunkParams = error else {
                XCTFail("Expected VecError.invalidChunkParams, got \(error)")
                return
            }
        }
    }

    func testFactoryMakeZeroOverlapSucceeds() throws {
        // Overlap of 0 is explicitly valid — the validator accepts
        // `overlap >= 0`.
        let profile = try IndexingProfileFactory.make(
            alias: "nomic",
            chunkSize: 100,
            chunkOverlap: 0
        )
        XCTAssertEqual(profile.chunkSize, 100)
        XCTAssertEqual(profile.chunkOverlap, 0)
        XCTAssertFalse(profile.isBuiltIn)
    }

    // MARK: - Partial-override precondition
    //
    // `make(alias:chunkSize:chunkOverlap:)` guards against partial
    // overrides (one nil, the other not) with a precondition — this
    // is a programmer-error trap, not a runtime-recoverable error.
    // Testing a `precondition` failure at runtime requires either a
    // process-spawning test harness or an unavailable mechanism in
    // XCTest. We document the contract by signature inspection
    // instead: the CLI layer is responsible for translating a
    // partial-override invocation into `VecError.partialChunkOverride`
    // *before* calling `make` (wired in Phase 3d). The precondition
    // string is `"IndexingProfileFactory.make requires both chunk
    // overrides or neither"`.

    // MARK: - Helpers

    private func assertMalformed(_ identity: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try IndexingProfile.parseIdentity(identity), file: file, line: line) { error in
            guard case VecError.malformedProfileIdentity(let reported) = error else {
                XCTFail("Expected VecError.malformedProfileIdentity, got \(error)", file: file, line: line)
                return
            }
            XCTAssertEqual(reported, identity, file: file, line: line)
        }
    }
}
