import AppKit
import Combine

final class GlobalShortcutManager {
    static let shared = GlobalShortcutManager()

    private var monitor: Any?
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    func start() {
        FileMasterSettings.shared.$shortcutKeyCode
            .combineLatest(FileMasterSettings.shared.$shortcutModifiers)
            .combineLatest(FileMasterSettings.shared.$hotkeyActivationEnabled)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.updateMonitor() }
            .store(in: &cancellables)
        updateMonitor()
    }

    func updateMonitor() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        let s = FileMasterSettings.shared
        guard s.hasShortcut && s.hotkeyActivationEnabled else { return }
        let keyCode = UInt16(s.shortcutKeyCode)
        let mods = NSEvent.ModifierFlags(rawValue: UInt(s.shortcutModifiers))
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == keyCode,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == mods
            else { return }
            DispatchQueue.main.async { DenManager.shared.newDen(placement: .nearCursor) }
        }
    }
}
