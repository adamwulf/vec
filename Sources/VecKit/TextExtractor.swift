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
    private let textExtraction: TextExtractionMode

    /// Construct with any `TextSplitter`. Callers pass the splitter from
    /// the active `IndexingProfile` so chunk sizing honors the recorded
    /// profile rather than a hardcoded default.
    public init(splitter: TextSplitter, textExtraction: TextExtractionMode = .raw) {
        self.splitter = splitter
        self.textExtraction = textExtraction
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
            return try extractFromPDF(file)
        }

        // Only route to image OCR if the file is an image but NOT also text.
        // SVG files conform to both .text and .image — their XML content is more
        // useful than OCR output, so we prefer the text extraction path.
        if utType?.conforms(to: .image) == true && utType?.conforms(to: .text) != true {
            return ExtractionResult(chunks: try extractFromImage(file), linePageCount: nil)
        }

        // Open-as-Data throws on real read errors (permission denied, IO
        // failure, missing file). Those propagate up to the pipeline's
        // catch arm, which records the file as `.skippedUnreadable`
        // *without* marking it indexed — so the next run retries.
        // A successful read whose bytes aren't valid UTF-8 is a "no
        // extractable text" case (binary masquerading as text, etc.):
        // return empty chunks so the file still gets a completion
        // record and stops re-processing on every run.
        let data = try Data(contentsOf: file.url)
        guard let content = String(data: data, encoding: .utf8) else {
            return ExtractionResult(chunks: [], linePageCount: nil)
        }

        if (textExtraction == .vttV1 || textExtraction == .markdownV1VttV1),
           file.fileExtension.lowercased() == "vtt" {
            return extractVTT(content)
        }

        let lineCount = countLines(in: content)
        // Markdown normalization keeps each source newline in place. The
        // splitter therefore reports original-file line numbers even though
        // link destinations and presentation markup are omitted from embeddings.
        let text: String
        if (textExtraction == .markdownV1 || textExtraction == .markdownV1VttV1),
           ["md", "markdown"].contains(file.fileExtension.lowercased()) {
            text = MarkdownTextNormalizer.normalize(content)
        } else {
            text = content
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ExtractionResult(chunks: [], linePageCount: lineCount)
        }

        var chunks: [TextChunk] = []

        chunks.append(TextChunk(text: trimmed, type: .whole))

        chunks.append(contentsOf: splitter.split(text))

        return ExtractionResult(chunks: chunks, linePageCount: lineCount)
    }

    private func extractVTT(_ content: String) -> ExtractionResult {
        let document = VTTTextNormalizer.document(content)
        let text = document.text
        guard !text.isEmpty else {
            return ExtractionResult(chunks: [], linePageCount: document.lineCount)
        }
        let chunks = [TextChunk(text: text, type: .whole)] + splitter.split(text).map { chunk in
            let (start, end) = document.sourceLines(start: chunk.lineStart, end: chunk.lineEnd)
            return TextChunk(text: chunk.text, type: chunk.type, lineStart: start,
                             lineEnd: end, pageNumber: chunk.pageNumber)
        }
        return ExtractionResult(chunks: chunks, linePageCount: document.lineCount)
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

    private func extractFromPDF(_ file: FileInfo) throws -> ExtractionResult {
        // Same split as the text path: read failure throws (so the
        // pipeline retries), parse failure returns empty (file is
        // readable but PDFKit can't make sense of it).
        let data = try Data(contentsOf: file.url)
        guard let document = PDFDocument(data: data) else {
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

    private func extractFromImage(_ file: FileInfo) throws -> [TextChunk] {
        // Read failure throws (so the pipeline retries on the next
        // run); Vision recognition failure on readable bytes returns
        // an empty chunk list (no OCR text found).
        let data = try Data(contentsOf: file.url)
        let requestHandler = VNImageRequestHandler(data: data)

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
