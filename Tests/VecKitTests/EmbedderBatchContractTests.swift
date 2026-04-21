import XCTest
@testable import VecKit

/// Pin the protocol-level batch contract: `embedDocuments([])` must
/// return `[]` without throwing or hitting the model. Indexing flushes
/// at end-of-file routinely produce an empty pending-bucket; the
/// pipeline's batch-spawner does its own zero-check, but the protocol
/// shape itself is what other call sites should be able to rely on.
final class EmbedderBatchContractTests: XCTestCase {

    /// A trivial Embedder that asserts if its body methods get called.
    /// Keeps the empty-input test independent of any model load.
    private actor SentinelEmbedder: Embedder {
        nonisolated let name = "sentinel"
        nonisolated let dimension = 4

        func embedDocument(_ text: String) async throws -> [Float] {
            XCTFail("embedDocument should not be called for empty-input contract")
            return []
        }
        func embedQuery(_ text: String) async throws -> [Float] {
            XCTFail("embedQuery should not be called for empty-input contract")
            return []
        }
        // Inherits the default protocol extension implementation of
        // embedDocuments. That is exactly the path under test.
    }

    func testDefaultEmbedDocumentsExtensionReturnsEmptyForEmptyInput() async throws {
        let e: any Embedder = SentinelEmbedder()
        let out = try await e.embedDocuments([])
        XCTAssertEqual(out.count, 0,
            "embedDocuments([]) must return [] without invoking the model")
    }

    /// Same contract for every built-in. They each provide their own
    /// `embedDocuments` override, so this catches per-implementer
    /// regressions (e.g. a `precondition(!texts.isEmpty)` that would
    /// crash an end-of-file empty flush).
    func testEveryBuiltInReturnsEmptyForEmptyInput() async throws {
        for builtIn in IndexingProfileFactory.builtIns {
            let profile = try IndexingProfileFactory.make(alias: builtIn.alias)
            let out = try await profile.embedder.embedDocuments([])
            XCTAssertEqual(out.count, 0,
                "[\(builtIn.alias)] embedDocuments([]) must return [], got \(out.count)")
        }
    }
}
