import SwiftUI
import AppKit

struct ShortcutRecorderView: NSViewRepresentable {
    @ObservedObject private var settings = FileMasterSettings.shared

    func makeNSView(context: Context) -> RecorderNSView { RecorderNSView() }

    func updateNSView(_ nsView: RecorderNSView, context: Context) { nsView.refresh() }

    // MARK: - RecorderNSView

    class RecorderNSView: NSView {
        private var isRecording = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.cornerRadius = 5
            layer?.borderWidth = 1.5
            updateStyle()
        }

        required init?(coder: NSCoder) { fatalError() }

        override var intrinsicContentSize: NSSize { NSSize(width: 90, height: 22) }
        override var acceptsFirstResponder: Bool { true }

        func refresh() { updateStyle(); needsDisplay = true }

        private func updateStyle() {
            if isRecording {
                layer?.borderColor = NSColor.controlAccentColor.cgColor
                layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
            } else {
                layer?.borderColor = NSColor.separatorColor.cgColor
                layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            let label: String
            let color: NSColor
            if isRecording {
                label = "Type shortcut…"
                color = .secondaryLabelColor
            } else if FileMasterSettings.shared.hasShortcut {
                label = shortcutString()
                color = .labelColor
            } else {
                label = "Click to set"
                color = .placeholderTextColor
            }
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: color,
                .paragraphStyle: para
            ]
            let str = NSAttributedString(string: label, attributes: attrs)
            let sz = str.size()
            str.draw(at: NSPoint(x: (bounds.width - sz.width) / 2, y: (bounds.height - sz.height) / 2))
        }

        private func shortcutString() -> String {
            let s = FileMasterSettings.shared
            let mods = NSEvent.ModifierFlags(rawValue: UInt(s.shortcutModifiers))
            var result = ""
            if mods.contains(.control) { result += "⌃" }
            if mods.contains(.option)  { result += "⌥" }
            if mods.contains(.shift)   { result += "⇧" }
            if mods.contains(.command) { result += "⌘" }
            result += Self.keyLabel(for: UInt16(s.shortcutKeyCode))
            return result
        }

        static func keyLabel(for keyCode: UInt16) -> String {
            let map: [UInt16: String] = [
                0: "A",  1: "S",  2: "D",  3: "F",  4: "H",  5: "G",  6: "Z",  7: "X",
                8: "C",  9: "V",  11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
                16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
                23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
                30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
                37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
                43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥",
                49: "Space", 50: "`", 51: "⌫",
                65: ".", 67: "*", 69: "+", 75: "/", 76: "↩", 78: "-", 81: "=",
                82: "0", 83: "1", 84: "2", 85: "3", 86: "4", 87: "5",
                88: "6", 89: "7", 91: "8", 92: "9",
                96: "F5", 97: "F6", 98: "F7",  99: "F3", 100: "F8",
                101: "F9", 103: "F11", 109: "F10", 111: "F12",
                118: "F4", 120: "F2", 122: "F1",
                123: "←", 124: "→", 125: "↓", 126: "↑",
            ]
            return map[keyCode] ?? "[\(keyCode)]"
        }

        // MARK: - Events

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            isRecording = true
            updateStyle()
            needsDisplay = true
        }

        override func keyDown(with event: NSEvent) {
            guard isRecording else { super.keyDown(with: event); return }
            let keyCode = event.keyCode
            if keyCode == 53 { // Escape = unbind
                FileMasterSettings.shared.shortcutKeyCode = -1
                FileMasterSettings.shared.shortcutModifiers = 0
                stopRecording()
                return
            }
            if keyCode == 36 || keyCode == 48 { stopRecording(); return } // Enter/Tab = cancel
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard !mods.isEmpty else { return } // require a modifier
            FileMasterSettings.shared.shortcutKeyCode = Int(keyCode)
            FileMasterSettings.shared.shortcutModifiers = Int(mods.rawValue)
            stopRecording()
        }

        override func resignFirstResponder() -> Bool {
            if isRecording { stopRecording() }
            return super.resignFirstResponder()
        }

        private func stopRecording() {
            isRecording = false
            updateStyle()
            needsDisplay = true
        }
    }
}
