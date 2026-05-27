import Foundation
import Accelerate

/// Brute-force cosine top-K over the whole corpus. Because every stored vector
/// and the query are L2-normalized, cosine == dot product, so the entire corpus
/// is scored with a single `cblas_sgemv` matrix-vector multiply — microseconds
/// for thousands of chunks. This is the answer to competitors' "minute per
/// search": we never re-embed or re-scan at query time.
public enum VectorSearch {
    /// - Parameters:
    ///   - query: normalized query vector, length `dim`.
    ///   - matrix: row-major `count` × `dim`, each row normalized.
    public static func topK(query: [Float], matrix: [Float], count: Int, dim: Int, k: Int)
        -> [(index: Int, score: Float)] {
        guard count > 0, dim > 0, k > 0,
              query.count == dim, matrix.count == count * dim else { return [] }

        var scores = [Float](repeating: 0, count: count)
        matrix.withUnsafeBufferPointer { m in
            query.withUnsafeBufferPointer { q in
                scores.withUnsafeMutableBufferPointer { s in
                    cblas_sgemv(CblasRowMajor, CblasNoTrans,
                                Int32(count), Int32(dim),
                                1.0, m.baseAddress, Int32(dim),
                                q.baseAddress, 1,
                                0.0, s.baseAddress, 1)
                }
            }
        }
        return selectTopK(scores: scores, k: min(k, count))
    }

    /// Top-k by score, descending, via bounded insertion (k is small). O(n·k),
    /// no full sort of the corpus.
    public static func selectTopK(scores: [Float], k: Int) -> [(index: Int, score: Float)] {
        guard k > 0 else { return [] }
        var top: [(index: Int, score: Float)] = []
        top.reserveCapacity(k)
        for (i, score) in scores.enumerated() {
            if top.count < k {
                top.append((i, score))
                if top.count == k { top.sort { $0.score > $1.score } }
            } else if score > top[k - 1].score {
                var pos = k - 1
                top[pos] = (i, score)
                while pos > 0 && top[pos].score > top[pos - 1].score {
                    top.swapAt(pos, pos - 1)
                    pos -= 1
                }
            }
        }
        if top.count < k { top.sort { $0.score > $1.score } }
        return top
    }
}
