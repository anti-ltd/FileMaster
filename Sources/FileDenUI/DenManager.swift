import AppKit
import Foundation
import FileDenCore

/// Owns every open den window and routes new-den / close-all requests to them.
///
/// A "den" is a floating panel that holds files the user is shuttling between
/// apps. `DenManager` is the single entry point for opening, reopening from
/// recents, and bulk-closing dens. It listens for ``Notification.Name/newDenRequested``
/// and ``Notification.Name/denClosed`` so subsystems (hotkey, shake, notch)
/// don't need a direct reference.
@MainActor
public class DenManager {
    public static let shared = DenManager()
    private var dens: [ShelfWindowController] = []

    private init() {
        NotificationCenter.default.addObserver(
            forName: .newDenRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.newDen() }
        }

        NotificationCenter.default.addObserver(
            forName: .denClosed,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let id = note.object as? ObjectIdentifier else { return }
            MainActor.assumeIsolated {
                self?.dens.removeAll { ObjectIdentifier($0) == id }
            }
        }
    }

    /// Where a freshly-opened den should appear on screen.
    public enum Placement {
        /// Center of the main screen. Cascades by 30pt when multiple dens are open.
        case center
        /// Tucked under the notch — used by notch-drop activation.
        case belowNotch
        /// Down-and-right of the mouse cursor — used by hotkey and shake.
        case nearCursor
        /// Explicit screen origin.
        case origin(NSPoint)
    }

    /// Open a new empty den. Reuses an existing hidden-empty den if one exists
    /// so spam-pressing the hotkey doesn't pile up windows.
    @discardableResult
    public func newDen(placement: Placement = .center) -> ShelfWindowController {
        if let empty = dens.first(where: { $0.isEmpty && $0.window?.isVisible != true }) {
            positionWindow(for: empty, placement: placement)
            empty.show()
            return empty
        }
        let controller = ShelfWindowController(initialURLs: [])
        dens.append(controller)
        positionWindow(for: controller, placement: placement)
        controller.show()
        return controller
    }

    /// Open a den pre-populated with `urls`. URLs that no longer exist on disk
    /// are filtered out; if nothing survives, an empty den is opened instead.
    @discardableResult
    public func openDen(with urls: [URL], placement: Placement = .center) -> ShelfWindowController {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return newDen(placement: placement) }
        let controller = ShelfWindowController(initialURLs: existing)
        dens.append(controller)
        positionWindow(for: controller, placement: placement)
        controller.show()
        return controller
    }

    private func positionWindow(for controller: ShelfWindowController, placement: Placement) {
        guard let window = controller.window else { return }
        let frame = window.frame
        let size = frame.size

        let origin: NSPoint
        switch placement {
        case .center:
            guard let screen = NSScreen.main else { return }
            let s = screen.visibleFrame
            var x = s.midX - size.width / 2
            var y = s.midY - size.height / 2
            let others = dens.filter { $0 !== controller && $0.window?.isVisible == true }
            if !others.isEmpty {
                let offset = CGFloat(min(others.count, 6)) * 30
                x += offset
                y -= offset
                x = max(s.minX + 8, min(x, s.maxX - size.width - 8))
                y = max(s.minY + 8, min(y, s.maxY - size.height - 8))
            }
            origin = NSPoint(x: x, y: y)
        case .belowNotch:
            guard let screen = NSScreen.main else { return }
            let s = screen.visibleFrame
            origin = NSPoint(x: s.midX - size.width / 2, y: s.maxY - size.height - 16)
        case .nearCursor:
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
            guard let screen else { return }
            let s = screen.visibleFrame
            // Offset down-right of cursor so it doesn't sit under the pointer
            var x = mouse.x + 20
            var y = mouse.y - size.height - 20
            x = max(s.minX + 8, min(x, s.maxX - size.width - 8))
            y = max(s.minY + 8, min(y, s.maxY - size.height - 8))
            origin = NSPoint(x: x, y: y)
        case .origin(let p):
            origin = p
        }
        window.setFrameOrigin(origin)
    }

    /// Reopen a den from the recents list. Equivalent to `openDen(with: recent.urls)`.
    public func reopenRecent(_ recent: RecentDen) {
        openDen(with: recent.urls)
    }

    /// Close every open den. Each den records its contents to recents on the way out.
    public func closeAllDens() {
        dens.forEach { $0.close() }
        dens.removeAll()
    }

    /// Empty every open den (keep the windows, drop their files). Items are
    /// recorded to recents before they vanish.
    public func emptyAllDens() {
        dens.forEach {
            NotificationCenter.default.post(name: .denEmptyRequested, object: ObjectIdentifier($0))
        }
    }

    public var hasDens: Bool { !dens.isEmpty }
}
