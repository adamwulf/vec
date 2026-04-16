import Foundation

/// A single search result from a vector similarity query.
public struct SearchResult {
    /// Path relative to the project root
    public let filePath: String
    /// Starting line number, if applicable
    public let lineStart: Int?
    /// Ending line number, if applicable
    public let lineEnd: Int?
    /// Chunk type (whole, chunk, pdf_page, image)
    public let chunkType: ChunkType
    /// PDF page number, if applicable
    public let pageNumber: Int?
    /// Preview of the content
    public let contentPreview: String?
    /// Distance from the query vector (lower = more similar)
    public let distance: Double

    public init(filePath: String, lineStart: Int?, lineEnd: Int?, chunkType: ChunkType, pageNumber: Int?, contentPreview: String?, distance: Double) {
        self.filePath = filePath
        self.lineStart = lineStart
        self.lineEnd = lineEnd
        self.chunkType = chunkType
        self.pageNumber = pageNumber
        self.contentPreview = contentPreview
        self.distance = distance
    }
}
