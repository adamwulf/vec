import Foundation
import XCTest
@testable import VecKit

final class HTMLAssetResolverTests: XCTestCase {
    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vec-html-assets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func options(
        root: URL,
        maximumImages: Int = 10,
        maximumLocalBytes: Int64 = 1_024,
        maximumInlineBytes: Int = 1_024,
        maximumTotalInlineBytes: Int = 2_048
    ) throws -> HTMLOCRAssetOptions {
        try HTMLOCRAssetOptions(
            policyVersion: 1,
            allowedAssetRoot: root,
            temporaryAssetDirectory: root.appendingPathComponent("tmp", isDirectory: true),
            maximumImages: maximumImages,
            maximumLocalImageBytes: maximumLocalBytes,
            maximumInlineImageBytes: maximumInlineBytes,
            maximumTotalInlineImageBytes: maximumTotalInlineBytes
        )
    }

    private func image(
        _ ordinal: Int,
        alt: String,
        attributes: [String: String]
    ) -> HTMLStructuralSegment {
        .image(HTMLStructuralImage(
            ordinal: ordinal,
            altText: alt,
            sourceAttributes: attributes
        ))
    }

    private func imageReferences(in resolution: HTMLAssetResolution) -> [HTMLImageReference] {
        resolution.segments.compactMap { segment in
            guard case .image(let image) = segment else { return nil }
            return image
        }
    }

    func testPlainHTMLMapsAltAndOrderWithoutAssetIO() throws {
        let root = URL(fileURLWithPath: "/path/that/does/not/exist")
        let resolution = try HTMLAssetResolver.resolve(
            [
                .text("Before"),
                image(0, alt: "Local diagram", attributes: ["src": "missing.png"]),
                .text("After"),
            ],
            htmlFileURL: root.appendingPathComponent("page.html"),
            options: nil
        )

        XCTAssertNil(resolution.manifest)
        XCTAssertTrue(resolution.diagnostics.isEmpty)
        XCTAssertEqual(resolution.segments, [
            .text("Before"),
            .image(HTMLImageReference(
                ordinal: 0,
                altText: "Local diagram",
                source: nil,
                contentDigest: nil
            )),
            .text("After"),
        ])
    }

    func testLocalManifestDetectsContentChangeAndMissingAsset() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = root.appendingPathComponent("page_files", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let chart = assets.appendingPathComponent("chart.png")
        try Data([1, 2, 3]).write(to: chart)
        let segments = [
            image(0, alt: "Chart", attributes: ["src": "page_files/chart.png"]),
            image(1, alt: "Missing", attributes: ["src": "page_files/missing.jpg"]),
        ]
        let policy = try options(root: root)

        let first = try HTMLAssetResolver.resolve(
            segments,
            htmlFileURL: root.appendingPathComponent("page.html"),
            options: policy
        )
        XCTAssertEqual(first.manifest?.entries.count, 2)
        XCTAssertEqual(first.manifest?.entries[0].state, .present)
        XCTAssertEqual(first.manifest?.entries[0].relativePath, "page_files/chart.png")
        XCTAssertEqual(first.manifest?.entries[0].byteCount, 3)
        XCTAssertNotNil(first.manifest?.entries[0].sha256)
        XCTAssertEqual(first.manifest?.entries[1].state, .missing)
        XCTAssertTrue(first.diagnostics.contains { $0.kind == .localImageMissing })
        guard case .localFile(let resolved)? = imageReferences(in: first)[0].source else {
            return XCTFail("Expected a local OCR source")
        }
        XCTAssertEqual(resolved, chart)

        try Data([1, 2, 4]).write(to: chart)
        let changed = try HTMLAssetResolver.resolve(
            segments,
            htmlFileURL: root.appendingPathComponent("page.html"),
            options: policy
        )
        XCTAssertNotEqual(first.manifest?.digest, changed.manifest?.digest)
        XCTAssertNotEqual(first.manifest?.entries[0].sha256, changed.manifest?.entries[0].sha256)
    }

