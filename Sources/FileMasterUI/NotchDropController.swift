import AppKit
import SwiftUI
import Combine

@MainActor
final class NotchDropController {
    static let shared = NotchDropController()

    private var panel: NSPanel?
    private var cancellables = Set<AnyCancellable>()
    private var screenObserver: NSObjectProtocol?
    private var dragMonitor: Any?
    private var releaseMonitor: Any?
    private var dragActive = false

    private init() {}

    func start() {
        FileMasterSettings.shared.$notchActivationEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                enabled ? self?.show() : self?.hide()
            }
            .store(in: &cancellables)
        if FileMasterSettings.shared.notchActivationEnabled { show() }
    }

    private func show() {
        if panel != nil { reposition(); return }
        guard let screen = NSScreen.main else { return }

        let size = NotchDropController.preferredSize(for: screen)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.isMovable = false

        let notchSize = NotchDropController.notchSize(for: screen)
        let view = NotchDropView(notchSize: notchSize) { urls in
            DenManager.shared.openDen(with: urls, placement: .belowNotch)
        }
        panel.contentView = NSHostingView(rootView: view)

        self.panel = panel
        reposition()
        panel.orderFrontRegardless()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reposition() }
        }

        installDragMonitors()
    }

    private func installDragMonitors() {
        if dragMonitor == nil {
            dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
                Task { @MainActor in self?.checkForFileDrag() }
            }
        }
        if releaseMonitor == nil {
            releaseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
                Task { @MainActor in self?.endDrag() }
            }
        }
    }

    private func removeDragMonitors() {
        if let m = dragMonitor    { NSEvent.removeMonitor(m); dragMonitor    = nil }
        if let m = releaseMonitor { NSEvent.removeMonitor(m); releaseMonitor = nil }
        endDrag()
    }

    private func checkForFileDrag() {
        guard !dragActive, let panel else { return }
        let pb = NSPasteboard(name: .drag)
        guard pb.types?.contains(.fileURL) == true else { return }
        dragActive = true
        panel.ignoresMouseEvents = false
    }

    private func endDrag() {
        dragActive = false
        panel?.ignoresMouseEvents = true
    }

    private func hide() {
        removeDragMonitors()
        panel?.orderOut(nil)
        panel = nil
        if let obs = screenObserver {
            NotificationCenter.default.removeObserver(obs)
            screenObserver = nil
        }
    }

    private func reposition() {
        guard let panel, let screen = NSScreen.main else { return }
        let size = NotchDropController.preferredSize(for: screen)
        let x = screen.frame.midX - size.width / 2
        let y = screen.frame.maxY - size.height
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    private static let glowPadding: CGFloat = 40

    static func notchSize(for screen: NSScreen) -> CGSize {
        let topInset = screen.safeAreaInsets.top
        if topInset > 0 {
            let leftWidth = screen.auxiliaryTopLeftArea?.width ?? 0
            let rightWidth = screen.auxiliaryTopRightArea?.width ?? 0
            let notchWidth = screen.frame.width - leftWidth - rightWidth
            return CGSize(width: max(notchWidth, 100), height: topInset)
        }
        return CGSize(width: 180, height: 28)
    }

    private static func preferredSize(for screen: NSScreen) -> CGSize {
        let n = notchSize(for: screen)
        return CGSize(width: n.width + glowPadding * 2, height: n.height + glowPadding)
    }
}

private struct NotchDropView: View {
    let notchSize: CGSize
    let onDrop: ([URL]) -> Void
    @State private var isTargeted = false

    private var cornerRadius: CGFloat { min(notchSize.height, 12) }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.accentColor)
                    .frame(
                        width: max(notchSize.width - 10, 40),
                        height: max(notchSize.height - 4, 12)
                    )
                    .blur(radius: 16)
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.accentColor)
                    .frame(
                        width: max(notchSize.width - 18, 30),
                        height: max(notchSize.height - 8, 8)
                    )
                    .blur(radius: 8)
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white)
                    .frame(
                        width: max(notchSize.width - 30, 20),
                        height: max(notchSize.height - 14, 4)
                    )
                    .blur(radius: 6)
                    .opacity(0.7)
            }
            .opacity(isTargeted ? 1 : 0)
            .animation(.easeInOut(duration: 0.22), value: isTargeted)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            var urls: [URL] = []
            let group = DispatchGroup()
            for provider in providers {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { urls.append(url) }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                guard !urls.isEmpty else { return }
                onDrop(urls)
            }
            return true
        }
    }
}
