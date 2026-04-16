import Foundation
import PDFKit

/// Extracts text content from files and splits into chunks for embedding.
public class TextExtractor {

    /// Default chunk size in lines for markdown files.
    public static let defaultChunkSize = 50
    /// Default number of overlapping lines between consecutive chunks.
    public static let defaultOverlapSize = 10

    private let chunkSize: Int
    private let overlapSize: Int

    public init(chunkSize: Int = TextExtractor.defaultChunkSize, overlapSize: Int = TextExtractor.defaultOverlapSize) {
        self.chunkSize = chunkSize
        self.overlapSize = overlapSize
    }

    /// Extract text chunks from a file, ready for embedding.
    public func extract(from file: FileInfo) throws -> [TextChunk] {
        if file.fileExtension == "pdf" {
            return extractFromPDF(file)
        }

        guard let content = try? String(contentsOf: file.url, encoding: .utf8) else {
            return []
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var chunks: [TextChunk] = []

        // Always add a whole-document embedding
        chunks.append(TextChunk(text: trimmed, type: .whole))

        // For markdown files, also create overlapping line-based chunks
        if file.fileExtension == "md" {
            let lineChunks = chunkMarkdown(content)
            chunks.append(contentsOf: lineChunks)
        }

        return chunks
    }

    // MARK: - Markdown Chunking

    private func chunkMarkdown(_ content: String) -> [TextChunk] {
        let lines = content.components(separatedBy: .newlines)

        guard lines.count > chunkSize else {
            // File is small enough to be a single chunk, whole-document embedding is sufficient
            return []
        }

        var chunks: [TextChunk] = []
        var start = 0

        while start < lines.count {
            var end = min(start + chunkSize, lines.count)

            // Try to find a heading boundary near the end to split cleanly
            if end < lines.count {
                let searchStart = max(start + chunkSize - 10, start)
                for i in stride(from: end, through: searchStart, by: -1) {
                    if i < lines.count && lines[i].hasPrefix("#") {
                        end = i
                        break
                    }
                }
            }

            let chunkLines = Array(lines[start..<end])
            let text = chunkLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

            if !text.isEmpty {
                chunks.append(TextChunk(
                    text: text,
                    type: .chunk,
                    lineStart: start + 1,  // 1-based line numbers
                    lineEnd: end
                ))
            }

            // Advance by chunkSize minus overlap
            let advance = max(chunkSize - overlapSize, 1)
            start += advance
        }

        return chunks
    }

    // MARK: - PDF Extraction

    private func extractFromPDF(_ file: FileInfo) -> [TextChunk] {
        guard let document = PDFDocument(url: file.url) else { return [] }

        var chunks: [TextChunk] = []
        var allText = ""

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            guard let text = page.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            chunks.append(TextChunk(
                text: text,
                type: .pdfPage,
                pageNumber: pageIndex + 1  // 1-based page numbers
            ))

            allText += text + "\n"
        }

        // Add whole-document embedding if we extracted any text
        let trimmedAll = allText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAll.isEmpty {
            chunks.insert(TextChunk(text: trimmedAll, type: .whole), at: 0)
        }

        return chunks
    }
}
