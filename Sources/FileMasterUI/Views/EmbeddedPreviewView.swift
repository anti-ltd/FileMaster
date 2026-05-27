import SwiftUI
import AppKit
import QuickLookUI

/// The embedded Quick Look pane — mirrors `ImageEditorView`'s layout (header on
/// top, content below) but the body is an in-process `QLPreviewView` rather than
/// the system Quick Look panel. Lets the user scrub, scroll, copy text, etc.
/// directly inside the den's expanded window for *any* file QL can preview.
struct EmbeddedPreviewView: View {
    let url: URL
    var onClose: () -> Void
    var onOpen: () -> Void
    var onReveal: () -> Void
    /// Hands the supplied view to the den's share picker so the popover anchors
    /// to it (matching the editor / Ask flow).
    var onShare: (NSView) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            QLPreviewRepresentable(url: url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "eye").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                Text(statusLine)
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            // `NSViewRepresentable` has no intrinsic size, so without an explicit
            // frame the share button greedily fills the header — that's the empty
            // rounded shape that used to sit in the middle of the pane.
            ShareHostingButton(symbol: "square.and.arrow.up", help: "Share", onTap: onShare)
                .frame(width: 28, height: 28)
            iconButton("arrow.up.forward.app", help: "Open with default app", action: onOpen)
            iconButton("folder", help: "Reveal in Finder", action: onReveal)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Close preview")
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .background(WindowDragHandle())
    }

    /// "1024 × 768 · 240 KB" for images, "1.2 MB · PDF" otherwise — keeps the
    /// header informative without re-implementing per-type metadata.
    private var statusLine: String {
        var parts: [String] = []
        if let size = url.pixelSize {
            parts.append("\(Int(size.width))×\(Int(size.height))")
        }
        if let bytes = url.allocatedSize {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        }
        let ext = url.pathExtension.uppercased()
        if !ext.isEmpty { parts.append(ext) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func iconButton(_ symbol: String, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - QLPreviewView bridge

/// Wraps `QLPreviewView` (AppKit) so SwiftUI can host it. We recreate the
/// preview item whenever the URL changes — `QLPreviewView` doesn't reliably
/// refresh in place when the underlying item is swapped on the same instance.
private struct QLPreviewRepresentable: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        // `.normal` style strips the system panel's chrome (it lives in our own
        // header instead) and gives us the bare content area.
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.shouldCloseWithWindow = false
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        // `previewItem` is identity-compared internally, so always reassign when
        // the URL changes; otherwise switching tabs would leave the old preview.
        let current = (nsView.previewItem as? NSURL) as URL?
        if current != url {
            nsView.previewItem = url as NSURL
        }
    }

    static func dismantleNSView(_ nsView: QLPreviewView, coordinator: ()) {
        nsView.close()
    }
}

// MARK: - Share button (NSView host so the share picker can anchor to it)

/// The share popover needs a real `NSView` to point at, but a plain SwiftUI
/// `Button` doesn't expose one. This hosts a tiny `NSButton` and passes itself
/// to `onTap`, matching what the actions menu does for the share menu item.
private struct ShareHostingButton: NSViewRepresentable {
    let symbol: String
    let help: String
    let onTap: (NSView) -> Void

    func makeNSView(context: Context) -> NSButton {
        let b = NSButton()
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.imagePosition = .imageOnly
        b.toolTip = help
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)?
            .withSymbolConfiguration(cfg)
        b.contentTintColor = .secondaryLabelColor
        b.target = context.coordinator
        b.action = #selector(Coordinator.fire(_:))
        b.frame = NSRect(x: 0, y: 0, width: 28, height: 28)
        b.wantsLayer = true
        b.layer?.cornerRadius = 14
        b.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.6).cgColor
        return b
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.onTap = onTap
    }

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    final class Coordinator: NSObject {
        var onTap: (NSView) -> Void
        init(onTap: @escaping (NSView) -> Void) { self.onTap = onTap }
        @objc func fire(_ sender: NSButton) { onTap(sender) }
    }
}

// MARK: - URL pixel-size helper

private extension URL {
    /// Pixel dimensions for image URLs, nil otherwise. Cheap header read via
    /// `CGImageSource` — doesn't decode pixel data.
    var pixelSize: CGSize? {
        guard let src = CGImageSourceCreateWithURL(self as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let h = props[kCGImagePropertyPixelHeight] as? CGFloat,
              w > 0, h > 0
        else { return nil }
        return CGSize(width: w, height: h)
    }
}
