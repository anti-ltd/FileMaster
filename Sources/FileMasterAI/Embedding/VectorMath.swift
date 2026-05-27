import Foundation
import Accelerate

/// Small vector helpers backed by Accelerate. Kept separate so the embedding
/// providers and the search code share one normalization convention.
enum VectorMath {
    /// L2-normalize in place-style (returns a normalized copy). A zero vector is
    /// returned unchanged so a degenerate embedding can't produce NaNs.
    static func normalized(_ v: [Float]) -> [Float] {
        guard !v.isEmpty else { return v }
        var sumSquares: Float = 0
        vDSP_svesq(v, 1, &sumSquares, vDSP_Length(v.count))
        let norm = sqrt(sumSquares)
        guard norm > 0 else { return v }
        var out = [Float](repeating: 0, count: v.count)
        var divisor = norm
        vDSP_vsdiv(v, 1, &divisor, &out, 1, vDSP_Length(v.count))
        return out
    }
}
