import Foundation

public enum ChatAnswerMode: Sendable, Equatable {
    case synthesized   // the model wrote an answer
    case passagesOnly  // showing retrieved passages (no LLM, or it declined)
}

/// Streamed events for one chat turn.
public enum ChatTurnEvent: Sendable {
    case citations([Citation])              // retrieved sources for this turn
    case partialText(String)                // cumulative assistant text
    case completed(text: String, mode: ChatAnswerMode)
}

/// A multi-turn conversation over a document set. Each turn retrieves fresh
/// context and (if available and enabled) asks the on-device model, streaming the
/// reply. It is **bulletproof by design**: any failure — model off, error, empty
/// output, context overflow — degrades to showing the relevant passages with a
/// friendly lead-in, never a dead end.
///
/// Retrieval is injected as a closure so the engine and the chat stay decoupled
/// (and the chat is testable without the global index).
public final class DocumentChat: @unchecked Sendable {
    public typealias Retrieve = @Sendable (_ query: String, _ topK: Int) -> [Citation]

    private let documentURLs: [URL]
    private let retrieve: Retrieve

    public init(documentURLs: [URL], retrieve: @escaping Retrieve) {
        self.documentURLs = documentURLs
        self.retrieve = retrieve
    }

    public var llmAvailable: Bool { Intelligence.isAvailable }

    public func send(question: String,
                     history: [ChatMessage],
                     synthesize: Bool,
                     topK: Int = 6) -> AsyncStream<ChatTurnEvent> {
        AsyncStream { continuation in
            let task = Task { [retrieve, documentURLs] in
                // A query with no content word ("what?", "what is") can't anchor
                // retrieval, and a small model will latch onto context noise — most
                // visibly by echoing the previous answer. Ask for more instead.
                if Self.isUnderspecified(question) {
                    continuation.yield(.completed(text: Self.clarificationText, mode: .passagesOnly))
                    continuation.finish()
                    return
                }

                let citations = retrieve(question, topK)
                continuation.yield(.citations(citations))

                guard synthesize, Intelligence.isAvailable, !citations.isEmpty else {
                    continuation.yield(.completed(text: Self.fallbackText(citations), mode: .passagesOnly))
                    continuation.finish()
                    return
                }

                #if canImport(FoundationModels)
                if #available(macOS 26, *) {
                    let tools = ChatTools.make(context: ToolContext(documentURLs: documentURLs))
                    var blocks = citations
                    while true {
                        do {
                            let prompt = Self.buildPrompt(question: question, history: history, citations: blocks)
                            var last = ""
                            last = try await LLMResponder.stream(prompt: prompt, tools: tools) { text in
                                last = text
                                continuation.yield(.partialText(text))
                            }
                            let trimmed = last.trimmingCharacters(in: .whitespacesAndNewlines)
                            continuation.yield(.completed(
                                text: trimmed.isEmpty ? Self.fallbackText(citations) : last,
                                mode: trimmed.isEmpty ? .passagesOnly : .synthesized))
                            break
                        } catch {
                            if LLMResponder.isContextOverflow(error), blocks.count > 1 {
                                blocks = Array(blocks.prefix(max(1, blocks.count / 2)))
                                continue   // retry with less context
                            }
                            continuation.yield(.completed(text: Self.fallbackText(citations), mode: .passagesOnly))
                            break
                        }
                    }
                } else {
                    continuation.yield(.completed(text: Self.fallbackText(citations), mode: .passagesOnly))
                }
                #else
                continuation.yield(.completed(text: Self.fallbackText(citations), mode: .passagesOnly))
                #endif
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Prompt

    static func fallbackText(_ citations: [Citation]) -> String {
        citations.isEmpty
            ? "I couldn't find anything about that in these documents."
            : "Here are the most relevant passages I found:"
    }

    static let clarificationText =
        "Could you say a bit more about what you'd like to know? A few words to go on will get you a better answer."

    /// True when a query carries no content word — only question words, articles,
    /// and the like (e.g. "what?", "what is the"). Such queries give a small model
    /// nothing to ground on, so the chat asks for more rather than synthesizing on
    /// noise. Queries with any real term ("summarize for me", "revenue?") pass.
    static func isUnderspecified(_ query: String) -> Bool {
        let stopwords: Set<String> = [
            "what", "who", "whom", "whose", "where", "when", "why", "how", "which",
            "is", "are", "was", "were", "be", "am", "do", "does", "did",
            "a", "an", "the", "of", "to", "for", "in", "on", "at", "and", "or",
            "me", "you", "it", "this", "that", "these", "those", "there", "here"
        ]
        let words = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return words.allSatisfy { stopwords.contains($0) }
    }

    static func buildPrompt(question: String, history: [ChatMessage], citations: [Citation]) -> String {
        var parts: [String] = []
        let recent = history.suffix(6)
        if !recent.isEmpty {
            let convo = recent.map { message in
                let who = message.role == .user ? "User" : "Assistant"
                return "\(who): \(message.text.prefix(400))"
            }.joined(separator: "\n")
            parts.append("Conversation so far:\n\(convo)")
        }
        let context = citations.enumerated().map { index, citation in
            "[\(index + 1)] (\(citation.sourceURL.lastPathComponent), \(citation.locationLabel))\n\(citation.chunk.text)"
        }.joined(separator: "\n\n")
        parts.append("Excerpts from the documents:\n\(context)")
        parts.append("User: \(question)")
        return parts.joined(separator: "\n\n")
    }
}
