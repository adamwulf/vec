import XCTest
@testable import VecKit

/// Fixture-based end-to-end coverage for the
/// `Fixtures/trademark-transcript.txt` file. The fixture is a real
/// transcript captured from a user's markdown-memory corpus; during
/// the pluggable-embedders retrieval-rubric sanity sweep it surfaced
/// as a concrete file that both embedders need to round-trip cleanly.
///
/// The tests loop over `IndexingProfileFactory.builtIns` so adding a
/// new built-in automatically extends coverage — each entry's
/// `canonicalDimension` is the truth source for the vector width we
/// expect from every chunk.
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

    /// Every built-in profile must produce non-empty chunks from the
    /// fixture — empty chunk lists would route to `.skippedUnreadable`
    /// in the pipeline.
    func testExtractorProducesNonEmptyChunksForEveryBuiltIn() throws {
        let file = try fixtureFileInfo()
        for builtIn in IndexingProfileFactory.builtIns {
            let profile = try IndexingProfileFactory.make(alias: builtIn.alias)
            let extractor = TextExtractor(splitter: profile.splitter)
            let result = try extractor.extract(from: file)

            XCTAssertGreaterThan(result.chunks.count, 0,
                "[\(builtIn.alias)] Extractor must produce at least one chunk")
            for (i, chunk) in result.chunks.enumerated() {
                XCTAssertFalse(chunk.text.isEmpty,
                    "[\(builtIn.alias)] Chunk \(i) should not be empty")
            }
        }
    }

    /// Every built-in profile must embed every chunk from the fixture
    /// at the profile's canonical dimension.
    func testEveryBuiltInEmbedsEveryChunkToCanonicalDimension() async throws {
        let file = try fixtureFileInfo()
        for builtIn in IndexingProfileFactory.builtIns {
            let profile = try IndexingProfileFactory.make(alias: builtIn.alias)
            let extractor = TextExtractor(splitter: profile.splitter)
            let chunks = try extractor.extract(from: file).chunks

            for (i, chunk) in chunks.enumerated() {
                let vec = try await profile.embedder.embedDocument(chunk.text)
                XCTAssertEqual(vec.count, builtIn.canonicalDimension,
                    "[\(builtIn.alias)] Chunk \(i) should embed to \(builtIn.canonicalDimension)-dim, got \(vec.count)")
            }
        }
    }
}
