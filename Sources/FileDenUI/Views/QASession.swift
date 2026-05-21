import Foundation
import AppKit
import FileDenAI

/// Drives the Ask UI as a multi-turn chat over a den's documents: indexes them in
/// the background, then runs each turn through ``DocumentChat`` (retrieve →
/// synthesize, with a passages fallback that never dead-ends). Mirrors the app's
/// off-main work pattern and publishes the transcript to ``QAView``.
@MainActor
final class QASession: ObservableObject {
    enum Phase: Equatable {
        case indexing
        case ready
        case empty
        case failed(String)
    }

    @Published private(set) var phase: Phase = .indexing
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isBusy = false           // a turn is in flight

    let fileCount: Int
    private let urls: [URL]
    private var engine: AskEngine?
    private var chat: DocumentChat?
    private var turnTask: Task<Void, Never>?
    private let work = DispatchQueue(label: "ltd.anti.FileDen.ask", qos: .userInitiated)

    init(urls: [URL]) {
        self.urls = urls
        self.fileCount = urls.filter { TextExtractor.canExtract($0) }.count
        startIndexing()
    }

    var hasMessages: Bool { !messages.isEmpty }

    var modelLabel: String {
        let config = FileDenSettings.shared.llmConfiguration
        if config.provider == .appleIntelligence { return "Apple Intelligence" }
        return config.model.isEmpty ? config.provider.displayName : config.model
    }

    var llmAvailable: Bool {
        let provider = LLMConfiguration.Provider(rawValue: FileDenSettings.shared.llmProvider)
            ?? .appleIntelligence
        return provider == .appleIntelligence ? Intelligence.isAvailable : true
    }

    var llmUnavailableNote: String? {
        let provider = LLMConfiguration.Provider(rawValue: FileDenSettings.shared.llmProvider)
            ?? .appleIntelligence
        return provider == .appleIntelligence ? Intelligence.unavailabilityReason : nil
    }

    // MARK: - Indexing

    private func startIndexing() {
        guard fileCount > 0 else { phase = .empty; return }
        phase = .indexing
        let hud = ProgressHUD(label: "Indexing documents")
        let urls = self.urls
        work.async { [weak self] in
            do {
                let engine = try AskEngine()
                try engine.prepare(urls: urls) { fraction in
                    Task { @MainActor in hud.update(fraction) }
                }
                Task { @MainActor in
                    hud.finish()
                    guard let self else { return }
                    self.engine = engine
                    let supported = urls.filter { TextExtractor.canExtract($0) }
                    self.chat = DocumentChat(documentURLs: supported,
                                             retrieve: { query, k in engine.retrieve(query, topK: k) })
                    self.phase = engine.isReady ? .ready : .empty
                }
            } catch {
                let message = Self.message(for: error)
                Task { @MainActor in
                    hud.finish()
                    self?.phase = .failed(message)
                }
            }
        }
    }

    // MARK: - Chatting

    func clearChat() {
        turnTask?.cancel()
        turnTask = nil
        messages = []
        isBusy = false
    }

    func send(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isBusy, phase == .ready, let chat else { return }

        let history = messages
        messages.append(ChatMessage(role: .user, text: trimmed))
        let assistant = ChatMessage(role: .assistant, isStreaming: true)
        messages.append(assistant)
        let assistantID = assistant.id
        isBusy = true

        let config = FileDenSettings.shared.llmConfiguration
        turnTask = Task { [weak self] in
            for await event in chat.send(question: trimmed, history: history, synthesize: true, config: config) {
                if Task.isCancelled { return }
                switch event {
                case .citations(let citations):
                    self?.update(assistantID) { $0.citations = citations }
                case .partialText(let text):
                    self?.update(assistantID) { $0.text = Self.stripGraphTag(text) }
                case .completed(let text, _, let svg):
                    self?.update(assistantID) { $0.text = text; $0.svg = svg; $0.isStreaming = false }
                }
            }
            self?.update(assistantID) { $0.isStreaming = false }
            self?.isBusy = false
        }
    }

    private func update(_ id: UUID, _ change: (inout ChatMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[index])
    }

    /// Strip `<graph>…</graph>` from streaming text so the raw spec is never shown.
    /// While the tag is still open (closing tag not yet received) everything from
    /// `<graph>` onward is hidden; once complete the whole block is removed.
    private static func stripGraphTag(_ text: String) -> String {
        if let start = text.range(of: "<graph>"),
           let end   = text.range(of: "</graph>") {
            let before = String(text[text.startIndex..<start.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let after  = String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return [before, after].filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        if let start = text.range(of: "<graph>") {
            let before = String(text[text.startIndex..<start.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            return [before, "Generating graph…"].filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        return text
    }

    private nonisolated static func message(for error: Error) -> String {
        switch error {
        case AskError.noSupportedFiles:
            return "No PDF, text, Markdown, or HTML files to search."
        case AskError.embeddingsUnavailable:
            return "On-device text embeddings aren't available on this Mac."
        default:
            return "Couldn't index these documents."
        }
    }
}
