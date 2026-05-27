import Foundation

/// Which backend produces the answer. Configurable (the user chose "configurable"
/// for the answer engine). M1 ships ``retrievalOnly``; M2 adds ``foundationModels``
/// (Apple's on-device LLM) and gates the default on availability.
public enum AnswerBackend: String, Sendable, CaseIterable, Codable {
    case retrievalOnly
    case foundationModels
    // case localEndpoint   // M3: OpenAI-compatible localhost model, still offline
}

/// The result of asking a question: the supporting passages always, plus a
/// synthesized prose answer when an LLM backend produced one.
public struct AnswerResult: Sendable {
    /// Synthesized prose. Nil in retrieval-only mode (the citations *are* the answer).
    public let text: String?
    public let citations: [Citation]
    public let backend: AnswerBackend

    public init(text: String?, citations: [Citation], backend: AnswerBackend) {
        self.text = text
        self.citations = citations
        self.backend = backend
    }
}

public enum AskError: Error, Sendable {
    case noSupportedFiles
    case embeddingsUnavailable
}
