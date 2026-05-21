import SwiftUI
import AppKit
import PDFKit
import FileDenAI

/// A pane that shows a single citation's source at its exact location, with the
/// cited passage highlighted. Lives inside the den (or the standalone Ask window)
/// as a third pane — no floating windows — so everything for one document set
/// stays in one window. Only one citation is shown at a time.
struct CitationPane: View {
    let citation: Citation
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 12)).foregroundStyle(.secondary)
                Text(citation.sourceURL.lastPathComponent)
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(citation.locationLabel)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Button(action: { NSWorkspace.shared.open(citation.sourceURL) }) {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Open in default app")
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Close source")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(WindowDragHandle())

            Divider().opacity(0.4)

            CitationContentView(citation: citation)
                .id(citation.id)   // rebuild when a different citation is shown
        }
        .background(.regularMaterial)
    }

    private var icon: String {
        citation.sourceURL.pathExtension.lowercased() == "pdf" ? "doc.richtext" : "doc.text"
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
