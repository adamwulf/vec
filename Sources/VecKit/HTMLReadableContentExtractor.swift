import Foundation
import SwiftSoup

/// Local, versioned HTML readable-content extraction.
///
/// The implementation is intentionally structural rather than a claim of
/// Mozilla Readability compatibility. It honors explicit single `<main>` or
/// `<article>` containers, then falls back to the cleaned visible page. If
/// cleanup would erase the page entirely (for example, a navigation-only
/// directory), a preservation fallback removes only executable/embedded
/// elements so non-article pages do not silently disappear.
public enum HTMLReadableContentExtractor {
    public static let version = 1

    public static func extract(
        _ html: String,
        sourceURL: URL,
        options: HTMLExtractionOptions
    ) throws -> HTMLReadableContent {
        guard sourceURL.isFileURL else {
            throw HTMLExtractionError.nonFileSourceURL(sourceURL)
        }
        let inputBytes = html.utf8.count
        guard inputBytes <= options.maximumInputBytes else {
            throw HTMLExtractionError.inputTooLarge(
                actualBytes: inputBytes,
                maximumBytes: options.maximumInputBytes
            )
        }

        // SwiftSoup parses strings without a resource loader: base URI is
        // retained only for DOM URL semantics and nothing is dereferenced.
        let document = try SwiftSoup.parse(html, sourceURL.absoluteString)
        guard let body = document.body() else {
            return HTMLReadableContent(
                strategyIdentifier: "empty-page-v1",
                extractorVersion: Self.version,
                title: nil,
                segments: []
            )
        }
        let elementCount = try body.getAllElements().size()
        guard elementCount <= options.maximumElementCount else {
            throw HTMLExtractionError.elementLimitExceeded(
                actual: elementCount,
                maximum: options.maximumElementCount
            )
        }

        let title = normalizedTitle(try document.title())
        let selection = try selectAndRender(
            document: document,
            body: body,
            baseURI: sourceURL.absoluteString,
            maximumElementCount: options.maximumElementCount,
            retainImageOnlyContent: options.ocrAssets != nil
        )
        guard isMeaningful(selection.result, retainImageOnlyContent: options.ocrAssets != nil) else {
            return HTMLReadableContent(
                strategyIdentifier: selection.strategyIdentifier,
                extractorVersion: Self.version,
                title: title,
                segments: []
            )
        }

        let titledSegments = HTMLStructuralRenderer.applyingTitle(
            title,
            to: selection.result.segments
        )
        let assets = try HTMLAssetResolver.resolve(
            titledSegments,
            htmlFileURL: sourceURL,
            options: options.ocrAssets
        )
        return HTMLReadableContent(
            strategyIdentifier: selection.strategyIdentifier,
            extractorVersion: Self.version,
            title: title,
            segments: assets.segments,
            assetManifest: assets.manifest,
            diagnostics: assets.diagnostics
        )
    }

    /// Re-evaluates the same bounded selection and source policy used by
    /// extraction and returns the manifest shared update categorization must
    /// compare before treating unchanged HTML bytes as an unchanged result.
    /// Nil means OCR assets were not enabled and no referenced-asset I/O ran.
    public static func discoverDependencies(
        _ html: String,
        sourceURL: URL,
        options: HTMLExtractionOptions
    ) throws -> HTMLAssetManifest? {
        try extract(html, sourceURL: sourceURL, options: options).assetManifest
    }

    // MARK: - Selection

    private struct Selection {
        let strategyIdentifier: String
        let result: HTMLStructuralRenderResult
    }

    private static func selectAndRender(
        document: Document,
        body: Element,
        baseURI: String,
        maximumElementCount: Int,
        retainImageOnlyContent: Bool
    ) throws -> Selection {
        let mains = try document.select("main").array()
        if mains.count == 1 {
            let rendered = try render(
                mains[0],
                baseURI: baseURI,
                cleanupMode: .visiblePageFallback,
                maximumElementCount: maximumElementCount
            )
            if isMeaningful(rendered, retainImageOnlyContent: retainImageOnlyContent) {
                return Selection(strategyIdentifier: "semantic-main-v1", result: rendered)
            }
        }

        let roleMains = try document.select("[role]").array().filter { element in
            let role = (try? element.attr("role")) ?? ""
            return role.split(whereSeparator: \.isWhitespace)
                .contains { $0.lowercased() == "main" }
        }
        if mains.isEmpty, roleMains.count == 1 {
            let rendered = try render(
                roleMains[0],
                baseURI: baseURI,
                cleanupMode: .visiblePageFallback,
                maximumElementCount: maximumElementCount
            )
            if isMeaningful(rendered, retainImageOnlyContent: retainImageOnlyContent) {
                return Selection(strategyIdentifier: "semantic-role-main-v1", result: rendered)
            }
        }

        let articles = try document.select("article").array()
        if mains.isEmpty, roleMains.isEmpty, articles.count == 1 {
            let rendered = try render(
                articles[0],
                baseURI: baseURI,
                cleanupMode: .visiblePageFallback,
                maximumElementCount: maximumElementCount
            )
            if isMeaningful(rendered, retainImageOnlyContent: retainImageOnlyContent) {
                return Selection(strategyIdentifier: "semantic-article-v1", result: rendered)
            }
        }

        let cleanedPage = try render(
            body,
            baseURI: baseURI,
            cleanupMode: .visiblePageFallback,
            maximumElementCount: maximumElementCount
        )
        if isMeaningful(cleanedPage, retainImageOnlyContent: retainImageOnlyContent) {
            return Selection(strategyIdentifier: "visible-page-v1", result: cleanedPage)
        }

        let preservedPage = try render(
            body,
            baseURI: baseURI,
            cleanupMode: .selectedArticle,
            maximumElementCount: maximumElementCount
        )
        return Selection(strategyIdentifier: "preserving-page-v1", result: preservedPage)
    }

    private static func render(
        _ element: Element,
        baseURI: String,
        cleanupMode: HTMLDOMCleanupMode,
        maximumElementCount: Int
    ) throws -> HTMLStructuralRenderResult {
        try HTMLStructuralRenderer.render(
            try element.html(),
            baseURI: baseURI,
            title: nil,
            cleanupMode: cleanupMode,
            maximumElementCount: maximumElementCount
        )
    }

    private static func isMeaningful(
        _ result: HTMLStructuralRenderResult,
        retainImageOnlyContent: Bool
    ) -> Bool {
        result.segments.contains { segment in
            switch segment {
            case .text(let text):
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .image(let image):
                retainImageOnlyContent || !(image.altText ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
    }

    private static func normalizedTitle(_ title: String) -> String? {
        let normalized = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }
}
