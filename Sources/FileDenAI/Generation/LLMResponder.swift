import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Thin wrapper over one streamed, plain-text generation from the on-device model
/// with tools attached. Plain text (not guided `@Generable`) is deliberate: it
/// avoids the `decodingFailure` that makes structured generation flaky, which is
/// the bulletproofing win. The caller owns prompt construction and retry policy.
@available(macOS 26, *)
enum LLMResponder {
    static let instructions = """
    You are a helpful assistant answering questions about the user's own documents in a conversation. \
    Answer the user's latest message directly, using the provided excerpts as your primary source and \
    staying grounded in them; you may use the conversation so far for context. If the excerpts don't \
    contain the answer, say so plainly rather than inventing facts. Only when the user explicitly asks \
    you to compute something over numbers in the documents — a total, sum, difference, product, or \
    percentage — call the `calculate` tool and report its result. When the numbers live in a table \
    with several columns, take the values from the exact column the user named (e.g. revenue, not \
    users), passing them as written (keep the currency symbols). For everything else, just answer in \
    prose and do not call any tool. Be concise and conversational.
    """

    #if canImport(FoundationModels)
    /// Stream a response for `prompt`, forwarding cumulative text via `onText`,
    /// returning the final text. Throws `GenerationError` (caller handles overflow).
    static func stream(prompt: String,
                       tools: [any Tool],
                       onText: @escaping (String) -> Void) async throws -> String {
        let session = LanguageModelSession(tools: tools, instructions: instructions)
        let options = GenerationOptions(temperature: 0.4, maximumResponseTokens: 800)
        var last = ""
        for try await snapshot in session.streamResponse(to: prompt, options: options) {
            last = snapshot.content
            onText(last)
        }
        return last
    }

    /// True if `error` is a context-window overflow (caller should retry smaller).
    static func isContextOverflow(_ error: Error) -> Bool {
        if let generationError = error as? LanguageModelSession.GenerationError,
           case .exceededContextWindowSize = generationError {
            return true
        }
        return false
    }
    #endif
}
