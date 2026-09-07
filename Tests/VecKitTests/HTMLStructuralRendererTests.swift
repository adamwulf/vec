import XCTest
@testable import VecKit

final class HTMLStructuralRendererTests: XCTestCase {
    private func render(
        _ html: String,
        title: String? = nil,
        cleanup: HTMLDOMCleanupMode = .visiblePageFallback,
        maximumElements: Int = 1_000
    ) throws -> HTMLStructuralRenderResult {
        try HTMLStructuralRenderer.render(
            html,
            baseURI: "file:///tmp/page.html",
            title: title,
            cleanupMode: cleanup,
            maximumElementCount: maximumElements
        )
    }

    private func text(_ result: HTMLStructuralRenderResult) -> String {
        result.segments.compactMap { segment in
            guard case .text(let value) = segment else { return nil }
            return value
        }.joined(separator: "\n\n")
    }

    func testRendersTitleHeadingsListsTablesAndEntities() throws {
        let html = """
        <h2>Reference &amp; Setup</h2>
        <p>Use <strong>safe defaults</strong> for café users.</p>
        <ol start="3"><li>Install</li><li>Configure<ul><li>Offline mode</li></ul></li></ol>
        <table><tr><th>Key</th><th>Meaning</th></tr><tr><td>A</td><td>Alpha &lt; Beta</td></tr></table>
        """
        let output = text(try render(html, title: "Local Manual"))
        XCTAssertTrue(output.hasPrefix("# Local Manual"))
        XCTAssertTrue(output.contains("## Reference & Setup"))
        XCTAssertTrue(output.contains("Use safe defaults for café users."))
        XCTAssertTrue(output.contains("3. Install"))
        XCTAssertTrue(output.contains("4. Configure"))
        XCTAssertTrue(output.contains("- Offline mode"))
        XCTAssertTrue(output.contains("| Key | Meaning |"))
        XCTAssertTrue(output.contains("| --- | --- |"))
        XCTAssertTrue(output.contains("| A | Alpha < Beta |"))
    }

    func testMatchingFirstHeadingDoesNotDuplicateTitle() throws {
        let output = text(try render("<h1>Résumé Guide</h1><p>Body.</p>", title: "Resume Guide"))
        XCTAssertEqual(output.components(separatedBy: "# Résumé Guide").count - 1, 1)
        XCTAssertFalse(output.contains("# Resume Guide"))
    }

    func testMatchingFirstParagraphDoesNotSuppressTitle() throws {
        let output = text(try render("<p>Body</p><p>Details.</p>", title: "Body"))
        XCTAssertTrue(output.hasPrefix("# Body\n\nBody"))
    }

    func testFallbackRemovesStaticChromeButKeepsReferenceContentAndFooter() throws {
        let html = """
        <nav>Home Products Pricing</nav>
        <div role="Navigation">Secondary navigation</div>
        <main>
          <h1>API Index</h1>
          <p>Visible reference content.</p>
          <div style=" DISPLAY : none !important ">Hidden promotion</div>
          <div aria-hidden="TRUE">Hidden accessibility duplicate</div>
          <ul><li>Endpoint one</li><li>Endpoint two</li></ul>
          <form><input value="noise"><button>Submit</button></form>
          <script>window.evil = true</script>
          <style>.secret { display: block }</style>
        </main>
        <footer>License terms remain useful.</footer>
        """
        let output = text(try render(html))
        for omitted in [
            "Home Products", "Secondary navigation", "Hidden promotion",
            "Hidden accessibility duplicate", "Submit", "window.evil", ".secret",
        ] {
            XCTAssertFalse(output.contains(omitted), "Unexpected fallback chrome: \(omitted)")
        }
        XCTAssertTrue(output.contains("# API Index"))
        XCTAssertTrue(output.contains("Visible reference content."))
        XCTAssertTrue(output.contains("- Endpoint one"))
        XCTAssertTrue(output.contains("License terms remain useful."))
    }

    func testMalformedHTMLRecoversDeterministically() throws {
        let html = "<article><h1>Broken &amp; useful<p>First <b>paragraph<p>Second<ul><li>One<li>Two"
        let first = try render(html)
        let second = try render(html)
        XCTAssertEqual(first, second)
        let output = text(first)
        XCTAssertTrue(output.contains("# Broken & useful"))
        XCTAssertTrue(output.contains("First paragraph"))
        XCTAssertTrue(output.contains("Second"))
        XCTAssertTrue(output.contains("- One"))
        XCTAssertTrue(output.contains("- Two"))
    }

    func testImagesRemainOrderedWithoutResolvingTheirSources() throws {
        let html = """
        <p>Before diagram.</p>
        <img src="assets/chart.png" data-src="https://remote.example/chart.png" alt="Revenue chart">
        <p>Between images.</p>
        <img srcset="small.jpg 1x, large.jpg 2x" alt="Responsive diagram">
        <p>After diagram.</p>
        """
        let result = try render(html)
        XCTAssertEqual(result.segments.count, 5)
        guard case .text(let before) = result.segments[0],
              case .image(let first) = result.segments[1],
              case .text(let middle) = result.segments[2],
              case .image(let second) = result.segments[3],
              case .text(let after) = result.segments[4] else {
            return XCTFail("Expected alternating text/image DOM order: \(result.segments)")
        }
        XCTAssertEqual(before, "Before diagram.")
        XCTAssertEqual(first.ordinal, 0)
        XCTAssertEqual(first.altText, "Revenue chart")
        XCTAssertEqual(first.sourceAttributes["src"], "assets/chart.png")
        XCTAssertEqual(first.sourceAttributes["data-src"], "https://remote.example/chart.png")
        XCTAssertEqual(middle, "Between images.")
        XCTAssertEqual(second.ordinal, 1)
        XCTAssertEqual(second.sourceAttributes["srcset"], "small.jpg 1x, large.jpg 2x")
        XCTAssertEqual(after, "After diagram.")
    }

    func testElementLimitFailsClosedAfterBoundedInputParse() throws {
        XCTAssertThrowsError(try render(
            "<div><p>one</p><p>two</p><p>three</p></div>",
            maximumElements: 2
        )) { error in
            guard case HTMLExtractionError.elementLimitExceeded(let actual, let maximum) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertGreaterThan(actual, maximum)
            XCTAssertEqual(maximum, 2)
        }
    }

    func testArticleCleanupDoesNotApplyFallbackNavigationPolicy() throws {
        let output = text(try render(
            "<nav>Kept by selected article mode</nav><p>Article body.</p>",
            cleanup: .selectedArticle
        ))
        XCTAssertTrue(output.contains("Kept by selected article mode"))
        XCTAssertTrue(output.contains("Article body."))
    }

    func testPreformattedTextKeepsIndentationAndBlankLines() throws {
        let output = text(try render("""
        <pre>if ready {
            first()

            second()
        }</pre>
        """))
        XCTAssertEqual(output, """
        ```
        if ready {
            first()

            second()
        }
        ```
        """)
    }

    func testEmptyAndExecutableOnlyFragmentsProduceNoSegments() throws {
        XCTAssertEqual(try render("").segments, [])
        XCTAssertEqual(
            try render("<script>steal()</script><style>body { display: none }</style>").segments,
            []
        )
    }
}
