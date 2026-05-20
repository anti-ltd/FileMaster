import AppKit
import SwiftUI
import FileDenCore

@MainActor
public class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    private var settingsPopover: NSPopover?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        _ = DenManager.shared
        GlobalShortcutManager.shared.start()
        ShakeDetector.shared.start()
        NotchDropController.shared.start()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "FileDen")
            button.action = #selector(handleStatusClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self
        }
    }

    @objc private func handleStatusClick() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showSettings()
        } else {
            showMainMenu()
        }
    }

    private func showMainMenu() {
        let menu = NSMenu()

        let newDenItem = NSMenuItem()
        newDenItem.title = "New Den"
        newDenItem.action = #selector(newDen)
        newDenItem.target = self
        if let (key, mods) = newDenMenuShortcut() {
            newDenItem.keyEquivalent = key
            newDenItem.keyEquivalentModifierMask = mods
        }
        menu.addItem(newDenItem)

        let recents = RecentDensStore.shared.all
        let recentsItem = NSMenuItem(title: "Recents", action: nil, keyEquivalent: "")
        let recentsMenu = NSMenu(title: "Recents")
        if recents.isEmpty {
            let empty = NSMenuItem(title: "No Recent Dens", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentsMenu.addItem(empty)
        } else {
            for recent in recents {
                let item = NSMenuItem(
                    title: recent.title,
                    action: #selector(openRecent(_:)),
                    keyEquivalent: "",
                    target: self
                )
                item.representedObject = recent.id.uuidString
                item.toolTip = recent.paths.joined(separator: "\n")
                recentsMenu.addItem(item)
            }
            recentsMenu.addItem(.separator())
            recentsMenu.addItem(NSMenuItem(
                title: "Clear Recent Dens",
                action: #selector(clearRecents),
                keyEquivalent: "",
                target: self
            ))
        }
        recentsItem.submenu = recentsMenu
        menu.addItem(recentsItem)

        menu.addItem(.separator())

        let emptyAll = NSMenuItem(title: "Empty All Dens", action: #selector(emptyAllDens), keyEquivalent: "", target: self)
        emptyAll.isEnabled = DenManager.shared.hasDens
        menu.addItem(emptyAll)

        let closeAll = NSMenuItem(title: "Close All Dens", action: #selector(closeAllDens), keyEquivalent: "", target: self)
        closeAll.isEnabled = DenManager.shared.hasDens
        menu.addItem(closeAll)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings", action: #selector(showSettings), keyEquivalent: ",", target: self))

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        showMenu(menu)
    }

    private func showMenu(_ menu: NSMenu) {
        guard let button = statusItem?.button else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: button)
    }

    @objc private func newDen() {
        DispatchQueue.main.async {
            DenManager.shared.newDen(placement: .center)
        }
    }

    private func newDenMenuShortcut() -> (String, NSEvent.ModifierFlags)? {
        let s = FileDenSettings.shared
        guard s.hasShortcut, s.hotkeyActivationEnabled else { return nil }
        guard let key = Self.keyEquivalent(for: UInt16(s.shortcutKeyCode)) else { return nil }
        let mods = NSEvent.ModifierFlags(rawValue: UInt(s.shortcutModifiers))
            .intersection(.deviceIndependentFlagsMask)
        return (key, mods)
    }

    private static func keyEquivalent(for keyCode: UInt16) -> String? {
        let map: [UInt16: String] = [
            0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x",
            8: "c", 9: "v", 11: "b", 12: "q", 13: "w", 14: "e", 15: "r",
            16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p",
            37: "l", 38: "j", 39: "'", 40: "k", 41: ";", 42: "\\",
            43: ",", 44: "/", 45: "n", 46: "m", 47: ".", 49: " ",
            50: "`",
            123: String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)),
            124: String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)),
            125: String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)),
            126: String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)),
            122: String(Character(UnicodeScalar(NSF1FunctionKey)!)),
            120: String(Character(UnicodeScalar(NSF2FunctionKey)!)),
            99:  String(Character(UnicodeScalar(NSF3FunctionKey)!)),
            118: String(Character(UnicodeScalar(NSF4FunctionKey)!)),
            96:  String(Character(UnicodeScalar(NSF5FunctionKey)!)),
            97:  String(Character(UnicodeScalar(NSF6FunctionKey)!)),
            98:  String(Character(UnicodeScalar(NSF7FunctionKey)!)),
            100: String(Character(UnicodeScalar(NSF8FunctionKey)!)),
            101: String(Character(UnicodeScalar(NSF9FunctionKey)!)),
            109: String(Character(UnicodeScalar(NSF10FunctionKey)!)),
            103: String(Character(UnicodeScalar(NSF11FunctionKey)!)),
            111: String(Character(UnicodeScalar(NSF12FunctionKey)!)),
        ]
        return map[keyCode]
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let idString = sender.representedObject as? String,
              let id = UUID(uuidString: idString),
              let recent = RecentDensStore.shared.all.first(where: { $0.id == id })
        else { return }
        DenManager.shared.reopenRecent(recent)
    }

    @objc private func clearRecents() { RecentDensStore.shared.clear() }
    @objc private func emptyAllDens() { DenManager.shared.emptyAllDens() }
    @objc private func closeAllDens() { DenManager.shared.closeAllDens() }

    @objc private func showSettings() {
        if settingsPopover == nil {
            let popover = NSPopover()
            let host = NSHostingController(rootView: SettingsPopoverView())
            host.sizingOptions = [.preferredContentSize]
            popover.contentViewController = host
            popover.behavior = .transient
            settingsPopover = popover
        }
        guard let button = statusItem?.button, let popover = settingsPopover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}

private extension NSMenuItem {
    convenience init(title: String, action: Selector?, keyEquivalent: String, target: AnyObject?) {
        self.init(title: title, action: action, keyEquivalent: keyEquivalent)
        self.target = target
    }
}
