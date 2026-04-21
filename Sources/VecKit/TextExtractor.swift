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

    private let splitter: TextSplitter

    /// Construct with any `TextSplitter`. Callers pass the splitter from
    /// the active `IndexingProfile` so chunk sizing honors the recorded
    /// profile rather than a hardcoded default.
    public init(splitter: TextSplitter) {
        self.splitter = splitter
    }

    /// Convenience init that borrows the default built-in profile's
    /// splitter. Tests and pipeline-agnostic callers use this when they
    /// don't have a profile on hand but need sensible chunk defaults.
    public convenience init() {
        // The default alias is always present in the built-in table
        // (covered by IndexingProfileTests); try! is safe.
        let builtIn = try! IndexingProfileFactory.builtIn(forAlias: IndexingProfileFactory.defaultAlias)
        self.init(splitter: RecursiveCharacterSplitter(
            chunkSize: builtIn.defaultChunkSize,
            chunkOverlap: builtIn.defaultChunkOverlap
        ))
    }

    /// Convenience init for the legacy line-based splitter, kept so existing
    /// call sites and tests that pass `chunkSize:overlapSize:` keep working.
    public convenience init(chunkSize: Int, overlapSize: Int) {
        self.init(splitter: LineBasedSplitter(chunkSize: chunkSize, overlapSize: overlapSize))
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

        chunks.append(TextChunk(text: trimmed, type: .whole))

        chunks.append(contentsOf: splitter.split(content))

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

        let trimmedAll = allText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAll.isEmpty {
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
