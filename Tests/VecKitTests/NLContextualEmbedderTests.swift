import XCTest
@testable import VecKit

/// Identity tests for `NLContextualEmbedder`. These tests do not load the
/// model — they only assert the `nonisolated` protocol-surface properties.
final class NLContextualEmbedderTests: XCTestCase {

    func testName() {
        let embedder = NLContextualEmbedder()
        XCTAssertEqual(embedder.name, "nl-contextual-en-512")
    }

    func testDimension() {
        let embedder = NLContextualEmbedder()
        XCTAssertEqual(embedder.dimension, 512)
    }
}
