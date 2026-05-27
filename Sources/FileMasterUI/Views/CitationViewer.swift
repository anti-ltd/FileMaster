import SwiftUI
import AppKit
import PDFKit
import FileMasterAI

/// A pane that shows the sources behind one assistant turn at their exact
/// locations, passage highlighted. Lives inside the den (or the standalone Ask
/// window) as a third pane — no floating windows — so everything for one
/// document set stays in one window.
///
/// The pane shows the full set of citations as a numbered strip across the top
/// (matching the inline `[N]` markers in the answer); the body shows the active
/// one. Use ◀ ▶ or click a number to switch.
struct CitationPane: View {
    let citations: [Citation]
    let active: Citation
    let onSelect: (Citation) -> Void
    let onClose: () -> Void

    private var activeIndex: Int {
        citations.firstIndex(of: active) ?? 0
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if citations.count > 1 {
                Divider().opacity(0.4)
                sourceStrip
            }
            Divider().opacity(0.4)
            CitationContentView(citation: active)
                .id(active.id)   // rebuild when a different citation is shown
        }
        .background(.regularMaterial)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: icon(active)).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(active.sourceURL.lastPathComponent)
                .font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Text(active.locationLabel)
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            if citations.count > 1 {
                navButton("chevron.left", help: "Previous source", enabled: activeIndex > 0) {
                    onSelect(citations[activeIndex - 1])
                }
                Text("\(activeIndex + 1) / \(citations.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: 36)
                navButton("chevron.right", help: "Next source", enabled: activeIndex < citations.count - 1) {
                    onSelect(citations[activeIndex + 1])
                }
            }
            iconButton("arrow.up.forward.app", help: "Open in default app") {
                NSWorkspace.shared.open(active.sourceURL)
            }
            iconButton("xmark", help: "Close source", action: onClose)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(WindowDragHandle())
    }

    /// A horizontally scrollable strip of `[N] filename · loc` chips — one per
    /// citation the turn drew on, in the same order as the inline markers in
    /// the answer. Click to jump.
    private var sourceStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(citations.enumerated()), id: \.element.id) { index, citation in
                    let isActive = citation == active
                    Button { onSelect(citation) } label: {
                        HStack(spacing: 6) {
                            Text("\(index + 1)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(isActive ? Color.white : .accentColor)
                                .frame(width: 16, height: 16)
                                .background(isActive ? Color.accentColor : Color.accentColor.opacity(0.15),
                                            in: Circle())
                            Text(citation.sourceURL.lastPathComponent)
                                .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                                .lineLimit(1)
                            Text(citation.locationLabel)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(
                            Capsule().fill(isActive ? Color.primary.opacity(0.08) : Color.primary.opacity(0.03))
                        )
                        .overlay(
                            Capsule().strokeBorder(isActive ? Color.accentColor.opacity(0.45) : Color.clear,
                                                   lineWidth: 1)
                        )
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("\(citation.sourceURL.lastPathComponent) · \(citation.locationLabel)")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private func icon(_ citation: Citation) -> String {
        citation.sourceURL.pathExtension.lowercased() == "pdf" ? "doc.richtext" : "doc.text"
    }

    @ViewBuilder
    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private func navButton(_ symbol: String, help: String, enabled: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(enabled ? .secondary : Color.secondary.opacity(0.35))
                .frame(width: 22, height: 22)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }
}

/// Native renderer for one citation: a `PDFView` jumped to the page with the
/// passage selected, or an `NSTextView` scrolled to and highlighting the span.
struct CitationContentView: NSViewRepresentable {
    let citation: Citation

    func makeNSView(context: Context) -> NSView {
        switch citation.chunk.locator {
        case .pdfPage(let index, let charRange):
            return makePDF(url: citation.sourceURL, page: index, charRange: charRange)
        case .textRange(let charRange, _):
            return makeText(url: citation.sourceURL, charRange: charRange)
        }
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private func makePDF(url: URL, page: Int, charRange: Range<Int>?) -> NSView {
        guard let document = PDFDocument(url: url) else { return fallback(url) }
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.backgroundColor = .clear
        pdfView.document = document

        guard page >= 0, page < document.pageCount, let pdfPage = document.page(at: page) else { return pdfView }
        pdfView.go(to: pdfPage)
        if let range = charRange, range.lowerBound >= 0,
           let selection = pdfPage.selection(for: NSRange(location: range.lowerBound, length: range.count)) {
            selection.color = .systemYellow
            pdfView.highlightedSelections = [selection]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                pdfView.go(to: selection)
                pdfView.scrollSelectionToVisible(nil)
            }
        }
        return pdfView
    }

    private func makeText(url: URL, charRange: Range<Int>?) -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 14, height: 14)

        let text = Self.displayText(for: url)
        textView.string = text
        scroll.documentView = textView

        if let range = charRange {
            let ns = text as NSString
            let location = max(0, min(range.lowerBound, ns.length))
            let length = max(0, min(range.count, ns.length - location))
            let nsRange = NSRange(location: location, length: length)
            textView.textStorage?.addAttribute(.backgroundColor,
                                               value: NSColor.systemYellow.withAlphaComponent(0.4),
                                               range: nsRange)
            textView.setSelectedRange(nsRange)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                textView.scrollRangeToVisible(nsRange)
            }
        }
        return scroll
    }

    private func fallback(_ url: URL) -> NSView {
        let label = NSTextField(labelWithString: "Couldn't open \(url.lastPathComponent)")
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        return label
    }

    /// The same text the indexer chunked, so stored offsets line up.
    private static func displayText(for url: URL) -> String {
        for segment in TextExtractor.extract(url) {
            if case .wholeText = segment.origin { return segment.text }
        }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}
