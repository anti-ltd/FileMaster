import AppKit
import Combine

final class ShakeDetector {
    static let shared = ShakeDetector()

    private var dragMonitor: Any?
    private var releaseMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    // Rolling window of (deltaX, timestamp) samples — only populated during drag
    private var samples: [(dx: CGFloat, t: TimeInterval)] = []
    private var lastTrigger: TimeInterval = 0
    // Den opened by the current shake gesture — closed on mouseUp if nothing was dropped in
    private weak var shakeDen: ShelfWindowController?

    private static let windowDuration: TimeInterval = 0.45
    private static let minReversals = 4        // 4 sign-changes ≈ 3 full shakes
    private static let minSegmentDelta: CGFloat = 8
    private static let cooldown: TimeInterval = 1.0

    private init() {}

    func start() {
        FileMasterSettings.shared.$shakeActivationEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateMonitor() }
            .store(in: &cancellables)
        updateMonitor()
    }

    func updateMonitor() {
        if let m = dragMonitor    { NSEvent.removeMonitor(m); dragMonitor    = nil }
        if let m = releaseMonitor { NSEvent.removeMonitor(m); releaseMonitor = nil }
        guard FileMasterSettings.shared.shakeActivationEnabled else { return }
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
            self?.handle(event)
        }
        releaseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            self?.samples.removeAll()
            guard let self, let den = self.shakeDen else { return }
            self.shakeDen = nil
            // Small delay lets the drop handler fire before we decide to close
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                if !den.receivedDrop { den.close() }
            }
        }
    }

    private func handle(_ event: NSEvent) {
        let dx = event.deltaX
        guard abs(dx) >= 1 else { return }

        let now = ProcessInfo.processInfo.systemUptime
        samples.append((dx: dx, t: now))

        // Prune outside window
        samples = samples.filter { now - $0.t < Self.windowDuration }

        guard samples.count >= 3 else { return }

        // Count direction reversals above the per-segment movement threshold
        var reversals = 0
        var accumulated: CGFloat = 0
        var lastSign: CGFloat = samples[0].dx.sign

        for s in samples.dropFirst() {
            let sign = s.dx.sign
            if sign == lastSign {
                accumulated += abs(s.dx)
            } else {
                if accumulated >= Self.minSegmentDelta { reversals += 1 }
                accumulated = abs(s.dx)
                lastSign = sign
            }
        }

        guard reversals >= Self.minReversals else { return }
        guard now - lastTrigger >= Self.cooldown else { return }

        lastTrigger = now
        samples.removeAll()
        DispatchQueue.main.async { @MainActor [weak self] in
            let den = DenManager.shared.newDen(placement: .nearCursor)
            self?.shakeDen = den
        }
    }
}

private extension CGFloat {
    var sign: CGFloat { self >= 0 ? 1 : -1 }
}
