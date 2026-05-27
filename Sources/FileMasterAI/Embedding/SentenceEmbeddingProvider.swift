import Foundation
import NaturalLanguage

/// Fallback embeddings via `NLEmbedding.sentenceEmbedding` (available far back,
/// 512-d, English-leaning, lower quality than the contextual model). Used when
/// the contextual model's assets can't be loaded (e.g. offline first run).
public final class SentenceEmbeddingProvider: EmbeddingProvider, @unchecked Sendable {
    public let identifier: String
    public let dimension: Int
    private let embedding: NLEmbedding

    public init?(language: NLLanguage = .english) {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: language) else { return nil }
        self.embedding = embedding
        self.dimension = embedding.dimension
        self.identifier = "sentence.\(language.rawValue).d\(embedding.dimension)"
    }

    public func embed(_ texts: [String]) -> [[Float]] {
        let zero = [Float](repeating: 0, count: dimension)
        return texts.map { text in
            guard !text.isEmpty, let v = embedding.vector(for: text) else { return zero }
            return VectorMath.normalized(v.map(Float.init))
        }
    }
}
