import Foundation

/// A single search result from a vector similarity query.
public struct SearchResult: Sendable {
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
    /// Row ID of the chunk in the database (stable within a single indexed state).
    public let chunkId: Int64

    public init(filePath: String, lineStart: Int?, lineEnd: Int?, chunkType: ChunkType, pageNumber: Int?, contentPreview: String?, distance: Double, chunkId: Int64 = 0) {
        self.filePath = filePath
        self.lineStart = lineStart
        self.lineEnd = lineEnd
        self.chunkType = chunkType
        self.pageNumber = pageNumber
        self.contentPreview = contentPreview
        self.distance = distance
        self.chunkId = chunkId
    }
}
