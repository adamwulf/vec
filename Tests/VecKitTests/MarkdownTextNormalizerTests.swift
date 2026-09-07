import XCTest
@testable import VecKit

/// Focused unit tests for `MarkdownTextNormalizer`.
///
/// The suite is organized around the two guarantees the normalizer makes:
///  1. Link/image *destinations* are removed; visible label/alt text stays.
///  2. The line-terminator sequence is preserved exactly, so a chunk's source
///     line numbers stay accurate after normalization.
final class MarkdownTextNormalizerTests: XCTestCase {

    private func normalize(_ s: String) -> String {
        MarkdownTextNormalizer.normalize(s)
    }

    /// The ordered list of line terminators in `s` (`\r\n`, `\n`, or lone
    /// `\r`). Equal signatures mean identical newline count, kind, and order —
    /// the integration contract with the splitter.
    private func lineTerminatorSignature(_ s: String) -> [String] {
        var result: [String] = []
        let scalars = Array(s.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if c == "\r" {
                if i + 1 < scalars.count && scalars[i + 1] == "\n" {
                    result.append("\r\n"); i += 2
                } else {
                    result.append("\r"); i += 1
                }
            } else if c == "\n" {
                result.append("\n"); i += 1
            } else {
                i += 1
            }
        }
        return result
    }

