import AppKit

/// A small floating progress panel for long-running actions (chiefly video
/// conversion). It appears top-center, stacks when several run at once, and only
/// shows if the work outlasts a short grace period — so fast ops (most image and
/// PDF tasks) never flash one up. Mirrors the den's panel style: borderless,
/// non-activating, floats across spaces, ignores clicks.
@MainActor
final class ProgressHUD {
    private static var active: [ProgressHUD] = []
    private static let size = NSSize(width: 280, height: 64)
    private static let topGap: CGFloat = 16
    private static let stackGap: CGFloat = 8

    private let panel: NSPanel
    private let bar: NSProgressIndicator
    private var showTask: Task<Void, Never>?
    private var shownAt: Date?
    private var finished = false

    init(label: String) {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true

        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.size))
        bg.material = .hudWindow
        bg.state = .active
        bg.blendingMode = .behindWindow
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 14
        bg.layer?.masksToBounds = true

        let title = NSTextField(labelWithString: label)
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: 16, y: 34, width: Self.size.width - 32, height: 18)

        let bar = NSProgressIndicator(frame: NSRect(x: 16, y: 18, width: Self.size.width - 32, height: 12))
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.doubleValue = 0

        bg.addSubview(title)
        bg.addSubview(bar)
        panel.contentView = bg

        self.panel = panel
        self.bar = bar

        showTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled, !self.finished else { return }
            self.present()
        }
    }

    /// Set determinate progress, 0…1.
    func update(_ fraction: Double) {
        if bar.isIndeterminate { bar.isIndeterminate = false }
        bar.doubleValue = max(0, min(1, fraction))
    }

    /// Switch to a barber-pole for work whose progress can't be measured.
    func indeterminate() {
        bar.isIndeterminate = true
        bar.startAnimation(nil)
    }

    /// Tear down. If still within the grace period it never appears; if shown,
    /// it lingers briefly so it can't strobe.
    func finish() {
        guard !finished else { return }
        finished = true
        showTask?.cancel()
        guard let shownAt else { return }
        let remaining = 0.3 - Date().timeIntervalSince(shownAt)
        if remaining > 0 {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(remaining))
                self?.dismiss()
            }
        } else {
            dismiss()
        }
    }

    private func present() {
        shownAt = Date()
        Self.active.append(self)
        Self.relayout()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    private func dismiss() {
        Self.active.removeAll { $0 === self }
        Self.relayout()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in panel.orderOut(nil) })
    }

    /// Re-stack the visible HUDs top-center, newest below the rest.
    private static func relayout() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        for (i, hud) in active.enumerated() {
            let x = visible.midX - size.width / 2
            let y = visible.maxY - size.height - topGap - CGFloat(i) * (size.height + stackGap)
            hud.panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }
}
