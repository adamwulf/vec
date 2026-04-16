import Foundation

/// Represents a file discovered by the scanner, with metadata needed for indexing.
public struct FileInfo: Sendable {
    /// Path relative to the project root
    public let relativePath: String
    /// Absolute URL to the file
    public let url: URL
    /// File modification date
    public let modificationDate: Date
    /// File extension (lowercase, without dot)
    public let fileExtension: String

    public init(relativePath: String, url: URL, modificationDate: Date, fileExtension: String) {
        self.relativePath = relativePath
        self.url = url
        self.modificationDate = modificationDate
        self.fileExtension = fileExtension
    }
}

/// Represents a chunk of text extracted from a file, ready to be embedded.
public struct TextChunk: Sendable {
    /// The text content to embed
    public let text: String
    /// The type of chunk
    public let type: ChunkType
    /// Starting line number (1-based), nil for whole-document or PDF pages
    public let lineStart: Int?
    /// Ending line number (1-based), nil for whole-document or PDF pages
    public let lineEnd: Int?
    /// PDF page number (1-based), nil for non-PDF files
    public let pageNumber: Int?

    public init(text: String, type: ChunkType, lineStart: Int? = nil, lineEnd: Int? = nil, pageNumber: Int? = nil) {
        self.text = text
        self.type = type
        self.lineStart = lineStart
        self.lineEnd = lineEnd
        self.pageNumber = pageNumber
    }
}

/// The type of chunk stored in the index.
public enum ChunkType: String, Sendable {
    case whole = "whole"
    case chunk = "chunk"
    case pdfPage = "pdf_page"
    case image = "image"
}
