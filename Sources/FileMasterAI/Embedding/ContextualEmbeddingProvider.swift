import Foundation
import NaturalLanguage

/// High-quality on-device embeddings via `NLContextualEmbedding` (a BERT-family
/// transformer, macOS 14+). It emits one vector per token; we mean-pool those
/// into a single passage vector and L2-normalize.
public final class ContextualEmbeddingProvider: EmbeddingProvider, @unchecked Sendable {
    public let identifier: String
    public let dimension: Int
    private let embedding: NLContextualEmbedding
    private let language: NLLanguage

    private init(embedding: NLContextualEmbedding, language: NLLanguage) {
        self.embedding = embedding
        self.language = language
        self.dimension = embedding.dimension
        self.identifier = "contextual.\(language.rawValue).d\(embedding.dimension)"
    }

    /// Build a provider for `language`, loading the on-device model (downloading
    /// once if needed and online). Returns nil if the language is unsupported or
    /// the assets can't be made available. Synchronous: call off the main thread.
    public static func make(language: NLLanguage) -> ContextualEmbeddingProvider? {
        guard let embedding = NLContextualEmbedding(language: language) else { return nil }
        if !embedding.hasAvailableAssets {
            let sem = DispatchSemaphore(value: 0)
            Task {
                _ = try? await embedding.requestAssets()
                sem.signal()
            }
            sem.wait()
        }
        do { try embedding.load() } catch { return nil }
        return ContextualEmbeddingProvider(embedding: embedding, language: language)
    }

    public func embed(_ texts: [String]) -> [[Float]] {
        texts.map(vector(for:))
    }

    private func vector(for text: String) -> [Float] {
        let zero = [Float](repeating: 0, count: dimension)
        guard !text.isEmpty,
              let result = try? embedding.embeddingResult(for: text, language: language)
        else { return zero }

        var sum = [Double](repeating: 0, count: dimension)
        var count = 0
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
            if vector.count == self.dimension {
                for i in 0..<self.dimension { sum[i] += vector[i] }
                count += 1
            }
            return true
        }
        guard count > 0 else { return zero }
        var pooled = [Float](repeating: 0, count: dimension)
        let inv = 1.0 / Double(count)
        for i in 0..<dimension { pooled[i] = Float(sum[i] * inv) }
        return VectorMath.normalized(pooled)
    }
}
