import Foundation

/// The in-memory view of a set of indexed files, ready for search: every chunk's
/// metadata plus a single contiguous, normalized vector matrix for the Accelerate
/// dot-product. Built once per Ask session by ``SQLiteIndexStore/loadCorpus(urls:dim:)``.
public struct Corpus: Sendable {
    public let chunks: [StoredChunk]
    /// Row-major `chunks.count` × `dim`, each row L2-normalized.
    public let matrix: [Float]
    public let dim: Int
    /// Chunk ids in this corpus (for filtering lexical hits to the active files).
    public let validIDs: Set<Int64>

    public init(chunks: [StoredChunk], matrix: [Float], dim: Int, validIDs: Set<Int64>) {
        self.chunks = chunks
        self.matrix = matrix
        self.dim = dim
        self.validIDs = validIDs
    }

    public var isEmpty: Bool { chunks.isEmpty }
}
