import XCTest
@testable import VecKit

/// Fixture-based end-to-end coverage for the
/// `Fixtures/trademark-transcript.txt` file. The fixture is a real
/// transcript captured from a user's markdown-memory corpus; during
/// the pluggable-embedders bean-test sanity sweep it surfaced as a
/// concrete file that both embedders need to round-trip cleanly.
///
/// The tests confirm that `TextExtractor` splits the transcript into
/// non-empty chunks (so it never falls into the `.skippedUnreadable`
/// path in the pipeline) and that every chunk produces a full-length
/// vector from each shipping embedder.
final class TrademarkTranscriptFixtureTests: XCTestCase {

    private func fixtureFileInfo() throws -> FileInfo {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "trademark-transcript",
                withExtension: "txt",
                subdirectory: "Fixtures"
            ),
            "trademark-transcript.txt fixture missing from bundle"
        )
        let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? Date()
        return FileInfo(
            relativePath: "trademark-transcript.txt",
            url: url,
            modificationDate: modDate,
            fileExtension: "txt"
        )
    }

    func testExtractorProducesNonEmptyChunks() throws {
        let file = try fixtureFileInfo()
        let extractor = TextExtractor()
        let result = try extractor.extract(from: file)

        XCTAssertGreaterThan(result.chunks.count, 0,
            "Extractor must produce at least one chunk — empty would route to .skippedUnreadable")
        for (i, chunk) in result.chunks.enumerated() {
            XCTAssertFalse(chunk.text.isEmpty, "Chunk \(i) should not be empty")
        }
    }

    func testNomicEmbedsEveryChunkTo768Dims() async throws {
        let file = try fixtureFileInfo()
        let extractor = TextExtractor()
        let chunks = try extractor.extract(from: file).chunks
        let embedder = NomicEmbedder()

        for (i, chunk) in chunks.enumerated() {
            let vec = try await embedder.embedDocument(chunk.text)
            XCTAssertEqual(vec.count, 768,
                "Chunk \(i) should embed to 768-dim with nomic, got \(vec.count)")
        }
    }

    func testNLEmbedsEveryChunkTo512Dims() async throws {
        let file = try fixtureFileInfo()
        let extractor = TextExtractor()
        let chunks = try extractor.extract(from: file).chunks
        let embedder = NLEmbedder()

        for (i, chunk) in chunks.enumerated() {
            let vec = try await embedder.embedDocument(chunk.text)
            XCTAssertEqual(vec.count, 512,
                "Chunk \(i) should embed to 512-dim with NL, got \(vec.count)")
        }
    }
}
