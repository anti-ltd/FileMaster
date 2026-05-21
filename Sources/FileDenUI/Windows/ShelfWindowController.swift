import AppKit
import SwiftUI
import FileDenCore

/// A den panel that can become key — needed so the inline Ask text field accepts
/// typing — while staying non-activating (it never brings the app forward).
final class DenPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Hosts a single den. Owns the borderless `NSPanel` and bridges the SwiftUI
/// `ShelfView` to AppKit lifecycle events (resize, empty, close).
public class ShelfWindowController: NSWindowController {
    private var emptyObserver: Any?
    var receivedDrop = false
    var isEmpty = true
    private var currentURLs: [URL] = []

    convenience init(initialURLs: [URL]) {
        let panel = DenPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isMovableByWindowBackground = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        self.init(window: panel)

        self.currentURLs = initialURLs
        self.isEmpty = initialURLs.isEmpty

        let shelfView = ShelfView(
            onClose: { [weak self] in self?.removeDen() },
            onResize: { [weak self] size in self?.animateResize(to: size) },
            onEmpty: { [weak self] handler in self?.registerEmptyHandler(handler) },
            onItemsReceived: { [weak self] in self?.receivedDrop = true },
            onItemsChanged: { [weak self] empty in self?.isEmpty = empty },
            onURLsChanged: { [weak self] urls in self?.currentURLs = urls },
            onAskModeChanged: { [weak self] asking in
                // Make the den key so the inline Ask field can accept typing.
                if asking { self?.window?.makeKeyAndOrderFront(nil) }
            },
            initialURLs: initialURLs
        )
        let hosting = NSHostingView(rootView: shelfView)
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 24
        hosting.layer?.masksToBounds = true
        panel.contentView = hosting
        panel.center()
    }

    override init(window: NSWindow?) { super.init(window: window) }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    // Bound when ShelfView appears; `DenManager.emptyAllDens` posts to this id-filtered observer.
    private func registerEmptyHandler(_ handler: @escaping () -> Void) {
        let id = ObjectIdentifier(self)
        emptyObserver = NotificationCenter.default.addObserver(
            forName: .denEmptyRequested,
            object: nil,
            queue: .main
        ) { note in
            if (note.object as? ObjectIdentifier) == id { handler() }
        }
    }

    private func animateResize(to size: CGSize) {
        guard let window else { return }
        let current = window.frame
        let newFrame = NSRect(
            x: current.midX - size.width / 2,
            y: current.maxY - size.height,
            width: size.width,
            height: size.height
        )
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.38
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(newFrame, display: true)
        }
    }

    private func recordIfNeeded() {
        guard !currentURLs.isEmpty else { return }
        RecentDensStore.shared.record(urls: currentURLs)
    }

    private func removeDen() {
        recordIfNeeded()
        window?.orderOut(nil)
        NotificationCenter.default.post(name: .denClosed, object: ObjectIdentifier(self))
    }

    deinit {
        if let obs = emptyObserver { NotificationCenter.default.removeObserver(obs) }
    }

    /// Bring the den window forward without stealing key-window focus.
    public func show() { window?.orderFrontRegardless() }

    /// Close the den, recording its contents to recents first.
    public override func close() {
        recordIfNeeded()
        window?.orderOut(nil)
        NotificationCenter.default.post(name: .denClosed, object: ObjectIdentifier(self))
    }
}
