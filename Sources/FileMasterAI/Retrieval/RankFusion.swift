import Foundation

/// Reciprocal Rank Fusion — combines the semantic and lexical result lists into
/// one ranking. RRF needs no score calibration between the two retrievers (it
/// uses ranks, not raw scores), which is exactly what hybrid retrieval wants:
/// semantic search catches paraphrase, lexical search catches exact names / IDs /
/// codes, and fusion keeps an item that either retriever ranked highly.
public enum RankFusion {
    /// - Parameters:
    ///   - lists: each is chunk ids ordered best-first.
    ///   - k: RRF damping constant (standard default 60).
    public static func rrf(_ lists: [[Int64]], k: Double = 60, limit: Int) -> [(id: Int64, score: Double)] {
        var scores: [Int64: Double] = [:]
        for list in lists {
            for (rank, id) in list.enumerated() {
                scores[id, default: 0] += 1.0 / (k + Double(rank + 1))
            }
        }
        return scores
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit)
            .map { (id: $0.key, score: $0.value) }
    }
}
