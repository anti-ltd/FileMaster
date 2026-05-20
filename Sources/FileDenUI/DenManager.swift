import AppKit
import Foundation
import FileDenCore

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

    public enum Placement {
        case center
        case belowNotch
        case nearCursor
        case origin(NSPoint)
    }

    @discardableResult
    public func newDen(placement: Placement = .center) -> ShelfWindowController {
        if let empty = dens.first(where: { $0.isEmpty && $0.window?.isVisible != true }) {
            positionWindow(for: empty, placement: placement)
            empty.show()
            return empty
        }
        let controller = ShelfWindowController()
        dens.append(controller)
        positionWindow(for: controller, placement: placement)
        controller.show()
        return controller
    }

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

    public func reopenRecent(_ recent: RecentDen) {
        openDen(with: recent.urls)
    }

    public func closeAllDens() {
        dens.forEach { $0.close() }
        dens.removeAll()
    }

    public func emptyAllDens() {
        dens.forEach {
            NotificationCenter.default.post(name: .denEmptyRequested, object: ObjectIdentifier($0))
        }
    }

    public var hasDens: Bool { !dens.isEmpty }
}
