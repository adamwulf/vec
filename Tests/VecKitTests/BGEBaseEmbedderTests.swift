import XCTest
@testable import VecKit

/// Minimal identity checks for `BGEBaseEmbedder`. An end-to-end embed
/// would require downloading the ~220 MB BGE-base safetensors from
/// HuggingFace, so that is deliberately left out of the default suite
/// — Phase D exercises it against the real corpus.
final class BGEBaseEmbedderTests: XCTestCase {

    func testNameMatchesCanonicalIdentifier() {
        let embedder = BGEBaseEmbedder()
        XCTAssertEqual(embedder.name, "bge-base-en-v1.5")
    }

    func testDimensionIs768() {
        let embedder = BGEBaseEmbedder()
        XCTAssertEqual(embedder.dimension, 768)
    }
}
