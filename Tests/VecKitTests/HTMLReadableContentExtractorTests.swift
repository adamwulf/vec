import Foundation
import XCTest
@testable import VecKit

final class HTMLReadableContentExtractorTests: XCTestCase {
    private func plainOptions(maximumInputBytes: Int = 64 * 1_024) throws -> HTMLExtractionOptions {
        try HTMLExtractionOptions(
            maximumInputBytes: maximumInputBytes,
            maximumElementCount: 2_000
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vec-html-reader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testSingleSemanticArticleSuppressesSiblingNavigation() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let html = """
        <!doctype html><html><head><title>  Local   Story </title></head><body>
          <nav>Home Pricing Account</nav>
          <article><h1>Local Story</h1><p>A short article remains useful.</p><script>bad()</script></article>
          <aside>Unrelated promotion</aside>
        </body></html>
        """
        let result = try HTMLReadableContentExtractor.extract(
            html,
            sourceURL: root.appendingPathComponent("story.html"),
            options: plainOptions()
        )

        XCTAssertEqual(result.strategyIdentifier, "semantic-article-v1")
        XCTAssertEqual(result.extractorVersion, 1)
        XCTAssertEqual(result.title, "Local Story")
        XCTAssertEqual(result.renderedText(), "# Local Story\n\nA short article remains useful.")
        XCTAssertNil(result.assetManifest)
        XCTAssertFalse(result.renderedText().contains("Home Pricing"))
        XCTAssertFalse(result.renderedText().contains("Unrelated promotion"))
        XCTAssertFalse(result.renderedText().contains("bad()"))
    }

    func testReferencePageUsesVisiblePageFallbackAndKeepsStructure() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let html = """
        <nav>Global navigation</nav>
        <h1>Command Reference</h1>
        <p>Options are listed below.</p>
        <ul><li>Fast mode</li><li>Safe mode</li></ul>
        <table><tr><th>Flag</th><th>Meaning</th></tr><tr><td>--safe</td><td>No network</td></tr></table>
        """
        let result = try HTMLReadableContentExtractor.extract(
            html,
            sourceURL: root.appendingPathComponent("reference.htm"),
            options: plainOptions()
        )
        let text = result.renderedText()
        XCTAssertEqual(result.strategyIdentifier, "visible-page-v1")
        XCTAssertTrue(text.contains("# Command Reference"))
        XCTAssertTrue(text.contains("- Fast mode"))
        XCTAssertTrue(text.contains("| Flag | Meaning |"))
        XCTAssertTrue(text.contains("| --safe | No network |"))
        XCTAssertFalse(text.contains("Global navigation"))
    }