    func testRemoteAndEscapingReferencesNeverBecomeOCRSources() throws {
        let outer = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outer) }
        let root = outer.appendingPathComponent("snapshot", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([7]).write(to: outer.appendingPathComponent("outside.png"))

        let result = try HTMLAssetResolver.resolve(
            [
                image(0, alt: "Remote", attributes: ["src": "https://example.invalid/a.png"]),
                image(1, alt: "Escape", attributes: ["src": "../outside.png"]),
            ],
            htmlFileURL: root.appendingPathComponent("page.html"),
            options: try options(root: root)
        )

        XCTAssertEqual(imageReferences(in: result).map(\.source), [nil, nil])
        XCTAssertEqual(result.manifest?.entries, [])
        XCTAssertTrue(result.diagnostics.contains { $0.kind == .remoteImageIgnored })
        XCTAssertTrue(result.diagnostics.contains { $0.kind == .imageOutsideAllowedRoot })
    }

    func testSymlinkEscapeIsRejectedAfterCanonicalization() throws {
        let outer = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outer) }
        let root = outer.appendingPathComponent("snapshot", isDirectory: true)
        let external = outer.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data([8]).write(to: external.appendingPathComponent("secret.png"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked", isDirectory: true),
            withDestinationURL: external
        )

        let result = try HTMLAssetResolver.resolve(
            [image(0, alt: "Secret", attributes: ["src": "linked/secret.png"])],
            htmlFileURL: root.appendingPathComponent("page.html"),
            options: try options(root: root)
        )
        XCTAssertNil(imageReferences(in: result)[0].source)
        XCTAssertTrue(result.diagnostics.contains { $0.kind == .imageOutsideAllowedRoot })
    }

    func testInlineDataDeduplicatesResidentBytesAndAppliesAggregateBound() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = Data([1, 2, 3]).base64EncodedString()
        let second = Data([4, 5, 6]).base64EncodedString()
        let result = try HTMLAssetResolver.resolve(
            [
                image(0, alt: "First", attributes: ["src": "data:image/png;base64,\(first)"]),
                image(1, alt: "Duplicate", attributes: ["src": "data:image/png;base64,\(first)"]),
                image(2, alt: "Over aggregate", attributes: ["src": "data:image/png;base64,\(second)"]),
            ],
            htmlFileURL: root.appendingPathComponent("page.html"),
            options: try options(
                root: root,
                maximumInlineBytes: 3,
                maximumTotalInlineBytes: 3
            )
        )

        let images = imageReferences(in: result)
        XCTAssertEqual(images[0].contentDigest, images[1].contentDigest)
        XCTAssertNotNil(images[0].source)
        XCTAssertNotNil(images[1].source)
        XCTAssertNil(images[2].source)
        XCTAssertTrue(result.diagnostics.contains {
            $0.kind == .inlineImageTooLarge && $0.detail?.contains("aggregate") == true
        })
        XCTAssertEqual(result.manifest?.entries, [])
    }

    func testImageWorkLimitKeepsAllAltTextAndSurroundingProse() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1]).write(to: root.appendingPathComponent("one.png"))
        try Data([2]).write(to: root.appendingPathComponent("two.png"))
        let result = try HTMLAssetResolver.resolve(
            [
                .text("Before"),
                image(0, alt: "First alt", attributes: ["src": "one.png"]),
                .text("Between"),
                image(1, alt: "Second alt", attributes: ["src": "two.png"]),
                .text("After"),
            ],
            htmlFileURL: root.appendingPathComponent("page.html"),
            options: try options(root: root, maximumImages: 1)
        )

        let content = HTMLReadableContent(
            strategyIdentifier: "fixture",
            extractorVersion: 1,
            title: nil,
            segments: result.segments,
            assetManifest: result.manifest,
            diagnostics: result.diagnostics
        )
        XCTAssertEqual(
            content.renderedText(),
            "Before\n\nFirst alt\n\nBetween\n\nSecond alt\n\nAfter"
        )
        XCTAssertNotNil(imageReferences(in: result)[0].source)
        XCTAssertNil(imageReferences(in: result)[1].source)
        XCTAssertTrue(result.diagnostics.contains { $0.kind == .imageLimitReached })
    }

    func testMalformedAndUnsupportedInlineDataAreSoftFailures() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try HTMLAssetResolver.resolve(
            [
                image(0, alt: "Malformed", attributes: ["src": "data:image/png;base64,%%%"]),
                image(1, alt: "Vector", attributes: ["src": "data:image/svg+xml;base64,PHN2Zz4="]),
            ],
            htmlFileURL: root.appendingPathComponent("page.html"),
            options: try options(root: root)
        )
        XCTAssertEqual(imageReferences(in: result).map(\.source), [nil, nil])
        XCTAssertEqual(result.diagnostics.map(\.kind), [.inlineImageMalformed, .unsupportedImageIgnored])
    }
}
