import AppKit
import QuickLook
import QuickLookUI

/// Drives the shared Quick Look panel for an arbitrary set of files. The data
/// source lives here (a singleton) rather than on a transient view so the panel
/// stays alive and focused after the triggering view goes away.
final class QuickLookController: NSObject {
    static let shared = QuickLookController()

    private var urls: [URL] = []

    /// Show — or refocus — the Quick Look panel for `urls`, making it the key
    /// window so it can be navigated and dismissed from the keyboard.
    func preview(_ urls: [URL]) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        panel.dataSource = self
        panel.delegate = self
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
    }
}

extension QuickLookController: QLPreviewPanelDataSource {
    func numberOfPreviewItems(in panel: QLPreviewPanel) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel, previewItemAt index: Int) -> QLPreviewItem {
        urls[index] as NSURL
    }
}

extension QuickLookController: QLPreviewPanelDelegate {}
