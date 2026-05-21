import SwiftUI
import AppKit
import FileDenAI

/// The Ask window: a status banner, the answer area (a written answer when the
/// on-device LLM is available, plus the source passages it drew from), and a
/// question input. Clicking a source jumps to it in the document.
struct QAView: View {
    @ObservedObject var session: QASession
    @ObservedObject private var settings = FileDenSettings.shared
    @State private var question = ""
    @FocusState private var inputFocused: Bool
    /// Called when a source is clicked, so the host can show it in a pane.
    var onOpenCitation: ((Citation) -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            banner
            Divider().opacity(0.4)
            content
            Divider().opacity(0.4)
            inputBar
        }
        .frame(minWidth: 360, minHeight: 420)
        .onAppear { if session.phase == .ready { inputFocused = true } }
        .onChange(of: session.phase) { _, phase in
            if phase == .ready { inputFocused = true }
        }
    }

    // MARK: - Banner

    @ViewBuilder private var banner: some View {
        HStack(spacing: 8) {
            switch session.phase {
            case .indexing:
                ProgressView().controlSize(.small)
                Text("Indexing \(session.fileCount) \(plural(session.fileCount))…")
            case .ready:
                Image(systemName: "sparkles").foregroundStyle(.tint)
                Text("\(session.fileCount) \(plural(session.fileCount)) · offline")
                Spacer()
                aiToggle
            case .empty:
                Image(systemName: "doc.questionmark").foregroundStyle(.secondary)
                Text("Nothing to search — add PDF, text, Markdown, or HTML files.")
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(message)
            }
            if case .ready = session.phase {} else { Spacer() }
        }
        .font(.system(size: 12, weight: .medium))
        .lineLimit(2)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Inline, configurable answer mode. Disabled (with a reason) when the
    /// on-device model isn't available — then Ask shows passages only.
    @ViewBuilder private var aiToggle: some View {
        if session.llmAvailable {
            Toggle(isOn: $settings.aiSynthesisEnabled) {
                Text("AI answer").font(.system(size: 11, weight: .medium))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
        } else if let note = session.llmUnavailableNote {
            Text("Passages only")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .help(note)
        }
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if !session.hasAsked {
            centered {
                VStack(spacing: 6) {
                    Image(systemName: "text.magnifyingglass")
                        .font(.system(size: 26)).foregroundStyle(.secondary)
                    Text("Ask a question about your documents.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    Text("Answers cite the exact passage — click to jump there.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .multilineTextAlignment(.center)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    questionHeader
                    if session.isSearching {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Searching…").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                    } else if session.citations.isEmpty {
                        Text("No relevant passages found.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                    } else {
                        if session.isAnswering || session.answerText != nil || session.answerError != nil {
                            answerSection
                        }
                        sourcesSection
                    }
                }
                .padding(.vertical, 10)
            }
        }
    }

    /// The question that was asked, shown above the answer on its own card.
    private var questionHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.tint)
            Text(session.lastQuestion)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .padding(.horizontal, 12)
    }

    @ViewBuilder private var answerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Answer")
            if let text = session.answerText {
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(.regularMaterial)
                            .overlay(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.12)))
                    )
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1))
            } else if let error = session.answerError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12)).foregroundStyle(.orange)
                    Text(error)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Writing answer…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel(session.answerText != nil ? "Sources" : "Top passages")
            ForEach(orderedCitations) { citation in
                CitationRow(citation: citation,
                            isCited: session.answerCitedIDs.contains(citation.id),
                            onOpen: { onOpenCitation?(citation) })
                    .padding(.horizontal, 10)
            }
        }
    }

    /// Cited sources first when we have an answer; otherwise retrieval order.
    private var orderedCitations: [Citation] {
        guard !session.answerCitedIDs.isEmpty else { return session.citations }
        let cited = session.citations.filter { session.answerCitedIDs.contains($0.id) }
        let rest = session.citations.filter { !session.answerCitedIDs.contains($0.id) }
        return cited + rest
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack { Spacer(); content(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
    }

    // MARK: - Input

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask a question…", text: $question, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($inputFocused)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                .onSubmit(submit)
                .disabled(session.phase != .ready)

            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(canAsk ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canAsk)
        }
        .padding(12)
    }

    private var canAsk: Bool {
        session.phase == .ready && !session.isSearching && !session.isAnswering &&
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard canAsk else { return }
        session.ask(question)
    }

    private func plural(_ n: Int) -> String { n == 1 ? "document" : "documents" }
}

/// One source passage: file, location, excerpt. Clicking jumps to the source.
private struct CitationRow: View {
    let citation: Citation
    var isCited: Bool = false
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: icon).font(.system(size: 12)).foregroundStyle(.secondary)
                    Text(citation.sourceURL.lastPathComponent)
                        .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if isCited {
                        Text("cited")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.accentColor, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    Spacer(minLength: 6)
                    Text(citation.locationLabel)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Text(citation.snippet)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isCited ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.1),
                                  lineWidth: isCited ? 1 : 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(citation.sourceURL.lastPathComponent) at \(citation.locationLabel)")
    }

    private var icon: String {
        citation.sourceURL.pathExtension.lowercased() == "pdf" ? "doc.richtext" : "doc.text"
    }
}
