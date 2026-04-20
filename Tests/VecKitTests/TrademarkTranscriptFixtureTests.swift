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

    /// Single-vs-batched parity: `embedDocuments([x, pad])[0]` must
    /// produce the same vector as `embedDocument(x)` to within fp16
    /// numerical noise. Locks in the property the E4 batched-embedding
    /// work depends on — if attention masking, pad-token id, or
    /// post-processing ever drifts between the two paths, this test
    /// fails fast.
    func testBatchedEmbedMatchesSingleEmbedForAllBuiltIns() async throws {
        let file = try fixtureFileInfo()
        for builtIn in IndexingProfileFactory.builtIns {
            let profile = try IndexingProfileFactory.make(alias: builtIn.alias)
            let extractor = TextExtractor(splitter: profile.splitter)
            let chunks = try extractor.extract(from: file).chunks
            guard let first = chunks.first else {
                XCTFail("[\(builtIn.alias)] extractor returned no chunks")
                continue
            }

            let padFiller = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. " +
                "Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. " +
                "Padding filler used to exercise the batch path's attention mask."

            let single = try await profile.embedder.embedDocument(first.text)
            let batched = try await profile.embedder.embedDocuments([first.text, padFiller])
            XCTAssertEqual(batched.count, 2,
                "[\(builtIn.alias)] embedDocuments should return one vector per input")
            XCTAssertEqual(single.count, batched[0].count,
                "[\(builtIn.alias)] single and batched vectors must have equal dimension")

            let cos = cosineSimilarity(single, batched[0])
            XCTAssertGreaterThanOrEqual(cos, 0.9999,
                "[\(builtIn.alias)] cosine(single, batched[0]) = \(cos); " +
                "expected ≥ 0.9999. Padding or attention-mask drift between paths.")
        }
    }

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        precondition(a.count == b.count, "vectors must share dimension")
        var dot = 0.0
        var na = 0.0
        var nb = 0.0
        for i in 0..<a.count {
            let ai = Double(a[i])
            let bi = Double(b[i])
            dot += ai * bi
            na += ai * ai
            nb += bi * bi
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }
}
