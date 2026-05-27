import Foundation

/// Turns text into L2-normalized embedding vectors for semantic search.
///
/// Implementations are called from a background queue (ingestion + per-query
/// embedding), never the main thread. `identifier` is folded into each file's
/// index fingerprint, so switching providers (or model dimensions) automatically
/// invalidates and re-indexes.
public protocol EmbeddingProvider: AnyObject, Sendable {
    var identifier: String { get }
    var dimension: Int { get }
    /// Returns one normalized vector per input, in order. A vector for empty or
    /// un-embeddable text is all-zeros (it simply never matches).
    func embed(_ texts: [String]) -> [[Float]]
}
