import XCTest
@testable import VecKit

final class HTMLExtractionTypesTests: XCTestCase {
    private enum ProbeError: Error {
        case expected
    }

    func testPlainHTMLOptionsDoNotEnableAssetCollection() throws {
        let options = try HTMLExtractionOptions(
            maximumInputBytes: 1_024,
            maximumElementCount: 100
        )
        XCTAssertNil(options.ocrAssets)
        XCTAssertThrowsError(
            try HTMLExtractionOptions(maximumInputBytes: 0, maximumElementCount: 100)
        )
        XCTAssertThrowsError(
            try HTMLExtractionOptions(maximumInputBytes: 1_024, maximumElementCount: -1)
        )
    }

    func testRenderedTextKeepsDOMOrderAndOnlyDeduplicatesEquivalentAltAndOCR() throws {
        let manifest = try HTMLAssetManifest(policyVersion: 1, entries: [])
        let content = HTMLReadableContent(
            strategyIdentifier: "fixture",
            extractorVersion: 1,
            title: "Title",
            segments: [
                .text("# Title"),
                .image(HTMLImageReference(
                    ordinal: 0,
                    altText: "System diagram",
                    source: nil,
                    contentDigest: nil
                )),
                .text("Explanation after the diagram."),
                .image(HTMLImageReference(
                    ordinal: 1,
                    altText: "Measured chart",
                    source: nil,
                    contentDigest: nil
                )),
            ],
            assetManifest: manifest
        )

        XCTAssertEqual(
            content.renderedText(),
            "# Title\n\nSystem diagram\n\nExplanation after the diagram.\n\nMeasured chart"
        )
        XCTAssertEqual(
            content.renderedText(ocrTextByImageOrdinal: [
                0: "  SYSTEM   DIAGRAM ",
                1: "Revenue rose by 12 percent.",
            ]),
            "# Title\n\nSystem diagram\n\nExplanation after the diagram.\n\nMeasured chart\nRevenue rose by 12 percent."
        )
    }

    func testInlineImageMaterializationIsScopedAcrossSuccessAndThrow() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data([0x01, 0x02, 0x03, 0x04])
        let image = HTMLImageReference(
            ordinal: 0,
            altText: nil,
            source: .inlineData(format: .png, data: bytes),
            contentDigest: "fixture"
        )

        var successURL: URL?
        let result = try image.withMaterializedURL(in: root) { url -> Int in
            successURL = url
            XCTAssertEqual(url.pathExtension, "png")
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            return bytes.count
        }
        XCTAssertEqual(result, bytes.count)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(successURL).path))

        var throwURL: URL?
        XCTAssertThrowsError(try image.withMaterializedURL(in: root) { url -> Void in
            throwURL = url
            throw ProbeError.expected
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(throwURL).path))
    }

    func testLocalImagePassesThroughWithoutTemporaryCopy() throws {
        let url = URL(fileURLWithPath: "/tmp/fixture.png")
        let image = HTMLImageReference(
            ordinal: 3,
            altText: "fixture",
            source: .localFile(url),
            contentDigest: "digest"
        )
        let observed = try image.withMaterializedURL(
            in: URL(fileURLWithPath: "/tmp/unused-html-assets")
        ) { $0 }
        XCTAssertEqual(observed, url)
    }

    func testManifestDigestIsStableSensitiveAndValidatedWhenDecoded() throws {
        let firstEntries = [
            HTMLAssetManifest.Entry(
                ordinal: 0,
                relativePath: "page_files/chart.png",
                state: .present,
                byteCount: 4,
                sha256: "aaaa"
            ),
            HTMLAssetManifest.Entry(
                ordinal: 1,
                relativePath: "page_files/missing.jpg",
                state: .missing
            ),
        ]
        let first = try HTMLAssetManifest(policyVersion: 1, entries: firstEntries)
        let same = try HTMLAssetManifest(policyVersion: 1, entries: firstEntries)
        XCTAssertEqual(first.digest, same.digest)

        let changed = try HTMLAssetManifest(policyVersion: 1, entries: [
            HTMLAssetManifest.Entry(
                ordinal: 0,
                relativePath: "page_files/chart.png",
                state: .present,
                byteCount: 4,
                sha256: "bbbb"
            ),
            firstEntries[1],
        ])
        XCTAssertNotEqual(first.digest, changed.digest)

        let reordered = try HTMLAssetManifest(
            policyVersion: 1,
            entries: Array(firstEntries.reversed())
        )
        XCTAssertNotEqual(first.digest, reordered.digest)

        let encoded = try JSONEncoder().encode(first)
        XCTAssertEqual(try JSONDecoder().decode(HTMLAssetManifest.self, from: encoded), first)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["digest"] = "tampered"
        let tampered = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(HTMLAssetManifest.self, from: tampered))
    }

    func testInlineRasterMIMETypesAreExplicitAndSVGIsRejected() {
        XCTAssertEqual(HTMLInlineRasterFormat(mimeType: "IMAGE/JPEG"), .jpeg)
        XCTAssertEqual(HTMLInlineRasterFormat(mimeType: "image/x-ms-bmp"), .bmp)
        XCTAssertNil(HTMLInlineRasterFormat(mimeType: "image/svg+xml"))
        XCTAssertNil(HTMLInlineRasterFormat(mimeType: "text/html"))
    }

    func testOCRAssetPolicyRequiresCurrentVersion() throws {
        let root = FileManager.default.temporaryDirectory
        XCTAssertNoThrow(try HTMLOCRAssetOptions(
            policyVersion: HTMLOCRAssetOptions.currentPolicyVersion,
            allowedAssetRoot: root,
            temporaryAssetDirectory: root,
            maximumImages: 1,
            maximumLocalImageBytes: 1,
            maximumInlineImageBytes: 1,
            maximumTotalInlineImageBytes: 1
        ))
        XCTAssertThrowsError(try HTMLOCRAssetOptions(
            policyVersion: HTMLOCRAssetOptions.currentPolicyVersion + 1,
            allowedAssetRoot: root,
            temporaryAssetDirectory: root,
            maximumImages: 1,
            maximumLocalImageBytes: 1,
            maximumInlineImageBytes: 1,
            maximumTotalInlineImageBytes: 1
        )) { error in
            XCTAssertEqual(
                error as? HTMLExtractionError,
                .unsupportedAssetPolicyVersion(HTMLOCRAssetOptions.currentPolicyVersion + 1)
            )
        }
        XCTAssertThrowsError(try HTMLOCRAssetOptions(
            policyVersion: HTMLOCRAssetOptions.currentPolicyVersion,
            allowedAssetRoot: URL(string: "https://example.invalid/assets")!,
            temporaryAssetDirectory: root,
            maximumImages: 1,
            maximumLocalImageBytes: 1,
            maximumInlineImageBytes: 1,
            maximumTotalInlineImageBytes: 1
        ))
    }
}