    func testNavigationOnlyDirectoryFallsBackRatherThanDisappearing() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try HTMLReadableContentExtractor.extract(
            "<nav><h1>Documentation</h1><ul><li><a href='api.html'>API</a></li><li>Guide</li></ul></nav>",
            sourceURL: root.appendingPathComponent("index.html"),
            options: plainOptions()
        )
        XCTAssertEqual(result.strategyIdentifier, "preserving-page-v1")
        XCTAssertTrue(result.renderedText().contains("# Documentation"))
        XCTAssertTrue(result.renderedText().contains("- API"))
        XCTAssertTrue(result.renderedText().contains("- Guide"))
    }

    func testMultipleArticlesUsePageFallbackWithoutDroppingEither() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try HTMLReadableContentExtractor.extract(
            "<article><h2>First</h2><p>One.</p></article><article><h2>Second</h2><p>Two.</p></article>",
            sourceURL: root.appendingPathComponent("feed.html"),
            options: plainOptions()
        )
        XCTAssertEqual(result.strategyIdentifier, "visible-page-v1")
        XCTAssertTrue(result.renderedText().contains("## First"))
        XCTAssertTrue(result.renderedText().contains("## Second"))
    }

    func testMainRoleIsCaseInsensitiveAndTakesPrecedenceOverArticle() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try HTMLReadableContentExtractor.extract(
            "<div role='MAIN'><h1>Primary</h1><p>Chosen content.</p></div><article>Other article.</article>",
            sourceURL: root.appendingPathComponent("page.html"),
            options: plainOptions()
        )
        XCTAssertEqual(result.strategyIdentifier, "semantic-role-main-v1")
        XCTAssertTrue(result.renderedText().contains("Chosen content."))
        XCTAssertFalse(result.renderedText().contains("Other article."))
    }

    func testScriptStyleOnlyPageIsEmptyEvenWithDocumentTitle() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try HTMLReadableContentExtractor.extract(
            "<html><head><title>Noise</title><style>.x{}</style></head><body><script>run()</script></body></html>",
            sourceURL: root.appendingPathComponent("empty.html"),
            options: plainOptions()
        )
        XCTAssertEqual(result.segments, [])
        XCTAssertEqual(result.renderedText(), "")
    }

    func testInputAndSourceURLAreRejectedBeforeExtraction() throws {
        XCTAssertThrowsError(try HTMLReadableContentExtractor.extract(
            "12345",
            sourceURL: URL(fileURLWithPath: "/tmp/large.html"),
            options: plainOptions(maximumInputBytes: 4)
        )) { error in
            XCTAssertEqual(
                error as? HTMLExtractionError,
                .inputTooLarge(actualBytes: 5, maximumBytes: 4)
            )
        }
        XCTAssertThrowsError(try HTMLReadableContentExtractor.extract(
            "éé",
            sourceURL: URL(fileURLWithPath: "/tmp/unicode.html"),
            options: plainOptions(maximumInputBytes: 3)
        )) { error in
            XCTAssertEqual(
                error as? HTMLExtractionError,
                .inputTooLarge(actualBytes: 4, maximumBytes: 3)
            )
        }
        XCTAssertThrowsError(try HTMLReadableContentExtractor.extract(
            "<p>Local input with a remote identity.</p>",
            sourceURL: try XCTUnwrap(URL(string: "https://example.invalid/page.html")),
            options: plainOptions()
        )) { error in
            XCTAssertEqual(
                error as? HTMLExtractionError,
                .nonFileSourceURL(URL(string: "https://example.invalid/page.html")!)
            )
        }
    }

    func testWholeDocumentElementLimitAppliesBeforeSemanticSelection() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let options = try HTMLExtractionOptions(
            maximumInputBytes: 64 * 1_024,
            maximumElementCount: 3
        )
        XCTAssertThrowsError(try HTMLReadableContentExtractor.extract(
            "<main><p>Selected.</p></main><aside><p>One</p><p>Two</p><p>Three</p></aside>",
            sourceURL: root.appendingPathComponent("many.html"),
            options: options
        )) { error in
            guard case HTMLExtractionError.elementLimitExceeded(let actual, let maximum) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertGreaterThan(actual, maximum)
            XCTAssertEqual(maximum, 3)
        }
    }

    func testMalformedDocumentIsRepairedDeterministically() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let html = "<main><h1>Broken &amp; useful<p>First <b>paragraph<p>Second<ul><li>One<li>Two"
        let first = try HTMLReadableContentExtractor.extract(
            html,
            sourceURL: root.appendingPathComponent("broken.html"),
            options: plainOptions()
        )
        let second = try HTMLReadableContentExtractor.extract(
            html,
            sourceURL: root.appendingPathComponent("broken.html"),
            options: plainOptions()
        )
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.renderedText().contains("# Broken & useful"))
        XCTAssertTrue(first.renderedText().contains("First paragraph"))
        XCTAssertTrue(first.renderedText().contains("- Two"))
    }

    func testPlainHTMLNeverResolvesRemoteImageOrLinkedResources() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try HTMLReadableContentExtractor.extract(
            """
            <link rel="stylesheet" href="https://example.invalid/site.css">
            <main><p>Offline body.</p><img src="https://example.invalid/chart.png" alt="Remote chart"></main>
            <iframe src="https://example.invalid/frame"></iframe>
            """,
            sourceURL: root.appendingPathComponent("offline.html"),
            options: plainOptions()
        )
        XCTAssertEqual(result.renderedText(), "Offline body.\n\nRemote chart")
        XCTAssertNil(result.assetManifest)
        XCTAssertTrue(result.diagnostics.isEmpty)
        guard case .image(let image) = result.segments[1] else {
            return XCTFail("Expected the remote image position")
        }
        XCTAssertNil(image.source)
    }

    func testDependencyDiscoveryMatchesCombinedExtractionManifest() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("chart.png"))
        let assetOptions = try HTMLOCRAssetOptions(
            policyVersion: HTMLOCRAssetOptions.currentPolicyVersion,
            allowedAssetRoot: root,
            temporaryAssetDirectory: root.appendingPathComponent("tmp", isDirectory: true),
            maximumImages: 4,
            maximumLocalImageBytes: 1_024,
            maximumInlineImageBytes: 1_024,
            maximumTotalInlineImageBytes: 2_048
        )
        let options = try HTMLExtractionOptions(
            maximumInputBytes: 64 * 1_024,
            maximumElementCount: 2_000,
            ocrAssets: assetOptions
        )
        let html = "<main><p>Before.</p><img src='chart.png' alt='Chart'><p>After.</p></main>"
        let sourceURL = root.appendingPathComponent("page.html")

        let content = try HTMLReadableContentExtractor.extract(
            html,
            sourceURL: sourceURL,
            options: options
        )
        let discovered = try HTMLReadableContentExtractor.discoverDependencies(
            html,
            sourceURL: sourceURL,
            options: options
        )
        XCTAssertEqual(content.assetManifest, discovered)
        XCTAssertEqual(content.assetManifest?.entries.first?.relativePath, "chart.png")
        XCTAssertEqual(content.renderedText(), "Before.\n\nChart\n\nAfter.")
    }
}
