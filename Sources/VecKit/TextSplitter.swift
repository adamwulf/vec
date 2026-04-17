import Foundation

/// Splits a block of text into embedding-sized chunks.
///
/// Conformers own their own sizing rules and separator logic. The returned
/// chunks should have `type == .chunk` and 1-based `lineStart`/`lineEnd`
/// populated where meaningful.
///
/// Multiple implementations exist so that chunking strategies can be
/// compared against the same corpus without changing call sites.
public protocol TextSplitter: Sendable {
    func split(_ text: String) -> [TextChunk]
}
