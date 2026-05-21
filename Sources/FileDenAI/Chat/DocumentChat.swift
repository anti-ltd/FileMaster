import Foundation

public enum ChatAnswerMode: Sendable, Equatable {
    case synthesized   // the model wrote an answer
    case passagesOnly  // showing retrieved passages (no LLM, or it declined)
}

/// Streamed events for one chat turn.
public enum ChatTurnEvent: Sendable {
    case citations([Citation])              // retrieved sources for this turn
    case partialText(String)                // cumulative assistant text
    case completed(text: String, mode: ChatAnswerMode, svg: String?)
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
                     config: LLMConfiguration = .appleDefault,
                     topK: Int = 6) -> AsyncStream<ChatTurnEvent> {
        AsyncStream { continuation in
            let task = Task { [retrieve, documentURLs] in
                // A query with no content word ("what?", "what is") can't anchor
                // retrieval, and a small model will latch onto context noise — most
                // visibly by echoing the previous answer. Ask for more instead.
                if Self.isUnderspecified(question) {
                    continuation.yield(.completed(text: Self.clarificationText, mode: .passagesOnly, svg: nil))
                    continuation.finish()
                    return
                }

                let citations = retrieve(question, topK)
                continuation.yield(.citations(citations))

                let useHTTP = config.provider != .appleIntelligence
                guard synthesize, !citations.isEmpty,
                      Intelligence.isAvailable || useHTTP else {
                    continuation.yield(.completed(text: Self.fallbackText(citations), mode: .passagesOnly, svg: nil))
                    continuation.finish()
                    return
                }

                let arithmetic = Self.needsArithmetic(question)
                let graph      = Self.needsGraph(question)

                if useHTTP {
                    let instructions = LLMResponder.instructions(arithmetic: arithmetic, graph: graph)
                    let prompt       = Self.buildPrompt(question: question, history: history, citations: citations)
                    do {
                        var last = ""
                        last = try await OpenAILLMResponder.stream(
                            prompt: prompt, systemPrompt: instructions, config: config
                        ) { text in
                            continuation.yield(.partialText(text))
                        }
                        let (text, mode, svg) = Self.processResponse(last, citations: citations)
                        continuation.yield(.completed(text: text, mode: mode, svg: svg))
                    } catch {
                        continuation.yield(.completed(text: Self.fallbackText(citations), mode: .passagesOnly, svg: nil))
                    }
                    continuation.finish()
                    return
                }

                #if canImport(FoundationModels)
                if #available(macOS 26, *) {
                    // Attach the calculator only for genuinely arithmetic questions.
                    // Always offering it makes the small model fixate on figures in a
                    // number-heavy document and refuse plain factual questions.
                    let tools = arithmetic
                        ? ChatTools.make(context: ToolContext(documentURLs: documentURLs))
                        : []
                    let instructions = LLMResponder.instructions(arithmetic: arithmetic, graph: graph)
                    var blocks = citations
                    while true {
                        do {
                            let prompt = Self.buildPrompt(question: question, history: history, citations: blocks)
                            var last = ""
                            last = try await LLMResponder.stream(prompt: prompt, tools: tools, instructions: instructions) { text in
                                last = text
                                continuation.yield(.partialText(text))
                            }
                            let (text, mode, svg) = Self.processResponse(last, citations: citations)
                            continuation.yield(.completed(text: text, mode: mode, svg: svg))
                            break
                        } catch {
                            if LLMResponder.isContextOverflow(error), blocks.count > 1 {
                                blocks = Array(blocks.prefix(max(1, blocks.count / 2)))
                                continue   // retry with less context
                            }
                            continuation.yield(.completed(text: Self.fallbackText(citations), mode: .passagesOnly, svg: nil))
                            break
                        }
                    }
                } else {
                    continuation.yield(.completed(text: Self.fallbackText(citations), mode: .passagesOnly, svg: nil))
                }
                #else
                continuation.yield(.completed(text: Self.fallbackText(citations), mode: .passagesOnly, svg: nil))
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

    /// Parse any graph spec from the model's response, generate SVG, and strip the tag.
    /// Returns the cleaned text, answer mode, and optional SVG string.
    static func processResponse(_ text: String, citations: [Citation]) -> (text: String, mode: ChatAnswerMode, svg: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (fallbackText(citations), .passagesOnly, nil)
        }
        if let spec = SVGGraphGenerator.parse(trimmed) {
            let svg     = SVGGraphGenerator.generate(spec)
            let cleaned = SVGGraphGenerator.stripTag(trimmed)
            return (cleaned, .synthesized, svg)
        }
        return (trimmed, .synthesized, nil)
    }

    /// True when the question is asking for a chart, graph, or data visualization.
    static func needsGraph(_ question: String) -> Bool {
        let q = question.lowercased()
        let cues: Set<String> = [
            "chart", "graph", "plot", "visualize", "visualization", "visualise",
            "diagram", "histogram", "draw", "pie", "bar", "trend"
        ]
        let words = Set(q.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
        if !words.isDisjoint(with: cues) { return true }
        return q.contains("line chart") || q.contains("show me a chart") || q.contains("show me a graph")
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

    /// True when the question asks for a calculation across numbers, so the chat
    /// should attach the `calculate` tool. Gating it (rather than always offering
    /// it) is what keeps a small model from fixating on figures in a number-heavy
    /// document and refusing factual questions — e.g. answering "who's the
    /// landlord?" with "the numbers … can't be evaluated". Matches whole words so
    /// "sum" doesn't fire on "summary" nor "add" on "address".
    static func needsArithmetic(_ question: String) -> Bool {
        let q = question.lowercased()
        // A digit on each side of an unambiguous arithmetic operator, e.g.
        // "1500 * 12", "100+50", "12 x 4". `-` and `/` are excluded so dates
        // ("01/06/2025") don't read as arithmetic.
        if q.range(of: #"[0-9]\s*[+*×÷x]\s*[0-9]"#, options: .regularExpression) != nil { return true }
        // "add up" / "adds up" / "added up" — the one cue that isn't a clean word.
        if q.range(of: #"\badd(s|ed)?\s+up\b"#, options: .regularExpression) != nil { return true }
        let cues: Set<String> = [
            "total", "subtotal", "sum", "altogether", "subtract", "minus", "plus",
            "multiply", "multiplied", "product", "divide", "divided", "average",
            "percent", "percentage", "calculate", "compute", "times", "difference",
            "lowest", "highest", "minimum", "maximum", "lowest", "best", "worst",
            "peak", "bottom", "least", "most", "smallest", "largest", "min", "max"
        ]
        let words = Set(q.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
        if !words.isDisjoint(with: cues) { return true }
        return q.contains("%")   // "what's 15% of the deposit"
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
        let rawContext = citations.enumerated().map { index, citation in
            "[\(index + 1)] (\(citation.sourceURL.lastPathComponent), \(citation.locationLabel))\n\(citation.chunk.text)"
        }.joined(separator: "\n\n")
        let context = TableDataAnnotator.annotate(rawContext)
        parts.append("Excerpts from the documents:\n\(context)")
        parts.append("User: \(question)")
        return parts.joined(separator: "\n\n")
    }
}
