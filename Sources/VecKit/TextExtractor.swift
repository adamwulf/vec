import Foundation
import PDFKit
import UniformTypeIdentifiers
import Vision

/// Result of extracting from a file: the chunks to embed plus a count of
/// the file's logical "size unit" — lines for text files, pages for PDFs,
/// nil for images / unknown file kinds.
public struct ExtractionResult: Sendable {
    public let chunks: [TextChunk]
    public let linePageCount: Int?

    public init(chunks: [TextChunk], linePageCount: Int?) {
        self.chunks = chunks
        self.linePageCount = linePageCount
    }
}

/// Extracts text content from files and splits into chunks for embedding.
/// Thread-safe: all stored properties are immutable after init.
public final class TextExtractor: @unchecked Sendable {

    /// Default chunk size in lines for text files.
    public static let defaultChunkSize = 30
    /// Default number of overlapping lines between consecutive chunks.
    public static let defaultOverlapSize = 8

    private let chunkSize: Int
    private let overlapSize: Int

    public init(chunkSize: Int = TextExtractor.defaultChunkSize, overlapSize: Int = TextExtractor.defaultOverlapSize) {
        self.chunkSize = chunkSize
        self.overlapSize = overlapSize
    }

    /// Extract text chunks from a file, along with a line (or page) count
    /// for the file.
    public func extract(from file: FileInfo) throws -> ExtractionResult {
        let utType = UTType(filenameExtension: file.fileExtension)

        if utType?.conforms(to: .pdf) == true {
            return extractFromPDF(file)
        }

        // Only route to image OCR if the file is an image but NOT also text.
        // SVG files conform to both .text and .image — their XML content is more
        // useful than OCR output, so we prefer the text extraction path.
        if utType?.conforms(to: .image) == true && utType?.conforms(to: .text) != true {
            return ExtractionResult(chunks: extractFromImage(file), linePageCount: nil)
        }

        guard let content = try? String(contentsOf: file.url, encoding: .utf8) else {
            return ExtractionResult(chunks: [], linePageCount: nil)
        }

        let lineCount = countLines(in: content)
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ExtractionResult(chunks: [], linePageCount: lineCount)
        }

        var chunks: [TextChunk] = []

        // Only add a whole-document embedding when the full text fits inside
        // the embedding limit. Otherwise NLEmbedding would silently truncate
        // to the first ~10 KB and produce a misleading "whole" vector.
        if trimmed.count <= EmbeddingService.maxEmbeddingTextLength {
            chunks.append(TextChunk(text: trimmed, type: .whole))
        }

        // Create overlapping line-based chunks for all text files
        let lineChunks = chunkText(content)
        chunks.append(contentsOf: lineChunks)

        return ExtractionResult(chunks: chunks, linePageCount: lineCount)
    }

    /// Counts newlines and adds 1 if the content is non-empty and doesn't
    /// end with a newline (so a 3-line file without trailing newline reports 3).
    private func countLines(in content: String) -> Int {
        if content.isEmpty { return 0 }
        var newlines = 0
        for scalar in content.unicodeScalars where scalar == "\n" {
            newlines += 1
        }
        return content.last == "\n" ? newlines : newlines + 1
    }

    // MARK: - Text Chunking

    private func chunkText(_ content: String) -> [TextChunk] {
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

    private func extractFromPDF(_ file: FileInfo) -> ExtractionResult {
        guard let document = PDFDocument(url: file.url) else {
            return ExtractionResult(chunks: [], linePageCount: nil)
        }

        var chunks: [TextChunk] = []
        var allText = ""
        let pageCount = document.pageCount

        for pageIndex in 0..<pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            guard let text = page.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            chunks.append(TextChunk(
                text: text,
                type: .pdfPage,
                pageNumber: pageIndex + 1  // 1-based page numbers
            ))

            allText += text + "\n"
        }

        // Add whole-document embedding only if the concatenated text fits
        // inside the embedding limit. See `extract(from:)` for the reasoning.
        let trimmedAll = allText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAll.isEmpty && trimmedAll.count <= EmbeddingService.maxEmbeddingTextLength {
            chunks.insert(TextChunk(text: trimmedAll, type: .whole), at: 0)
        }

        return ExtractionResult(chunks: chunks, linePageCount: pageCount)
    }

    // MARK: - Image OCR Extraction

    private func extractFromImage(_ file: FileInfo) -> [TextChunk] {
        let requestHandler = VNImageRequestHandler(url: file.url)

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en"]
        request.usesLanguageCorrection = true

        do {
            try requestHandler.perform([request])
        } catch {
            return []
        }

        guard let observations = request.results else { return [] }

        let recognizedStrings = observations.compactMap { observation in
            observation.topCandidates(1).first?.string
        }

        guard !recognizedStrings.isEmpty else { return [] }

        let fullText = recognizedStrings.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !fullText.isEmpty else { return [] }

        return [TextChunk(text: fullText, type: .image)]
    }
}
