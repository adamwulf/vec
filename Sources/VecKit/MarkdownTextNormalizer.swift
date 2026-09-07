import Foundation
import Markdown

/// Normalizes Markdown into plain, embedding-friendly text while keeping the
/// document's newline layout byte-for-byte stable.
///
/// The single goal is to strip Markdown link and image *destinations* (the
/// `(https://…)` URL, the reference key, the optional title) while keeping the
/// visible label / alt text. Everything else — headings, lists, paragraphs,
/// code (inline, fenced, indented), raw HTML, bare URLs, YAML frontmatter —
/// passes through unchanged.
///
/// ## Why source-range edits instead of AST rendering
///
/// A downstream splitter reports chunk locations as 1-based source line
/// numbers. That mapping is only valid if `normalize` preserves the original
/// newline count *and* ordering: output line *N* must still describe input
/// line *N*. Re-emitting the parsed AST (`MarkupFormatter`) reflows text and
/// collapses blank lines, which would shift every later line. Instead this
/// type parses only to discover where links and images live, then performs
/// minimal deletions on the *original* bytes:
///
/// - The syntactic opener (`[`, `![`, and any line break before the label) and
///   the closer (`](destination "title")`, `][ref]`, `]`) are removed.
/// - The label / alt bytes in between are left untouched, so nested images
///   inside a link label are handled by the same pass and inner code, escapes,
///   and Unicode survive verbatim.
/// - Any line terminators that fall inside a removed span are re-emitted in
///   place, so a link whose destination wraps across lines keeps its newlines.
///
/// Because the parser never produces link or image nodes inside code spans,
/// code blocks, or raw HTML, those regions are inherently preserved — no
/// special-casing is required.
///
/// ## Frontmatter
///
/// A leading, delimited YAML frontmatter block (`---` … `---`/`...`) is split
/// off and copied through verbatim before parsing. This both preserves its
/// exact bytes and prevents a reference definition or link-like string inside
/// the frontmatter from resolving or rewriting links in the body. Metadata is
/// not interpreted (deferred). Detection is conservative — see
/// `frontmatterBodyStart`.
///
/// ## Known limitations
///
/// - Reference link *definitions* in the body (e.g. `[id]: https://…`) are
///   left verbatim, so their URL remains. `swift-markdown` consumes
///   definitions during parsing and does not expose them as editable nodes,
///   and deleting a whole definition line would risk the newline contract.
///   Reference link *usages* are still resolved to their label.
/// - Emphasis markers inside a kept label (e.g. `**bold**`) are retained; the
///   scope is destinations only, and this drops no words.
///
/// ## Coordinate system
///
/// `swift-markdown` reports `SourceLocation.column` as a 1-based count of
/// UTF-8 *bytes* from the start of the line. All work therefore happens on the
/// UTF-8 byte buffer, which also keeps multi-byte characters that appear
/// before a link correctly aligned.
public enum MarkdownTextNormalizer {

    /// Returns `source` with Markdown link/image destinations removed and the
    /// visible label/alt text retained. The result has exactly the same line
    /// terminators, in the same order, as the input.
    public static func normalize(_ source: String) -> String {
        // Nothing to parse, and no allocation worth doing.
        guard !source.isEmpty else { return source }

        // A leading, delimited YAML frontmatter block is copied through
        // verbatim and is never parsed. Excluding it from the parse also stops
        // a frontmatter reference definition (or link-like string) from
        // resolving or altering links in the body. Interpreting the metadata
        // is deliberately out of scope for v1.
        let allBytes = Array(source.utf8)
        let bodyStart = frontmatterBodyStart(allBytes)
        guard bodyStart > 0 else {
            return normalizeBody(source)
        }
        let frontmatter = String(decoding: allBytes[0..<bodyStart], as: UTF8.self)
        let body = String(decoding: allBytes[bodyStart...], as: UTF8.self)
        return frontmatter + normalizeBody(body)
    }

    /// Removes link/image destinations from `source`, which must not contain a
    /// leading frontmatter block (the caller strips that first). Preserves the
    /// line-terminator sequence exactly.
    private static func normalizeBody(_ source: String) -> String {
        guard !source.isEmpty else { return source }

        let bytes = Array(source.utf8)
        // Default options keep source-position tracking on (the opt-out is
        // `disableSourcePosOpts`). No source URL is needed to locate ranges.
        let document = Document(parsing: source)

        let lineStarts = computeLineStarts(bytes)

        var edits: [Edit] = []
        collectEdits(from: document, bytes: bytes, lineStarts: lineStarts, byteCount: bytes.count, into: &edits)

        // No links or images: the source is already plain text for our
        // purposes, so hand it back untouched (and unallocated).
        guard !edits.isEmpty else { return source }

        return applyEdits(edits, to: bytes)
    }

