import SwiftUI
import AppKit
import FileMasterAI

/// The Ask UI: a multi-turn chat over the den's documents. User turns appear as
/// accent bubbles; assistant turns stream in on material cards with the sources
/// they used. Clicking a source opens it in the viewer pane.
struct QAView: View {
    @ObservedObject var session: QASession
    @State private var question = ""
    @FocusState private var inputFocused: Bool
    /// Called when a source is clicked, so the host can show it in a pane.
    /// Both arguments come from the same assistant turn: `active` is the source
    /// the user tapped, `siblings` is every source that turn drew on so the
    /// viewer can offer a strip of `[N]` chips and ◀ ▶ navigation.
    var onOpenCitation: ((_ active: Citation, _ siblings: [Citation]) -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            transcript
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

    // MARK: - Transcript

    @ViewBuilder private var transcript: some View {
        if !session.hasMessages {
            centered {
                VStack(spacing: 6) {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .font(.system(size: 26)).foregroundStyle(.secondary)
                    Text("Chat")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    Text("Grounded answers cite the exact passage — click to jump there.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .multilineTextAlignment(.center)
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(session.messages) { message in
                            messageView(message).id(message.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                }
                .onChange(of: session.messages.count) { _, _ in scrollToEnd(proxy) }
                .onChange(of: session.messages.last?.text) { _, _ in scrollToEnd(proxy) }
            }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        guard let last = session.messages.last else { return }
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
    }

    @ViewBuilder private func messageView(_ message: ChatMessage) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 36)
                Text(message.text)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
            }
        case .assistant:
            let bubbleMaxW: CGFloat = message.svg.map { svgNaturalSize($0).width + 24 } ?? .infinity
            assistantBubble(message)
                .frame(maxWidth: bubbleMaxW, alignment: .leading)
        }
    }

    @ViewBuilder private func assistantBubble(_ message: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if message.text.isEmpty && message.svg == nil && message.isStreaming {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Thinking…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            } else {
                if !message.text.isEmpty {
                    let parts = message.text.components(separatedBy: "Generating graph…")
                    let prose = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    let generatingGraph = parts.count > 1
                    if !prose.isEmpty {
                        Text(Self.annotated(prose, citations: message.citations))
                            .font(.system(size: 13))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .environment(\.openURL, OpenURLAction { url in
                                guard url.scheme == "fm-citation",
                                      let host = url.host, let n = Int(host),
                                      n >= 1, n <= message.citations.count
                                else { return .systemAction }
                                onOpenCitation?(message.citations[n - 1], message.citations)
                                return .handled
                            })
                    }
                    if generatingGraph {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Generating graph…")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let svg = message.svg {
                    let size = svgNaturalSize(svg)
                    SVGView(svg: svg)
                        .aspectRatio(size.width / size.height, contentMode: .fit)
                        .frame(maxWidth: size.width)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            if message.svg != nil || !message.citations.isEmpty {
                HStack {
                    if let svg = message.svg {
                        GraphExportButton(svg: svg)
                    }
                    Spacer()
                    if !message.citations.isEmpty {
                        SourcesButton(citations: message.citations,
                                      onOpen: { onOpenCitation?($0, message.citations) })
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack { Spacer(); content(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
    }

    // MARK: - Input

    private var inputBar: some View {
        HStack(spacing: 8) {
            if session.hasMessages {
                Button(action: { session.clearChat() }) {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear chat")
                .disabled(session.isBusy)
            }
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
                    .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canSend)
        }
        .padding(12)
    }

    private var canSend: Bool {
        session.phase == .ready && !session.isBusy &&
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard canSend else { return }
        session.send(question)
        question = ""
    }

    private func plural(_ n: Int) -> String { n == 1 ? "document" : "documents" }

    /// Turn `prose` into an attributed string where each `[N]` marker that
    /// references a real citation becomes a clickable accent-coloured link
    /// (`fm-citation://N`). Stray brackets — and `[N]` for indexes the model
    /// hallucinated past the actual source list — pass through as plain text so
    /// the reader still sees them but they don't go anywhere.
    static func annotated(_ prose: String, citations: [Citation]) -> AttributedString {
        guard !citations.isEmpty,
              let pattern = try? NSRegularExpression(pattern: #"\[(\d+)\]"#)
        else { return AttributedString(prose) }
        let ns = prose as NSString
        let matches = pattern.matches(in: prose, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return AttributedString(prose) }

        var result = AttributedString()
        var cursor = 0
        for match in matches {
            let start = match.range.location
            let end = start + match.range.length
            let number = ns.substring(with: match.range(at: 1))
            guard let n = Int(number), n >= 1, n <= citations.count else { continue }

            if start > cursor {
                result += AttributedString(ns.substring(with: NSRange(location: cursor, length: start - cursor)))
            }
            var chip = AttributedString("[\(n)]")
            chip.foregroundColor = .accentColor
            chip.font = .system(size: 11, weight: .semibold)
            chip.link = URL(string: "fm-citation://\(n)")
            chip.underlineStyle = .single
            chip.baselineOffset = 1
            result += chip
            cursor = end
        }
        if cursor < ns.length {
            result += AttributedString(ns.substring(with: NSRange(location: cursor, length: ns.length - cursor)))
        }
        return result
    }

    /// Parse the declared width/height from an SVG element's opening tag so the
    /// WKWebView and its bubble can be sized to exactly fit the chart content.
    private func svgNaturalSize(_ svg: String) -> CGSize {
        let head = String(svg.prefix(256))
        func attr(_ name: String) -> CGFloat? {
            guard let r = head.range(of: "\(name)=\"") else { return nil }
            let after = head[r.upperBound...]
            guard let q = after.firstIndex(of: "\"") else { return nil }
            let v = CGFloat(Double(String(after[..<q])) ?? 0)
            return v > 0 ? v : nil
        }
        return CGSize(width: attr("width") ?? 540, height: attr("height") ?? 270)
    }
}

/// A small chip on an assistant bubble showing the source count; tap for a
/// popover listing the sources, each clickable to open in the viewer pane.
private struct SourcesButton: View {
    let citations: [Citation]
    let onOpen: (Citation) -> Void
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "quote.opening").font(.system(size: 10, weight: .semibold))
                Text("\(citations.count) \(citations.count == 1 ? "source" : "sources")")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.primary.opacity(0.07), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Show sources")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            SourcesPopover(citations: citations, onOpen: { citation in
                showing = false
                onOpen(citation)
            })
        }
    }
}

/// Brief rundown of an answer's sources, shown in a popover.
private struct SourcesPopover: View {
    let citations: [Citation]
    let onOpen: (Citation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sources")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(citations) { citation in
                Button { onOpen(citation) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: icon(citation)).font(.system(size: 11)).foregroundStyle(.secondary)
                            Text(citation.sourceURL.lastPathComponent)
                                .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(citation.locationLabel)
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                        Text(citation.snippet)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(2).multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open \(citation.sourceURL.lastPathComponent) at \(citation.locationLabel)")
            }
        }
        .padding(12)
        .frame(width: 340)
    }

    private func icon(_ citation: Citation) -> String {
        citation.sourceURL.pathExtension.lowercased() == "pdf" ? "doc.richtext" : "doc.text"
    }
}

/// Inline export button shown in the chart bubble's footer row.
/// Rasterises the chart at 2× and stages it in a new den.
private struct GraphExportButton: View {
    let svg: String

    var body: some View {
        Button(action: export) {
            HStack(spacing: 4) {
                Image(systemName: "square.and.arrow.up").font(.system(size: 10, weight: .semibold))
                Text("Export").font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.primary.opacity(0.07), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Export chart to a new den")
    }

    private func export() {
        guard let svgData = svg.data(using: .utf8),
              let image   = NSImage(data: svgData),
              let png     = rasterize(image, scale: 2).flatMap(pngData)
        else { return }

        let url = Staging.uniqueURL(in: Staging.dir("CHART"), name: "chart.png")
        guard (try? png.write(to: url)) != nil else { return }
        DenManager.shared.openDen(with: [url], placement: .nearCursor)
    }

    private func rasterize(_ image: NSImage, scale: CGFloat) -> NSImage? {
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let out  = NSImage(size: size)
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: size))
        out.unlockFocus()
        return out
    }

    private func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep  = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [.interlaced: false])
    }
}
