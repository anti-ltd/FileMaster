import Foundation

/// Identifies which LLM backend handles synthesis and supplies the connection details for
/// HTTP-based providers (OpenAI, Ollama, llama.cpp). Apple Intelligence carries no config.
public struct LLMConfiguration: Sendable, Equatable {

    public enum Provider: String, Sendable, CaseIterable {
        case appleIntelligence = "apple"
        case openAI            = "openai"
        case ollama            = "ollama"
        case llamaCpp          = "llamacpp"
        /// No LLM — document search and passage retrieval only.
        case none              = "none"

        public var displayName: String {
            switch self {
            case .appleIntelligence: "Apple Intelligence"
            case .openAI:            "OpenAI"
            case .ollama:            "Ollama"
            case .llamaCpp:          "llama.cpp"
            case .none:              "None"
            }
        }

        public var defaultBaseURL: String {
            switch self {
            case .appleIntelligence: ""
            case .openAI:            "https://api.openai.com/v1"
            case .ollama:            "http://localhost:11434/v1"
            case .llamaCpp:          "http://localhost:8080/v1"
            case .none:              ""
            }
        }

        public var defaultModel: String {
            switch self {
            case .appleIntelligence: ""
            case .openAI:            "gpt-4o-mini"
            case .ollama:            "llama3.2"
            case .llamaCpp:          "default"
            case .none:              ""
            }
        }

        /// Only OpenAI requires an API key; local servers run unauthenticated.
        public var requiresAPIKey: Bool { self == .openAI }
    }

    public var provider: Provider
    /// Endpoint base URL. Empty resolves to `provider.defaultBaseURL` at call time.
    public var baseURL: String
    /// API key (required for OpenAI; leave empty for Ollama/llama.cpp).
    public var apiKey: String
    /// Model identifier sent in the request body.
    public var model: String

    public init(provider: Provider, baseURL: String = "", apiKey: String = "", model: String = "") {
        self.provider = provider
        self.baseURL  = baseURL.isEmpty ? provider.defaultBaseURL : baseURL
        self.apiKey   = apiKey
        self.model    = model.isEmpty ? provider.defaultModel : model
    }

    public static let appleDefault = LLMConfiguration(provider: .appleIntelligence)
}
