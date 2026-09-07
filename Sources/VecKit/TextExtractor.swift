import Foundation
import PDFKit
import UniformTypeIdentifiers

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
    /// Recognizer used for the image-OCR path. When `ocrCacheDirectory` is
    /// supplied this is an `ImageOCRCache` wrapping the base recognizer;
    /// otherwise it is the base recognizer itself.
    private let ocrRecognizer: ImageTextRecognizer
    /// The cache instance, present only when a cache directory was supplied.
    /// Kept separately so `ocrCacheStatistics` can expose its counters.
    private let ocrCache: ImageOCRCache?

    /// Extensions the extractor treats as image-like even when `UTType` does
    /// not report `.image` (SVGZ has no registered type; AVIF may not on older
    /// runtimes). Kept in sync with `FileScanner`'s image set so the direct
    /// extractor and the scanner agree on which files are images and must
    /// never be read as text.
    private static let imageLikeExtensions: Set<String> = [
        "jpg", "jpeg", "png", "webp", "gif", "heic", "heif",
        "tif", "tiff", "bmp", "avif", "svg", "svgz"
    ]

    /// Construct with any `TextSplitter` and image-OCR recognizer. Callers
    /// pass the splitter from the active `IndexingProfile` so chunk sizing
    /// honors the recorded profile rather than a hardcoded default.
    ///
    /// The recognizer is injectable so tests (and pipeline concurrency
    /// probes) can drive the image path without invoking Vision. When
    /// `ocrCacheDirectory` is non-nil, image OCR is served through a
    /// content-addressed `ImageOCRCache` rooted at that directory (the CLI
    /// passes the per-DB directory), wrapping the injected recognizer.
    public init(splitter: TextSplitter,
                textExtraction: TextExtractionMode = .raw,
                ocrRecognizer baseRecognizer: ImageTextRecognizer,
                ocrCacheDirectory: URL? = nil) {
        self.splitter = splitter
        self.textExtraction = textExtraction
        if let directory = ocrCacheDirectory {
            let cache = ImageOCRCache(directory: directory, recognizer: baseRecognizer)
            self.ocrCache = cache
            self.ocrRecognizer = cache
        } else {
            self.ocrCache = nil
            self.ocrRecognizer = baseRecognizer
        }
    }

    /// Construct with the default Vision-backed OCR engine. This is the main
    /// entry point for the pipeline and CLI; `ocrCacheDirectory` enables the
    /// on-disk OCR cache when supplied.
    public convenience init(splitter: TextSplitter,
                            textExtraction: TextExtractionMode = .raw,
                            ocrCacheDirectory: URL? = nil) {
        self.init(splitter: splitter,
                  textExtraction: textExtraction,
                  ocrRecognizer: ImageOCR(),
                  ocrCacheDirectory: ocrCacheDirectory)
    }

    /// Whether `extract(from:)` will run image OCR on `file`: true only when
    /// the active mode opts into image OCR *and* the file's extension is a
    /// supported raster format. Lets a caller (e.g. the pipeline) route just
    /// the files that will incur OCR cost.
    public func isImageOCRFile(_ file: FileInfo) -> Bool {
        textExtraction.includesImageOCR
            && ImageOCR.supportedExtensions.contains(file.fileExtension.lowercased())
    }

    /// A snapshot of the OCR cache counters, or nil when no cache directory
    /// was configured.
    public var ocrCacheStatistics: ImageOCRCacheStatistics? {
        ocrCache?.statistics
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

        // Image-like files (raster or vector, including SVG which also
        // conforms to `.text`) are handled here and NEVER fall through to the
        // text path. This mirrors the scanner exactly: OCR runs only under an
        // image-OCR mode on a supported raster extension; every other
        // image-like file — SVG/SVGZ, an unsupported raster type such as HEIF,
        // or any image under a non-OCR mode — yields no chunks. Falling
        // through would index SVG's XML or an unsupported image's bytes as
        // apparent text, contradicting the scanner's skip policy and leaking
        // through the direct-insert path.
        let ext = file.fileExtension.lowercased()
        if utType?.conforms(to: .image) == true || Self.imageLikeExtensions.contains(ext) {
            if textExtraction.includesImageOCR && ImageOCR.supportedExtensions.contains(ext) {
                return ExtractionResult(chunks: try extractFromImage(file), linePageCount: nil)
            }
            return ExtractionResult(chunks: [], linePageCount: nil)
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

        // Use the mode predicates, not equality: every combined mode that
        // includes VTT (e.g. vtt-v1+image-ocr-v1) must still normalize .vtt,
        // and likewise for Markdown. Equality checks silently skipped
        // normalization under the new combined OCR modes.
        if textExtraction.includesVTT, ext == "vtt" {
            return extractVTT(content)
        }

        let lineCount = countLines(in: content)
        // Markdown normalization keeps each source newline in place. The
        // splitter therefore reports original-file line numbers even though
        // link destinations and presentation markup are omitted from embeddings.
        let text: String
        if textExtraction.includesMarkdown, ["md", "markdown"].contains(ext) {
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
        // The recognizer (optionally cache-backed) reads and decodes the
        // image. A read or transient recognition error throws and propagates
        // to the pipeline, which records the file as unreadable *without*
        // marking it indexed, so the next run retries. A successful but
        // text-less image returns an empty (blank) result — cached — and
        // yields no chunks, so the file is completed and not re-processed.
        let result = try ocrRecognizer.recognizeText(in: file.url)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        // Whole-image chunk (the full OCR text). Image chunks carry no source
        // line or page numbers — an image has no line structure, so inventing
        // locations would be a lie about origin.
        var chunks: [TextChunk] = [TextChunk(text: text, type: .image)]

        // Sub-chunk the OCR text with the profile splitter, but retain the
        // `.image` chunk type and drop the splitter's synthetic line numbers
        // (they index the reflowed OCR string, not any real source line). The
        // splitter yields nothing when the text already fits one chunk.
        chunks.append(contentsOf: splitter.split(text).map { piece in
            TextChunk(text: piece.text, type: .image)
        })

        return chunks
    }
}