    // MARK: - Edit model

    /// A half-open byte range `[start, end)` in the original buffer to be
    /// replaced by `replacement` (only ever line terminators, never new text).
    private struct Edit {
        let start: Int
        let end: Int
        let replacement: [UInt8]
    }

    // MARK: - Tree walk

    private static func collectEdits(from markup: Markup,
                                     bytes: [UInt8],
                                     lineStarts: [Int],
                                     byteCount: Int,
                                     into edits: inout [Edit]) {
        if let link = markup as? Link {
            appendEdits(for: link, bytes: bytes, lineStarts: lineStarts, byteCount: byteCount, into: &edits)
        } else if let image = markup as? Image {
            appendEdits(for: image, bytes: bytes, lineStarts: lineStarts, byteCount: byteCount, into: &edits)
        }

        // Always descend: a link label may itself contain an image, and both
        // sets of edits compose because neither touches the other's bytes.
        for child in markup.children {
            collectEdits(from: child, bytes: bytes, lineStarts: lineStarts, byteCount: byteCount, into: &edits)
        }
    }

    /// Emits the opener and closer deletions for one link or image node.
    ///
    /// For `[label](url)` the label occupies `[b, c)` (the first child's start
    /// through the last child's end). We delete the opener `[a, b)` and the
    /// closer `[c, d)`, keeping `[b, c)` intact. A node with no children
    /// (empty label / alt) is deleted whole. Every deletion re-emits the line
    /// terminators it contained so the line count never changes.
    private static func appendEdits(for node: Markup,
                                    bytes: [UInt8],
                                    lineStarts: [Int],
                                    byteCount: Int,
                                    into edits: inout [Edit]) {
        guard let range = node.range,
              let a = byteOffset(range.lowerBound, lineStarts: lineStarts, byteCount: byteCount),
              let d = byteOffset(range.upperBound, lineStarts: lineStarts, byteCount: byteCount),
              a <= d else {
            // A missing or backwards range means we cannot edit safely; leave
            // the node alone rather than risk corrupting the document.
            return
        }

        let count = node.childCount
        if count == 0 {
            edits.append(Edit(start: a, end: d, replacement: lineTerminators(in: bytes, from: a, to: d)))
            return
        }

        guard let firstChild = node.child(at: 0),
              let lastChild = node.child(at: count - 1),
              let firstRange = firstChild.range,
              let lastRange = lastChild.range,
              let b = byteOffset(firstRange.lowerBound, lineStarts: lineStarts, byteCount: byteCount),
              let c = byteOffset(lastRange.upperBound, lineStarts: lineStarts, byteCount: byteCount),
              a <= b, b <= c, c <= d else {
            // Inconsistent child ranges: keep the label words rather than drop
            // them, so we simply skip this node.
            return
        }

        if a < b {
            edits.append(Edit(start: a, end: b, replacement: lineTerminators(in: bytes, from: a, to: b)))
        }
        if c < d {
            edits.append(Edit(start: c, end: d, replacement: lineTerminators(in: bytes, from: c, to: d)))
        }
    }

    // MARK: - Frontmatter

    /// If `bytes` opens with a delimited YAML frontmatter block, returns the
    /// byte index at which the body begins (just past the closing delimiter
    /// line); otherwise returns 0.
    ///
    /// Detection is intentionally conservative: the very first line must be
    /// exactly `---` (trailing spaces/tabs allowed), and there must be a later
    /// line that is exactly `---` or `...` closing it. Any leading block that
    /// matches this shape is protected — even if it is really a thematic-break
    /// section — because keeping a URL is safer than dropping words, and no
    /// document normally opens this way except with frontmatter. Without a
    /// closing delimiter the input is treated as ordinary content.
    private static func frontmatterBodyStart(_ bytes: [UInt8]) -> Int {
        let n = bytes.count
        let opener = lineSpan(bytes, from: 0)
        // The opener must be `---` and must be followed by a real line ending
        // (a lone `---` with no newline is not a frontmatter block).
        guard opener.next > opener.contentEnd,
              isDelimiter(bytes, from: 0, contentEnd: opener.contentEnd, allowDots: false) else {
            return 0
        }

        var cursor = opener.next
        while cursor < n {
            let line = lineSpan(bytes, from: cursor)
            if isDelimiter(bytes, from: cursor, contentEnd: line.contentEnd, allowDots: true) {
                return line.next
            }
            cursor = line.next
        }
        return 0
    }

