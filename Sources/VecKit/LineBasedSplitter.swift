import Foundation

/// The original line-count-based splitter.
///
/// Produces overlapping fixed-line chunks and prefers to end a chunk on a
/// Markdown heading (`#…`) when one appears near the target boundary.
/// Kept alongside newer splitters so both can be benchmarked on the same
/// corpus.
public struct LineBasedSplitter: TextSplitter {
    public static let defaultChunkSize = 30
    public static let defaultOverlapSize = 8

    public let chunkSize: Int
    public let overlapSize: Int

    public init(chunkSize: Int = LineBasedSplitter.defaultChunkSize,
                overlapSize: Int = LineBasedSplitter.defaultOverlapSize) {
        self.chunkSize = chunkSize
        self.overlapSize = overlapSize
    }

    public func split(_ content: String) -> [TextChunk] {
        let lines = content.components(separatedBy: .newlines)

        guard lines.count > chunkSize else { return [] }

        var chunks: [TextChunk] = []
        var start = 0

        while start < lines.count {
            var end = min(start + chunkSize, lines.count)

            if end < lines.count {
                let searchStart = max(start + chunkSize - 10, start)
                for i in stride(from: end, through: searchStart, by: -1) {
                    if i < lines.count && lines[i].hasPrefix("#") {
                        end = i
                        break
                    }
                }
            }

            let chunkLines = Array(lines[start..<end])
            let text = chunkLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !text.isEmpty {
                chunks.append(TextChunk(
                    text: text,
                    type: .chunk,
                    lineStart: start + 1,
                    lineEnd: end
                ))
            }

            let advance = max(chunkSize - overlapSize, 1)
            start += advance
        }

        return chunks
    }
}
