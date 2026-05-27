import Foundation
import NaturalLanguage

/// Chooses the best available embedding provider for a corpus: the contextual
/// model in the corpus's dominant language, falling back to sentence embeddings.
public enum EmbeddingProviderFactory {
    /// Synchronous (loads/awaits model assets internally); call off the main thread.
    /// Returns nil only if no embedding model is available at all.
    public static func make(sampleText: String, preferContextual: Bool = true) -> EmbeddingProvider? {
        let language = detectLanguage(sampleText)
        if preferContextual, let contextual = ContextualEmbeddingProvider.make(language: language) {
            return contextual
        }
        if let sentence = SentenceEmbeddingProvider(language: language) {
            return sentence
        }
        if let english = SentenceEmbeddingProvider(language: .english) {
            return english
        }
        return ContextualEmbeddingProvider.make(language: .english)
    }

    static func detectLanguage(_ text: String) -> NLLanguage {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(2000)))
        return recognizer.dominantLanguage ?? .english
    }
}
