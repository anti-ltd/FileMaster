import AppKit

/// A simple app-modal text prompt (used for naming/renaming notebooks). Returns
/// the entered text, or nil if cancelled. Uses `NSAlert` so it works reliably
/// from a menu-bar accessory app without a host window.
@MainActor
func promptForText(title: String, message: String, defaultValue: String, confirm: String = "Save") -> String? {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: confirm)
    alert.addButton(withTitle: "Cancel")

    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    field.stringValue = defaultValue
    alert.accessoryView = field
    alert.window.initialFirstResponder = field

    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? defaultValue : value
}
