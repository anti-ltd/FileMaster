import AppKit
import SwiftUI
import FileMasterAI

/// Hosts the single Notebooks manager window. Opening a notebook routes to the
/// Ask window via `DenManager`.
public final class NotebooksWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: NotebooksWindowController?

    /// Show the manager, reusing the existing window if open.
    public static func showShared() {
        if let existing = shared {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = NotebooksWindowController()
        shared = controller
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 460),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "Notebooks"
        self.init(window: window)
        window.delegate = self
        window.center()
        window.contentView = NSHostingView(rootView: NotebooksView { notebook in
            let urls = notebook.existingURLs
            guard !urls.isEmpty else { NSSound.beep(); return }
            DenManager.shared.openAsk(with: urls)
        })
    }

    override init(window: NSWindow?) { super.init(window: window) }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    public func windowWillClose(_ notification: Notification) {
        NotebooksWindowController.shared = nil
    }
}
