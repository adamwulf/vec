import XCTest
import VecKit

final class ImageOCRScannerTests: XCTestCase {
    func testDiscoveryRequiresOCRInEveryCombination() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Deliberately text-like bytes prove excluded images cannot leak in
        // through the scanners fallback text sniffing. Decoding is tested by
        // ImageOCRTests; discovery should not decode 325k files up front.
        let extensions = ["jpeg", "jpg", "png", "webp", "gif", "heic", "tiff", "tif", "bmp", "avif", "svg", "svgz"]
        for ext in extensions {
            try Data("visible text".utf8).write(to: root.appendingPathComponent("sample.\(ext)"))
        }
        for name in ["notes.md", "captions.vtt", "plain.txt"] {
            try Data("visible text".utf8).write(to: root.appendingPathComponent(name))
        }
        try Data("uppercase".utf8).write(to: root.appendingPathComponent("UPPER.JPG"))
        for mode in TextExtractionMode.allCases {
            let paths = Set(try FileScanner(directory: root, respectsGitignore: false,
                                            textExtraction: mode).scan().map(\.relativePath))
            XCTAssertTrue(paths.isSuperset(of: ["notes.md", "captions.vtt", "plain.txt"]))
            for ext in extensions {
                XCTAssertEqual(paths.contains("sample.\(ext)"),
                               mode.includesImageOCR && ImageOCR.supportedExtensions.contains(ext),
                               "\(mode.rawValue), extension \(ext)")
            }
            XCTAssertEqual(paths.contains("UPPER.JPG"), mode.includesImageOCR)
            XCTAssertFalse(paths.contains("sample.svg"))
        }
    }

    func testIgnoreRulesStillApplyToImages() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["keep.png", "ignore.jpg", ".hidden.png"] {
            try Data([0]).write(to: root.appendingPathComponent(name))
        }
        try Data("*.jpg".utf8).write(to: root.appendingPathComponent(".vecignore"))
        let paths = try FileScanner(directory: root, respectsGitignore: false,
                                    textExtraction: .imageOCRV1).scan().map(\.relativePath)
        XCTAssertEqual(paths, ["keep.png"])
    }
}
