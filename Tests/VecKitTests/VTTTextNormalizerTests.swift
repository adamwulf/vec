import XCTest
@testable import VecKit

final class VTTTextNormalizerTests: XCTestCase {
    func testStripsStructureAndJoinsFragmentedCues() {
        let source = """
        WEBVTT - English
        Kind: captions
        Language: en

        NOTE commentary
        00:00.000 --> 00:01.000
        do not embed this

        STYLE
        ::cue { color: red; }

        REGION
        id:main
        width:80%

        arbitrary-cue-id
        00:00:01.000 --> 00:00:03.000 align:start position:0%
        <c.green><i>Hello</i> <b>world</b></c>
        this is

        2
        00:03.000 --> 00:05.000
        a <u>readable</u> <lang en>sentence.</lang>
        """
        XCTAssertEqual(VTTTextNormalizer.normalize(source), "Hello world this is a readable sentence.")
    }

    func testDecodesEntitiesAfterStrippingTags() {
        let source = """
        WEBVTT

        00:00.000 --> 00:02.000
        <00:00.200><c>猫 &amp; café&nbsp;&lt;i&gt; &#65; &#x1F600; &quot;yes&quot; &apos;no&apos; &amp;lt; &unknown; &#xD800;</c>
        """
        XCTAssertEqual(VTTTextNormalizer.normalize(source), "猫 & café <i> A 😀 \"yes\" 'no' &lt; &unknown; &#xD800;")
    }

    func testPreservesSpeakersAndMultipleVoicesInOneCue() {
        let source = """
        WEBVTT

        00:00.000 --> 00:02.000
        <v.class Alice &amp; Bob><i>We are</i>
        talking.

        00:02.000 --> 00:04.000
        <v Alice &amp; Bob>Still talking.</v>

        00:04.000 --> 00:06.000
        <v Carol>Hello.</v><v Dave>Hello.</v>

        00:06.000 --> 00:08.000
        Unattributed speech.
        """
        XCTAssertEqual(VTTTextNormalizer.normalize(source), "Alice & Bob: We are talking. Still talking.\n\nCarol: Hello.\n\nDave: Hello.\n\nUnattributed speech.")
    }

    func testRollingOverlapAndDuplicateCues() {
        let source = """
        WEBVTT

        00:00.000 --> 00:02.000
        we are building

        00:01.000 --> 00:03.000
        we are building a better

        00:02.000 --> 00:04.000
        a better caption parser

        00:03.000 --> 00:05.000
        a better caption parser

        00:05.000 --> 00:06.000
        caption parser today.
        """
        XCTAssertEqual(VTTTextNormalizer.normalize(source), "we are building a better caption parser today.")
    }

    func testDoesNotDeduplicateRepeatedSpeechAcrossTimeOrSpeakers() {
        let source = """
        WEBVTT

        00:00.000 --> 00:01.000
        <v A>yes yes

        00:01.000 --> 00:02.000
        <v A>yes yes

        00:01.500 --> 00:03.000
        <v B>yes yes

        00:10.000 --> 00:11.000
        <v B>yes yes

        00:05.000 --> 00:06.000
        <v B>yes yes
        """
        XCTAssertEqual(VTTTextNormalizer.normalize(source), "A: yes yes yes yes\n\nB: yes yes\n\nB: yes yes\n\nB: yes yes")
    }

    func testParagraphsBreakOnSilenceAndThirtySecondBoundaries() {
        let source = """
        WEBVTT

        00:00.000 --> 00:29.000
        First idea.

        00:30.000 --> 00:31.000
        Second idea.

        00:36.000 --> 00:37.000
        After a pause.
        """
        XCTAssertEqual(VTTTextNormalizer.normalize(source), "First idea.\n\nSecond idea.\n\nAfter a pause.")
    }

    func testMalformedBlocksAreSkippedAndHeaderlessCuesRecover() {
        for source in ["", "WEBVTT", "WEBVTT\n\nNOTE nothing\nmore", "not captions", "00:00.000 --> 00:02.000"] {
            XCTAssertEqual(VTTTextNormalizer.normalize(source), "")
        }
        let source = """
        invalid
        00:61.000 --> 00:62.000
        invalid minute or second

        00:05.000 --> 00:01.000
        backwards duration

        00:01.000 --> 00:01.000
        empty duration

        00:01.000 --> 00:02.000
        NOTEworthy & music [applause] 2 < 3
        """
        XCTAssertEqual(VTTTextNormalizer.normalize(source), "NOTEworthy & music [applause] 2 < 3")
    }

    func testBOMAndAllLineEndingsHaveSameSourceCoordinates() {
        for newline in ["\n", "\r\n", "\r"] {
            let source = ["\u{FEFF}WEBVTT", "", "cue-id", "01:00:00.000 --> 01:00:02.000", "Hello", "world", ""].joined(separator: newline)
            let document = VTTTextNormalizer.document(source)
            XCTAssertEqual(document.text, "Hello world")
            XCTAssertEqual(document.lineCount, 6)
            XCTAssertEqual(document.passages.first?.lineStart, 4)
            XCTAssertEqual(document.passages.first?.lineEnd, 6)
        }
    }

    func testLongRollingCuePreservesNewTail() {
        let repeated = Array(repeating: "same", count: 5_000).joined(separator: " ")
        let source = "WEBVTT\n\n00:00.000 --> 00:02.000\n\(repeated)\n\n00:01.000 --> 00:03.000\n\(repeated) new tail"
        XCTAssertEqual(VTTTextNormalizer.normalize(source), repeated + " new tail")
    }

    func testMissingBlankCueSeparatorDoesNotEmbedTimingLine() {
        let source = "WEBVTT\n\n00:00.000 --> 00:01.000\nHello\n00:01.000 --> 00:02.000\nworld"
        let document = VTTTextNormalizer.document(source)
        XCTAssertEqual(document.text, "Hello world")
        XCTAssertEqual(document.passages.first?.lineStart, 3)
        XCTAssertEqual(document.passages.first?.lineEnd, 6)
        XCTAssertEqual(VTTTextNormalizer.document("\u{FEFF}").lineCount, 1)
    }
}
