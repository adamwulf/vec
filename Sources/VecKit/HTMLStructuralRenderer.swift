import Foundation
import SwiftSoup

/// Cleanup intensity applied before structural rendering. Article HTML from a
/// content selector should already be focused; the fallback additionally
/// removes static page chrome while preserving ordinary links, lists, tables,
/// headings, and footer text.
enum HTMLDOMCleanupMode: Sendable, Equatable {
    case selectedArticle
    case visiblePageFallback
}

enum HTMLStructuralSegment: Sendable, Equatable {
    case text(String)
    case image(HTMLStructuralImage)
}

struct HTMLStructuralImage: Sendable, Equatable {
    let ordinal: Int
    let altText: String?
    /// Raw static attributes only. Resolution and I/O belong to the optional
    /// OCR asset phase, so plain `html-v1` never dereferences them.
    let sourceAttributes: [String: String]
}

struct HTMLStructuralRenderResult: Sendable, Equatable {
    let segments: [HTMLStructuralSegment]
    let elementCount: Int
}

/// Deterministic, Markdown-like rendering of a selected HTML fragment.
///
/// The renderer intentionally does not select the main article and never
/// resolves a URL. Both a future Readability adapter and the full-page
/// fallback feed their chosen, bounded HTML through this one renderer so
/// headings/lists/tables/entities cannot diverge between strategies.
enum HTMLStructuralRenderer {
    static func render(
        _ html: String,
        baseURI: String,
        title: String?,
        cleanupMode: HTMLDOMCleanupMode,
        maximumElementCount: Int
    ) throws -> HTMLStructuralRenderResult {
        let document = try SwiftSoup.parseBodyFragment(html, baseURI)
        guard let body = document.body() else {
            return HTMLStructuralRenderResult(segments: [], elementCount: 0)
        }

        let elementCount = body.getAllElements().size()
        guard elementCount <= maximumElementCount else {
            throw HTMLExtractionError.elementLimitExceeded(
                actual: elementCount,
                maximum: maximumElementCount
            )
        }

        try clean(body, mode: cleanupMode)

        var renderer = Renderer()
        try renderer.renderChildren(of: body, context: Context())
        var segments = renderer.finish()

        let cleanTitle = collapseWhitespace(title ?? "")
        if !cleanTitle.isEmpty, !firstHeading(in: segments, matches: cleanTitle) {
            segments.insert(.text("# \(cleanTitle)"), at: 0)
        }
        return HTMLStructuralRenderResult(segments: segments, elementCount: elementCount)
    }

    // MARK: - Static DOM cleanup

    private static let alwaysRemovedSelector = [
        "script", "style", "noscript", "template", "iframe", "frame",
        "object", "embed", "canvas", "audio", "video", "svg", "math",
        "link", "meta", "dialog", "[hidden]",
    ].joined(separator: ",")

    private static let fallbackRemovedSelector = [
        "nav", "form", "button", "input", "select", "textarea", "option",
    ].joined(separator: ",")

    private static func clean(_ root: Element, mode: HTMLDOMCleanupMode) throws {
        try root.select(alwaysRemovedSelector).remove()
        if mode == .visiblePageFallback {
            try root.select(fallbackRemovedSelector).remove()
        }

        // Static HTML has no computed style or layout. Recognize only explicit
        // inline declarations whose hidden meaning is unambiguous and fail
        // open on malformed or unfamiliar CSS so prose is not guessed away.
        let fallbackRoles: Set<String> = [
            "navigation", "button", "menu", "menubar", "toolbar", "tab",
            "tablist", "dialog", "alertdialog", "search", "tooltip",
        ]
        for element in root.getAllElements().array() {
            let ariaHidden = try element.attr("aria-hidden")
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let style = try element.attr("style")
            let roleTokens = try element.attr("role").lowercased()
                .split(whereSeparator: \.isWhitespace).map(String.init)
            if ariaHidden == "true" || hasHiddenInlineStyle(style) ||
                (mode == .visiblePageFallback && !fallbackRoles.isDisjoint(with: roleTokens)) {
                try element.remove()
            }
        }
    }

