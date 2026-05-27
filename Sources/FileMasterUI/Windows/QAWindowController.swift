import AppKit
import SwiftUI
import FileMasterAI

/// Ask + an optional source pane, for the standalone Ask window (used by
/// menu-bar Notebooks, which have no den). Clicking a citation reveals the source
/// beside Ask in the same window — no floating viewer.
private struct AskWindowContent: View {
    let session: QASession
    let onViewingChange: (Bool) -> Void
    @State private var viewing: Citation?
    @State private var siblings: [Citation] = []

    var body: some View {
        HStack(spacing: 0) {
            QAView(session: session,
                   onOpenCitation: { citation, peers in
                       withAnimation { siblings = peers; viewing = citation }
                   })
                .frame(minWidth: 360, maxWidth: viewing == nil ? .infinity : 400)
            if let citation = viewing {
                Divider().opacity(0.4)
                CitationPane(citations: siblings.isEmpty ? [citation] : siblings,
                             active: citation,
                             onSelect: { viewing = $0 },
                             onClose: { withAnimation { viewing = nil; siblings = [] } })
                    .frame(maxWidth: .infinity)
            }
        }
        .background(.ultraThinMaterial)
        .onChange(of: viewing) { _, value in onViewingChange(value != nil) }
    }
}

/// Hosts a single Ask window. Unlike den panels (borderless, non-activating),
/// this is a titled floating panel that can become key — the user types into it.
/// Owns one ``QASession`` for the documents it was opened with.
public final class QAWindowController: NSWindowController, NSWindowDelegate {
    private let askWidth: CGFloat = 440
    private let askViewWidth: CGFloat = 940

    public convenience init(urls: [URL]) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 580),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.title = "Ask"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: 360, height: 420)

        self.init(window: panel)
        panel.delegate = self

        let session = QASession(urls: urls)
        panel.contentView = NSHostingView(rootView:
            AskWindowContent(session: session,
                             onViewingChange: { [weak self] showing in self?.setSourceVisible(showing) }))
        panel.center()
    }

    override init(window: NSWindow?) { super.init(window: window) }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    /// Grow/shrink the window when the source pane shows/hides, keeping the left edge.
    private func setSourceVisible(_ showing: Bool) {
        guard let window else { return }
        var frame = window.frame
        frame.size.width = showing ? askViewWidth : askWidth
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(frame, display: true)
        }
    }

    /// Bring the window forward and focus it so the user can type immediately.
    public func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.post(name: .qaClosed, object: ObjectIdentifier(self))
    }
}