    /// Asserts the newline layout is byte-identical between input and output.
    private func assertNewlinesPreserved(_ input: String, _ output: String,
                                         _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lineTerminatorSignature(input), lineTerminatorSignature(output),
                       message, file: file, line: line)
    }

    // MARK: - Core link / image stripping

    func testBasicLinkKeepsLabelDropsDestination() {
        XCTAssertEqual(normalize("[label](https://example.com)"), "label")
    }

    func testBasicImageKeepsAltDropsSource() {
        XCTAssertEqual(normalize("![alt text](https://example.com/image.png)"), "alt text")
    }

    func testLinkInSentenceKeepsSurroundingText() {
        XCTAssertEqual(normalize("See [the docs](https://x.com) now."), "See the docs now.")
    }

    func testMultipleLinksOnOneLine() {
        XCTAssertEqual(normalize("[a](1) and [b](2)."), "a and b.")
    }

    func testLinkWithTitleDropsTitle() {
        XCTAssertEqual(normalize("[label](https://x.com \"a title\")"), "label")
    }

    func testNestedParenthesesInDestination() {
        // CommonMark allows balanced parens in an unenclosed destination.
        let input = "[wiki](https://en.wikipedia.org/wiki/Foo_(bar))"
        XCTAssertEqual(normalize(input), "wiki")
    }

    func testAngleBracketedDestination() {
        XCTAssertEqual(normalize("[label](<https://x.com/a b>)"), "label")
    }

    func testImageNestedInLinkLabel() {
        // Both nodes are edited in one pass; only the alt text survives.
        XCTAssertEqual(normalize("[![alt](img.png)](https://x.com)"), "alt")
    }

    func testLabelWithInnerEmphasisIsKeptVerbatim() {
        // Emphasis markers are out of scope: no words are dropped.
        XCTAssertEqual(normalize("[see **bold** text](https://x.com)"), "see **bold** text")
    }

    func testLabelWithInlineCodeIsKept() {
        XCTAssertEqual(normalize("[call `foo()` now](https://x.com)"), "call `foo()` now")
    }

    // MARK: - Reference links

    func testReferenceLinkUsageIsResolvedToLabel() {
        let input = "[label][ref]\n\n[ref]: https://example.com\n"
        let output = normalize(input)
        let lines = output.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "label")
        // The definition line is preserved verbatim (see documented limitation).
        XCTAssertTrue(output.contains("[ref]: https://example.com"))
        assertNewlinesPreserved(input, output)
    }

    func testShortcutReferenceLinkIsResolvedToLabel() {
        let input = "Read [the guide].\n\n[the guide]: https://example.com\n"
        let output = normalize(input)
        XCTAssertEqual(output.components(separatedBy: "\n").first, "Read the guide.")
        assertNewlinesPreserved(input, output)
    }

    // MARK: - Autolinks and bare URLs

    func testAutolinkKeepsUrlText() {
        XCTAssertEqual(normalize("<https://example.com>"), "https://example.com")
    }

    func testBareUrlIsPreservedLiterally() {
        let input = "Visit https://example.com today."
        XCTAssertEqual(normalize(input), input)
    }

    // MARK: - Escaped syntax

    func testEscapedLinkSyntaxIsNotTreatedAsLink() {
        let input = "\\[not a link\\](not-a-url)"
        // Not a link, so the source (backslashes and all) is preserved.
        XCTAssertEqual(normalize(input), input)
    }

    // MARK: - Unicode

    func testUnicodeBeforeAndInsideLink() {
        // Multi-byte characters before the link exercise UTF-8 byte columns.
        let input = "héllo wörld [ссылка](https://example.com/страница) 🎯"
        XCTAssertEqual(normalize(input), "héllo wörld ссылка 🎯")
    }

    func testEmojiImmediatelyBeforeLink() {
        XCTAssertEqual(normalize("🚀[go](https://x.com)"), "🚀go")
    }

    // MARK: - Code preservation (parser never makes links inside code)

    func testInlineCodeContainingLinkSyntaxIsPreserved() {
        let input = "Use `[x](y)` verbatim."
        XCTAssertEqual(normalize(input), input)
    }

    func testFencedCodeBlockIsPreserved() {
        let input = "```\n[x](https://y.com)\nlet u = \"https://z.com\"\n```\n"
        XCTAssertEqual(normalize(input), input)
    }

    func testIndentedCodeBlockIsPreserved() {
        let input = "paragraph\n\n    [x](https://y.com)\n"
        XCTAssertEqual(normalize(input), input)
    }

    func testTabIndentedCodeBlockIsPreserved() {
        let input = "paragraph\n\n\t[x](https://y.com)\n"
        XCTAssertEqual(normalize(input), input)
    }

    // MARK: - Block boundaries

    func testLinkInsideHeadingKeepsHeadingMarker() {
        XCTAssertEqual(normalize("# Title with [link](https://x.com)"), "# Title with link")
    }

    func testLinkInsideListItemKeepsBullet() {
        let input = "- item one [link](https://x.com)\n- item two\n"
        XCTAssertEqual(normalize(input), "- item one link\n- item two\n")
    }

    func testParagraphAndHeadingBoundariesPreserved() {
        let input = "# Heading\n\nA paragraph with [a link](https://x.com).\n\n## Next\n"
        let output = normalize(input)
        XCTAssertEqual(output, "# Heading\n\nA paragraph with a link.\n\n## Next\n")
        assertNewlinesPreserved(input, output)
    }

    // MARK: - Frontmatter (interpretation deferred; content preserved)

    func testFrontmatterContentIsPreserved() {
        let input = """
        ---
        title: Hello
        url: https://example.com/in-frontmatter
        ---

        # Body

        [link](https://example.com/in-body)
        """
        let output = normalize(input)
        XCTAssertTrue(output.contains("url: https://example.com/in-frontmatter"),
                      "Frontmatter scalar must be preserved verbatim")
        XCTAssertTrue(output.contains("title: Hello"))
        // The body link is normalized to its label.
        XCTAssertTrue(output.contains("\nlink"))
        XCTAssertFalse(output.contains("in-body"))
        assertNewlinesPreserved(input, output)
    }

    func testFrontmatterLinkSyntaxIsPreservedVerbatim() {
        let input = [
            "---",
            "title: Hello",
            "hero: [click here](https://tracker.example.com/x)",
            "---",
            "",
            "Body [visible](https://body.example.com).",
            ""
        ].joined(separator: "\n")
        let output = normalize(input)
        // Link-like strings inside frontmatter survive byte-for-byte.
        XCTAssertTrue(output.contains("hero: [click here](https://tracker.example.com/x)"))
        XCTAssertTrue(output.contains("title: Hello"))
        // A genuine body link is still normalized.
        XCTAssertTrue(output.contains("Body visible."))
        XCTAssertFalse(output.contains("https://body.example.com"))
        assertNewlinesPreserved(input, output)
    }

    func testFrontmatterReferenceDefinitionDoesNotLeakIntoBody() {
        // The blank line makes `[ref]:` a block start, so it WOULD be parsed as
        // a reference definition if the frontmatter were not excluded. It must
        // not resolve the body's `[ref]`, which has to stay literal.
        let input = [
            "---",
            "title: Hello",
            "",
            "[ref]: https://frontmatter-only.example.com",
            "---",
            "",
            "Body uses [ref] and [visible](https://body.example.com).",
            ""
        ].joined(separator: "\n")
        let output = normalize(input)
        XCTAssertTrue(output.contains("[ref]: https://frontmatter-only.example.com"),
                      "Frontmatter definition preserved verbatim")
        XCTAssertTrue(output.contains("Body uses [ref] and"),
                      "Body [ref] must stay literal (definition did not leak)")
        XCTAssertFalse(output.contains("Body uses ref and"),
                       "A leaked definition would have stripped the brackets")
        XCTAssertTrue(output.contains("visible"))
        XCTAssertFalse(output.contains("https://body.example.com"))
        assertNewlinesPreserved(input, output)
    }

    func testFrontmatterClosedWithDotsIsProtected() {
        let input = [
            "---",
            "link: [x](https://frontmatter.example.com)",
            "...",
            "",
            "[y](https://body.example.com)",
            ""
        ].joined(separator: "\n")
        let output = normalize(input)
        XCTAssertTrue(output.contains("link: [x](https://frontmatter.example.com)"))
        XCTAssertTrue(output.contains("\ny\n"))
        XCTAssertFalse(output.contains("https://body.example.com"))
        assertNewlinesPreserved(input, output)
    }

    func testLeadingDashesWithoutCloserAreNotFrontmatter() {
        // No closing delimiter: treat as ordinary content, so the body link is
        // still normalized.
        let input = "---\n# Title\n\n[link](https://example.com)\n"
        let output = normalize(input)
        XCTAssertEqual(output, "---\n# Title\n\nlink\n")
        assertNewlinesPreserved(input, output)
    }

    func testBareTripleDashWithoutNewlineIsNotFrontmatter() {
        // A lone "---" with no following line is not a frontmatter opener.
        XCTAssertEqual(normalize("---"), "---")
    }

    // MARK: - CRLF

    func testCRLFNewlinesArePreserved() {
        let input = "[a](https://x.com)\r\nnext line\r\n"
        XCTAssertEqual(normalize(input), "a\r\nnext line\r\n")
    }

    func testMixedCRLFAndLFPreserved() {
        let input = "[a](https://x.com)\r\n[b](https://y.com)\nplain\r\n"
        let output = normalize(input)
        XCTAssertEqual(output, "a\r\nb\nplain\r\n")
        assertNewlinesPreserved(input, output)
    }

    // MARK: - Multiline links and definitions

    func testMultilineInlineLinkWithTitleOnNextLinePreservesNewline() {
        // A single line ending is allowed in the whitespace before an inline
        // link title, so this whole construct is one valid link spanning two
        // lines. The label stays on line 1; the interior newline is retained
        // so trailing text keeps its original line.
        let input = "See [the docs](https://example.com\n\"Title\") here."
        let output = normalize(input)
        XCTAssertEqual(output, "See the docs\n here.")
        assertNewlinesPreserved(input, output)
    }

    func testDestinationContainingLineBreakIsNotALink() {
        // Per CommonMark an unenclosed inline destination may not contain a
        // line ending, so this is not a link at all and must survive verbatim.
        let input = "See [the docs](https://example.com/\npath) here."
        let output = normalize(input)
        XCTAssertEqual(output, input)
        assertNewlinesPreserved(input, output)
    }

    func testLinkLabelSpanningTwoLinesKeepsBothLines() {
        let input = "[click\nhere](https://x.com) done"
        let output = normalize(input)
        XCTAssertEqual(output, "click\nhere done")
        assertNewlinesPreserved(input, output)
    }

    func testMultilineReferenceDefinitionUsageResolvesAndLinesPreserved() {
        let input = "[x][r] tail\n\n[r]: https://example.com/very/long/path\n   \"multi line title\"\n"
        let output = normalize(input)
        XCTAssertEqual(output.components(separatedBy: "\n").first, "x tail")
        assertNewlinesPreserved(input, output)
    }

    // MARK: - Empty / degenerate

    func testEmptyStringReturnsEmpty() {
        XCTAssertEqual(normalize(""), "")
    }

    func testWhitespaceOnlyIsUnchanged() {
        let input = "   \n\t\n"
        XCTAssertEqual(normalize(input), input)
    }

    func testEmptyLabelLinkProducesEmptyOutput() {
        XCTAssertEqual(normalize("[](https://example.com)"), "")
    }

    func testEmptyAltImageProducesEmptyOutput() {
        XCTAssertEqual(normalize("![](https://example.com/i.png)"), "")
    }

    func testEmptyLabelLinkBetweenTextCollapses() {
        // No label to keep; surrounding words remain and the line stays.
        XCTAssertEqual(normalize("before [](https://x.com) after"), "before  after")
    }

    // MARK: - Malformed markdown (must not crash; source preserved)

    func testUnclosedLinkIsPreserved() {
        let input = "[unclosed](https://example.com"
        XCTAssertEqual(normalize(input), input)
    }

    func testDanglingBracketsArePreserved() {
        let input = "text ] with ( stray [ brackets )"
        XCTAssertEqual(normalize(input), input)
    }

    func testUnresolvedReferenceIsPreserved() {
        let input = "[label][missing-ref] and more"
        XCTAssertEqual(normalize(input), input)
    }

    // MARK: - Newline invariant across a battery of inputs

    func testNewlineStructurePreservedAcrossManyInputs() {
        let inputs = [
            "[a](x)\n[b](y)\n[c](z)\n",
            "line1\nline2\n\n[link](url)\n\n\nline6",
            "no newline at all [q](u)",
            "\n\n\n[only](links)\n\n\n",
            "![i](s)\r\n![j](t)\r\n",
            "# H\n\n- [x](1)\n- [y](2)\n\n> quote [z](3)\n",
            "mixed\r\nendings\nhere\r[edge](case)"
        ]
        for input in inputs {
            let output = normalize(input)
            assertNewlinesPreserved(input, output, "Newlines drifted for input: \(input.debugDescription)")
        }
    }

    // MARK: - Line-index integrity (every source line maps to itself)

    func testEachOutputLineCorrespondsToItsSourceLine() {
        // 20 uniquely-tagged lines; after stripping the long URLs each tag must
        // remain on its original line index.
        let sourceLines = (1...20).map {
            "L\($0) [ref\($0)](https://example.com/\(String(repeating: "seg/", count: 20))) keep\($0)"
        }
        let input = sourceLines.joined(separator: "\n")
        let output = normalize(input)
        let outputLines = output.components(separatedBy: "\n")
        XCTAssertEqual(outputLines.count, sourceLines.count)
        for (index, line) in outputLines.enumerated() {
            let number = index + 1
            XCTAssertTrue(line.contains("L\(number) "), "Line \(number) lost its head tag: \(line.debugDescription)")
            XCTAssertTrue(line.contains("keep\(number)"), "Line \(number) lost its tail tag: \(line.debugDescription)")
            XCTAssertFalse(line.contains("https://"), "Line \(number) kept a destination: \(line.debugDescription)")
        }
    }
}
