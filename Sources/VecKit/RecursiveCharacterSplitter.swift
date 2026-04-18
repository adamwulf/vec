import Foundation

/// Port of LangChain's `RecursiveCharacterTextSplitter`.
///
/// Walks the separator list in priority order (`\n\n`, `\n`, `. `, ` `),
/// splits on the first separator that appears in the text, and recurses
/// into any piece still larger than `chunkSize`. A greedy merge step
/// recombines adjacent small pieces back up to `chunkSize`, producing
/// `chunkOverlap` characters of overlap between consecutive chunks.
///
/// Notable deviations from the LangChain default:
///   - No empty-string fallback separator. If a single atomic piece
///     (typically a full line with no internal whitespace — common in
///     VTT cues and log lines) exceeds `chunkSize`, it is emitted whole
///     rather than sliced mid-word. This preserves the "at least one
///     full line" invariant for non-prose inputs.
///   - Separator list includes `". "` between `"\n"` and `" "` so prose
///     without paragraph breaks still splits on sentence boundaries.
public struct RecursiveCharacterSplitter: TextSplitter {
    public static let defaultChunkSize = 1200
    public static let defaultChunkOverlap = 240
    public static let defaultSeparators: [String] = ["\n\n", "\n", ". ", " "]

    public let chunkSize: Int
    public let chunkOverlap: Int
    public let separators: [String]
    public let keepSeparator: Bool

    public init(chunkSize: Int = RecursiveCharacterSplitter.defaultChunkSize,
                chunkOverlap: Int = RecursiveCharacterSplitter.defaultChunkOverlap,
                separators: [String] = RecursiveCharacterSplitter.defaultSeparators,
                keepSeparator: Bool = true) {
        precondition(chunkSize > 0, "chunkSize must be positive")
        precondition(chunkOverlap >= 0 && chunkOverlap < chunkSize,
                     "chunkOverlap must be in [0, chunkSize)")
        self.chunkSize = chunkSize
        self.chunkOverlap = chunkOverlap
        self.separators = separators
        self.keepSeparator = keepSeparator
    }

    public func split(_ text: String) -> [TextChunk] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // If the whole document fits in a single chunk, the caller's
        // whole-document embedding already covers it — no need to emit a
        // duplicate `.chunk`. Matches the pre-existing line-splitter behavior.
        guard trimmed.count > chunkSize else { return [] }

        let pieces = splitRecursive(text, separators: separators)
        guard !pieces.isEmpty else { return [] }

        var index = LineIndex(text: text)
        return pieces.map { piece in
            let (lineStart, lineEnd) = index.lineRange(of: piece)
            return TextChunk(
                text: piece,
                type: .chunk,
                lineStart: lineStart,
                lineEnd: lineEnd
            )
        }
    }

    // MARK: - Recursive split (port of LangChain `_split_text`)

    private func splitRecursive(_ text: String, separators: [String]) -> [String] {
        var final: [String] = []

        // Pick the first separator that actually appears in the text;
        // fall back to the last one if none do.
        var chosen = separators.last ?? ""
        var remaining: [String] = []
        for (i, s) in separators.enumerated() {
            if s.isEmpty { chosen = s; break }
            if text.contains(s) {
                chosen = s
                remaining = Array(separators[(i + 1)...])
                break
            }
        }

        let splits = splitWithSeparator(text, separator: chosen, keep: keepSeparator)

        var good: [String] = []
        let mergeSeparator = keepSeparator ? "" : chosen
        for piece in splits {
            if piece.count < chunkSize {
                good.append(piece)
            } else {
                if !good.isEmpty {
                    final.append(contentsOf: merge(good, separator: mergeSeparator))
                    good.removeAll(keepingCapacity: true)
                }
                if remaining.isEmpty {
                    // No more separators to try — emit oversize piece whole.
                    final.append(piece)
                } else {
                    final.append(contentsOf: splitRecursive(piece, separators: remaining))
                }
            }
        }
        if !good.isEmpty {
            final.append(contentsOf: merge(good, separator: mergeSeparator))
        }
        return final
    }

    // MARK: - Split with optional separator retention (port of `_split_text_with_regex`)

    /// Splits `text` on `separator`. When `keep == true`, each separator
    /// occurrence is prepended to the following piece (LangChain's
    /// `keep_separator="start"` behavior) so paragraph/sentence breaks
    /// remain visible to the merge step.
    private func splitWithSeparator(_ text: String, separator: String, keep: Bool) -> [String] {
        guard !separator.isEmpty else {
            return text.map { String($0) }.filter { !$0.isEmpty }
        }

        let components = text.components(separatedBy: separator)
        if !keep {
            return components.filter { !$0.isEmpty }
        }

        var result: [String] = []
        for (i, piece) in components.enumerated() {
            if i == 0 {
                if !piece.isEmpty { result.append(piece) }
            } else {
                result.append(separator + piece)
            }
        }
        return result.filter { !$0.isEmpty }
    }

    // MARK: - Greedy merge (port of `_merge_splits`)

    /// Greedily combines small pieces into chunks up to `chunkSize`,
    /// keeping a tail of length `chunkOverlap` for the next chunk.
    private func merge(_ splits: [String], separator: String) -> [String] {
        let separatorLen = separator.count

        var docs: [String] = []
        var current: [String] = []
        var total = 0

        for piece in splits {
            let pieceLen = piece.count
            let joinCost = current.isEmpty ? 0 : separatorLen

            if total + pieceLen + joinCost > chunkSize {
                if !current.isEmpty {
                    if let joined = joinDocs(current, separator: separator) {
                        docs.append(joined)
                    }
                    // Pop from the front until the buffer is small enough
                    // to append the next piece without exceeding chunkSize,
                    // while still honoring chunkOverlap.
                    while total > chunkOverlap ||
                          (total + pieceLen + (current.count > 1 ? separatorLen : 0) > chunkSize && total > 0) {
                        guard let first = current.first else { break }
                        total -= first.count + (current.count > 1 ? separatorLen : 0)
                        current.removeFirst()
                    }
                }
            }
            current.append(piece)
            total += pieceLen + (current.count > 1 ? separatorLen : 0)
        }
        if let joined = joinDocs(current, separator: separator) {
            docs.append(joined)
        }
        return docs
    }

    private func joinDocs(_ docs: [String], separator: String) -> String? {
        let text = docs.joined(separator: separator)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

// MARK: - Line-number recovery

/// Recovers 1-based line numbers for chunks after the splitter has already
/// produced them. Keeping this separate from the split logic lets the port
/// stay faithful to LangChain's algorithm, which is character-based only.
private struct LineIndex {
    private let text: String
    private var lastSearchIndex: String.Index

    init(text: String) {
        self.text = text
        self.lastSearchIndex = text.startIndex
    }

    mutating func lineRange(of chunk: String) -> (Int, Int) {
        guard let range = text.range(of: chunk, range: lastSearchIndex..<text.endIndex)
                ?? text.range(of: chunk) else {
            return (1, 1)
        }
        let startLine = lineNumber(at: range.lowerBound)
        let endLine = lineNumber(at: range.upperBound)
        lastSearchIndex = range.upperBound
        return (startLine, max(startLine, endLine))
    }

    private func lineNumber(at index: String.Index) -> Int {
        let prefix = text[text.startIndex..<index]
        return prefix.reduce(1) { count, ch in ch == "\n" ? count + 1 : count }
    }
}