    private static func hasHiddenInlineStyle(_ style: String) -> Bool {
        for declaration in style.split(separator: ";", omittingEmptySubsequences: true) {
            let pieces = declaration.split(separator: ":", maxSplits: 1)
            guard pieces.count == 2 else { continue }
            let name = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased().replacingOccurrences(of: "!important", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if name == "display", value == "none" { return true }
            if name == "visibility", value == "hidden" || value == "collapse" { return true }
        }
        return false
    }

    // MARK: - Renderer

    private struct Context {
        var listDepth = 0
        var insideListItem = false
        var preserveWhitespace = false
    }

    private struct Renderer {
        var segments: [HTMLStructuralSegment] = []
        var buffer = ""
        var nextImageOrdinal = 0

        mutating func finish() -> [HTMLStructuralSegment] {
            flushText()
            return segments
        }

        mutating func renderChildren(of node: Node, context: Context) throws {
            for child in node.getChildNodes() {
                try render(child, context: context)
            }
        }

        mutating func render(_ node: Node, context: Context) throws {
            if let textNode = node as? TextNode {
                if context.preserveWhitespace {
                    appendLiteral(textNode.getWholeText())
                } else {
                    appendInline(HTMLStructuralRenderer.collapseWhitespace(textNode.getWholeText()))
                }
                return
            }
            guard let element = node as? Element else { return }
            let tag = element.tagName().lowercased()

            switch tag {
            case "script", "style", "noscript", "template", "iframe", "frame",
                 "object", "embed", "canvas", "audio", "video", "svg", "math",
                 "link", "meta", "dialog":
                return
            case "br":
                lineBreak()
            case "hr":
                blockBreak()
                appendLiteral("---")
                blockBreak()
            case "h1", "h2", "h3", "h4", "h5", "h6":
                blockBreak()
                let level = Int(String(tag.dropFirst())) ?? 1
                appendLiteral(String(repeating: "#", count: level) + " ")
                try renderChildren(of: element, context: context)
                blockBreak()
            case "p", "div", "section", "article", "main", "header", "footer",
                 "aside", "address", "figure", "figcaption", "details", "summary":
                if !context.insideListItem { blockBreak() }
                try renderChildren(of: element, context: context)
                if !context.insideListItem { blockBreak() }
            case "blockquote":
                blockBreak()
                let text = try element.text()
                for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                    appendLiteral("> " + line.trimmingCharacters(in: .whitespacesAndNewlines))
                    lineBreak()
                }
                blockBreak()
            case "pre":
                blockBreak()
                appendLiteral("```\n")
                appendLiteral(try element.text(trimAndNormaliseWhitespace: false)
                    .trimmingCharacters(in: .newlines))
                appendLiteral("\n```")
                blockBreak()
            case "ul":
                try renderList(element, ordered: false, context: context)
            case "ol":
                try renderList(element, ordered: true, context: context)
            case "li":
                // Normally owned by renderList. This fallback preserves a
                // malformed/orphan list item instead of dropping it.
                blockBreak()
                appendLiteral("- ")
                var itemContext = context
                itemContext.insideListItem = true
                try renderChildren(of: element, context: itemContext)
                lineBreak()
            case "table":
                try renderTable(element, context: context)
            case "img":
                try renderImage(element)
            default:
                try renderChildren(of: element, context: context)
            }
        }

        mutating func renderList(_ list: Element, ordered: Bool, context: Context) throws {
            blockBreak()
            let start = ordered ? max(1, Int(try list.attr("start")) ?? 1) : 1
            var itemNumber = start
            for child in list.getChildNodes() {
                guard let item = child as? Element, item.tagName().lowercased() == "li" else {
                    continue
                }
                appendLiteral(String(repeating: "  ", count: context.listDepth))
                appendLiteral(ordered ? "\(itemNumber). " : "- ")
                var itemContext = context
                itemContext.listDepth += 1
                itemContext.insideListItem = true
                for itemChild in item.getChildNodes() {
                    if let nested = itemChild as? Element {
                        let nestedTag = nested.tagName().lowercased()
                        if nestedTag == "ul" || nestedTag == "ol" {
                            lineBreak()
                            try renderList(nested, ordered: nestedTag == "ol", context: itemContext)
                            continue
                        }
                    }
                    try render(itemChild, context: itemContext)
                }
                lineBreak()
                itemNumber += 1
            }
            blockBreak()
        }

        mutating func renderTable(_ table: Element, context: Context) throws {
            blockBreak()
            let rows = try table.select("tr").array()
            for (rowIndex, row) in rows.enumerated() {
                let cells = row.children().array().filter {
                    let name = $0.tagName().lowercased()
                    return name == "th" || name == "td"
                }
                guard !cells.isEmpty else { continue }
                appendLiteral("| ")
                for cell in cells {
                    try renderChildren(of: cell, context: context)
                    appendLiteral(" | ")
                }
                lineBreak()
                if rowIndex == 0, cells.contains(where: { $0.tagName().lowercased() == "th" }) {
                    appendLiteral("| " + Array(repeating: "---", count: cells.count).joined(separator: " | ") + " |")
                    lineBreak()
                }
            }
            blockBreak()
        }

        mutating func renderImage(_ image: Element) throws {
            let alt = HTMLStructuralRenderer.collapseWhitespace(try image.attr("alt"))
            let names = ["src", "srcset", "data-src", "data-srcset", "data-original", "data-lazy-src"]
            var attributes: [String: String] = [:]
            for name in names where image.hasAttr(name) {
                let value = try image.attr(name).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { attributes[name] = value }
            }

            flushText()
            segments.append(.image(HTMLStructuralImage(
                ordinal: nextImageOrdinal,
                altText: alt.isEmpty ? nil : alt,
                sourceAttributes: attributes
            )))
            nextImageOrdinal += 1
        }

        mutating func appendInline(_ text: String) {
            guard !text.isEmpty else { return }
            if let last = buffer.last, !last.isWhitespace,
               let first = text.first,
               !Self.noLeadingSpacePunctuation.contains(first),
               !Self.openingPunctuation.contains(last) {
                buffer.append(" ")
            }
            buffer.append(text)
        }

        mutating func appendLiteral(_ text: String) {
            buffer.append(text)
        }

        mutating func lineBreak() {
            trimTrailingHorizontalWhitespace()
            if !buffer.hasSuffix("\n") { buffer.append("\n") }
        }

        mutating func blockBreak() {
            trimTrailingWhitespace()
            if !buffer.isEmpty { buffer.append("\n\n") }
        }

        mutating func flushText() {
            let normalized = HTMLStructuralRenderer.normalizeLayout(buffer)
            if !normalized.isEmpty { segments.append(.text(normalized)) }
            buffer = ""
        }

        mutating func trimTrailingHorizontalWhitespace() {
            while let last = buffer.last, last == " " || last == "\t" {
                buffer.removeLast()
            }
        }

        mutating func trimTrailingWhitespace() {
            while let last = buffer.last, last.isWhitespace {
                buffer.removeLast()
            }
        }

        private static let noLeadingSpacePunctuation: Set<Character> = [
            ".", ",", ";", ":", "!", "?", ")", "]", "}", "%",
        ]
        private static let openingPunctuation: Set<Character> = ["(", "[", "{"]
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func normalizeLayout(_ text: String) -> String {
        let normalizedNewlines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var output: [String] = []
        output.reserveCapacity(normalizedNewlines.count / 32)
        var previousWasBlank = false
        for rawLine in normalizedNewlines.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let isBlank = line.isEmpty
            if isBlank, previousWasBlank { continue }
            output.append(line)
            previousWasBlank = isBlank
        }
        return output.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstHeading(in segments: [HTMLStructuralSegment], matches title: String) -> Bool {
        for segment in segments {
            guard case .text(let text) = segment else { continue }
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let heading = trimmed.drop { $0 == "#" || $0.isWhitespace }
                return collapseWhitespace(String(heading)).compare(
                    title,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    range: nil,
                    locale: Locale(identifier: "en_US_POSIX")
                ) == .orderedSame
            }
        }
        return false
    }
}
