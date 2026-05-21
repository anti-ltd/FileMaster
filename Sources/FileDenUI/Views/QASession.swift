import Foundation
import AppKit
import FileDenAI

/// Drives the Ask window: indexes a den's documents in the background (with a
/// `ProgressHUD`), retrieves the relevant passages for each question, and — when
/// the on-device LLM is available and enabled — synthesizes a grounded, cited
/// written answer over them. Mirrors the app's off-main tool pattern, exposing
/// observable state to ``QAView``.
@MainActor
final class QASession: ObservableObject {
    enum Phase: Equatable {
        case indexing
        case ready
        case empty                 // nothing indexable
        case failed(String)
    }

    @Published private(set) var phase: Phase = .indexing
    @Published private(set) var citations: [Citation] = []
    @Published private(set) var answerText: String?       // synthesized prose, when produced
    @Published private(set) var answerError: String?      // why synthesis failed, if it did
    @Published private(set) var answerCitedIDs: Set<Int64> = []
    @Published private(set) var isSearching = false        // retrieving passages
    @Published private(set) var isAnswering = false        // LLM writing the answer
    @Published private(set) var lastQuestion = ""
    @Published private(set) var hasAsked = false

    let fileCount: Int
    private let urls: [URL]
    private var engine: AskEngine?
    private var answerTask: Task<Void, Never>?
    private let work = DispatchQueue(label: "ltd.anti.FileDen.ask", qos: .userInitiated)

    init(urls: [URL]) {
        self.urls = urls
        self.fileCount = urls.filter { TextExtractor.canExtract($0) }.count
        startIndexing()
    }

    // MARK: - Intelligence availability

    /// Whether the on-device LLM can write answers right now.
    var llmAvailable: Bool {
        if #available(macOS 26, *) { return FoundationModelsAnswerProvider.isAvailable }
        return false
    }

    /// Why the LLM isn't available (for the banner), or nil when it is.
    var llmUnavailableNote: String? {
        if #available(macOS 26, *) { return FoundationModelsAnswerProvider.unavailabilityReason }
        return "Written answers need macOS 26 with Apple Intelligence."
    }

    /// True when this question will be answered in prose (vs. passages only).
    var willSynthesize: Bool { FileDenSettings.shared.aiSynthesisEnabled && llmAvailable }

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

    // MARK: - Asking

    func ask(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSearching, !isAnswering, phase == .ready, let engine else { return }

        answerTask?.cancel()
        lastQuestion = trimmed
        hasAsked = true
        isSearching = true
        answerText = nil
        answerError = nil
        answerCitedIDs = []
        citations = []

        let synthesize = willSynthesize
        work.async { [weak self] in
            let results = engine.retrieve(trimmed)
            Task { @MainActor in
                guard let self else { return }
                self.citations = results
                self.isSearching = false
                if synthesize, !results.isEmpty {
                    self.synthesize(question: trimmed, citations: results)
                }
            }
        }
    }

    private func synthesize(question: String, citations: [Citation]) {
        guard #available(macOS 26, *) else { return }
        isAnswering = true
        answerError = nil
        answerTask = Task { [weak self] in
            do {
                for try await event in FoundationModelsAnswerProvider.streamAnswer(question: question, citations: citations) {
                    if Task.isCancelled { return }
                    switch event {
                    case .partialText(let text):
                        self?.answerText = text
                    case .completed(let answer):
                        let trimmed = answer.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty {
                            self?.answerText = nil
                            self?.answerError = "The model didn't return an answer — showing the source passages below."
                        } else {
                            self?.answerText = answer.text
                            self?.answerCitedIDs = Set(answer.citedIDs)
                        }
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                self?.answerText = nil
                self?.answerError = "Couldn't generate a written answer — showing the source passages below."
            }
            self?.isAnswering = false
        }
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