    /// Returns the content end (index of the first line-terminator byte, or the
    /// buffer length) and the start of the next line for the line beginning at
    /// `start`. Recognizes `\n`, `\r\n`, and a lone `\r`.
    private static func lineSpan(_ bytes: [UInt8], from start: Int) -> (contentEnd: Int, next: Int) {
        let n = bytes.count
        var i = start
        while i < n {
            let b = bytes[i]
            if b == 0x0A {
                return (i, i + 1)
            } else if b == 0x0D {
                if i + 1 < n && bytes[i + 1] == 0x0A {
                    return (i, i + 2)
                }
                return (i, i + 1)
            }
            i += 1
        }
        return (n, n)
    }

    /// Whether `bytes[from..<contentEnd]` is a frontmatter delimiter: three `-`
    /// (or, when `allowDots`, three `.`) followed only by spaces or tabs.
    private static func isDelimiter(_ bytes: [UInt8], from: Int, contentEnd: Int, allowDots: Bool) -> Bool {
        guard contentEnd - from >= 3 else { return false }
        let a = bytes[from], b = bytes[from + 1], c = bytes[from + 2]
        let dashes = (a == 0x2D && b == 0x2D && c == 0x2D)          // ---
        let dots = allowDots && (a == 0x2E && b == 0x2E && c == 0x2E) // ...
        guard dashes || dots else { return false }
        var i = from + 3
        while i < contentEnd {
            let ch = bytes[i]
            if ch != 0x20 && ch != 0x09 { return false } // space or tab only
            i += 1
        }
        return true
    }

    // MARK: - Coordinate mapping

    /// Byte offsets at which each source line begins, plus a trailing sentinel
    /// equal to the buffer length so an `upperBound` at end-of-file resolves.
    /// Line breaks are counted the way cmark does: `\n`, `\r\n`, or a lone `\r`.
    private static func computeLineStarts(_ bytes: [UInt8]) -> [Int] {
        var starts: [Int] = [0]
        var i = 0
        let n = bytes.count
        while i < n {
            let b = bytes[i]
            if b == 0x0A { // \n
                starts.append(i + 1)
                i += 1
            } else if b == 0x0D { // \r
                if i + 1 < n && bytes[i + 1] == 0x0A { // \r\n
                    starts.append(i + 2)
                    i += 2
                } else { // lone \r
                    starts.append(i + 1)
                    i += 1
                }
            } else {
                i += 1
            }
        }
        if starts.last != n {
            starts.append(n)
        }
        return starts
    }

    /// Converts a `SourceLocation` (1-based line, 1-based UTF-8 byte column)
    /// into an absolute byte offset, or `nil` if it falls outside the buffer.
    private static func byteOffset(_ location: SourceLocation, lineStarts: [Int], byteCount: Int) -> Int? {
        let lineIndex = location.line - 1
        guard lineIndex >= 0, lineIndex < lineStarts.count else { return nil }
        let offset = lineStarts[lineIndex] + (location.column - 1)
        guard offset >= 0, offset <= byteCount else { return nil }
        return offset
    }

    /// Collects the line-terminator bytes inside `[start, end)`, preserving
    /// their exact form (`\r\n`, `\n`, or lone `\r`) and order.
    private static func lineTerminators(in bytes: [UInt8], from start: Int, to end: Int) -> [UInt8] {
        var result: [UInt8] = []
        var i = start
        while i < end {
            let b = bytes[i]
            if b == 0x0A {
                result.append(0x0A)
                i += 1
            } else if b == 0x0D {
                if i + 1 < end && bytes[i + 1] == 0x0A {
                    result.append(0x0D)
                    result.append(0x0A)
                    i += 2
                } else {
                    result.append(0x0D)
                    i += 1
                }
            } else {
                i += 1
            }
        }
        return result
    }

    // MARK: - Apply

    private static func applyEdits(_ edits: [Edit], to bytes: [UInt8]) -> String {
        let sorted = edits.sorted { $0.start < $1.start }
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)

        var cursor = 0
        for edit in sorted {
            // Edits are disjoint by construction; skip any overlap defensively
            // so a parser surprise degrades to under-editing, never corruption.
            guard edit.start >= cursor, edit.end <= bytes.count, edit.start <= edit.end else { continue }
            output.append(contentsOf: bytes[cursor..<edit.start])
            output.append(contentsOf: edit.replacement)
            cursor = edit.end
        }
        if cursor < bytes.count {
            output.append(contentsOf: bytes[cursor..<bytes.count])
        }

        return String(decoding: output, as: UTF8.self)
    }
}
