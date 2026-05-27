import SwiftUI
import AppKit

/// Transparent overlay that captures a click-or-drag gesture.
/// - On drag past a small threshold, starts a multi-file drag session.
/// - On release without dragging, fires `onTap(modifiers)`.
struct MultiURLDragView: NSViewRepresentable {
    let urls: () -> [URL]
    var onTap: (NSEvent.ModifierFlags) -> Void = { _ in }
    /// Fired on a double-click (no modifiers), e.g. to open the item.
    var onDoubleClick: () -> Void = {}
    /// Right-click / control-click contextual menu provider. Receives the overlay
    /// view so the menu can use it as a host (e.g. positioning a share picker).
    /// Nil means no contextual menu.
    var menu: ((NSView) -> NSMenu?)? = nil
    /// Fired when a drag session ends, with the dragged URLs and the operation
    /// the drop performed (`[]` if cancelled). Lets the owner react to drag-out.
    var onDragEnded: ([URL], NSDragOperation) -> Void = { _, _ in }

    func makeNSView(context: Context) -> DragCaptureView {
        let v = DragCaptureView()
        v.urls = urls
        v.onTap = onTap
        v.onDoubleClick = onDoubleClick
        v.menuProvider = menu
        v.onDragEnded = onDragEnded
        return v
    }

    func updateNSView(_ nsView: DragCaptureView, context: Context) {
        nsView.urls = urls
        nsView.onTap = onTap
        nsView.onDoubleClick = onDoubleClick
        nsView.menuProvider = menu
        nsView.onDragEnded = onDragEnded
    }
}

final class DragCaptureView: NSView, NSDraggingSource {
    var urls: () -> [URL] = { [] }
    var onTap: (NSEvent.ModifierFlags) -> Void = { _ in }
    var onDoubleClick: () -> Void = {}
    var menuProvider: ((NSView) -> NSMenu?)? = nil
    var onDragEnded: ([URL], NSDragOperation) -> Void = { _, _ in }

    private var downPointInWindow: NSPoint?
    private var downEvent: NSEvent?
    private var didStartDrag = false
    private var downModifiers: NSEvent.ModifierFlags = []
    /// Snapshot of what this session is carrying, so the end callback reports the
    /// dragged set even if the selection changes meanwhile.
    private var draggedURLs: [URL] = []

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Always answer for mouse — but let scroll/keyboard pass.
        return self
    }

    // Right-click / control-click: AppKit's default rightMouseDown pops up
    // whatever this returns, positioned at the event.
    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?(self)
    }

    override func mouseDown(with event: NSEvent) {
        downPointInWindow = event.locationInWindow
        downEvent = event
        downModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        didStartDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didStartDrag,
              let down = downPointInWindow,
              let downEvent
        else { return }
        let dx = event.locationInWindow.x - down.x
        let dy = event.locationInWindow.y - down.y
        guard hypot(dx, dy) > 4 else { return }

        let list = urls()
        guard !list.isEmpty else { return }

        didStartDrag = true
        draggedURLs = list
        let items = list.map { url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            let size = NSSize(width: 48, height: 48)
            let frame = NSRect(origin: NSPoint(x: down.x - size.width / 2,
                                               y: down.y - size.height / 2),
                               size: size)
            item.draggingFrame = self.convert(frame, from: nil)
            item.imageComponentsProvider = {
                let comp = NSDraggingImageComponent(key: .icon)
                icon.size = size
                comp.contents = icon
                comp.frame = NSRect(origin: .zero, size: size)
                return [comp]
            }
            return item
        }
        beginDraggingSession(with: items, event: downEvent, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if !didStartDrag {
            if event.clickCount >= 2 && downModifiers.isEmpty {
                onDoubleClick()
            } else {
                onTap(downModifiers)
            }
        }
        downPointInWindow = nil
        downEvent = nil
        didStartDrag = false
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .link, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        onDragEnded(draggedURLs, operation)
        draggedURLs = []
    }
}

/// Reports the hosting `NSWindow` once the view is in the hierarchy. Used to
/// scope window-wide key monitors to the den that owns them.
struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { onResolve(v.window) }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView.window) }
    }
}

/// Overlay that drags the host window via `performDrag`.
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragCaptureView { WindowDragCaptureView() }
    func updateNSView(_ nsView: WindowDragCaptureView, context: Context) {}
}

final class WindowDragCaptureView: NSView {
    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { self }
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

