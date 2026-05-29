import AppKit
import SwiftUI
import FileMasterCore
import FileMasterAI
import iUX_MacOS

@MainActor
public class AppDelegate: NSObject, NSApplicationDelegate {
    // iUX-MacOS owns the status item, the right-click settings popover, and the
    // left-click app menu. We keep one alive for the process lifetime and rebuild
    // the menu on every click so Recents/Notebooks reflect live state.
    private var menuBar: MenuBarController?
    private var instanceLockFD: Int32 = -1

    // FileMaster is LSUIElement — the menu-bar item is the whole app. The pop-out
    // settings window is a transient surface; closing it must not terminate the
    // process. Without this, AppKit's default returns true the moment a real
    // window closes and the menu bar item disappears.
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    public func applicationWillFinishLaunching(_ notification: Notification) {
        // appstage capture builds skip the single-instance lock so they can run
        // alongside a real FileMaster. Compiled out of normal/release builds.
        #if APPSTAGE
        if AppStageCapture.state != nil { return }
        #endif
        // Reel showcase recorder skips the single-instance lock so it can run
        // alongside a real FileMaster while recording. Compiled out of normal
        // builds (FILEMASTER_SHOWCASE only).
        #if FILEMASTER_SHOWCASE
        if ShowcaseRunner.isActive { return }
        #endif
        // Single instance only. A file lock is the race-safe source of truth:
        // `flock` is atomic, so exactly one process can hold it — two launches
        // racing at the same instant can't both bow out (a symmetric "is another
        // instance running?" check can, leaving zero alive). If we don't get the
        // lock, activate whoever holds it and quit before setting anything up.
        // LSMultipleInstancesProhibited blocks a second `open`; this also covers
        // a binary launched directly (e.g. `make debug`).
        guard acquireInstanceLock() else {
            activateExistingInstance()
            exit(0)
        }
    }

    /// Take an exclusive, non-blocking lock held for the process's lifetime
    /// (the kernel releases it on exit). Returns false if another instance has
    /// it; true if acquired — or if the lock file can't be created, so a
    /// filesystem hiccup never prevents launch.
    private func acquireInstanceLock() -> Bool {
        let id = Bundle.main.bundleIdentifier ?? "ltd.anti.filemaster"
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("\(id).lock")
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return true }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }
        instanceLockFD = fd  // keep open to hold the lock
        return true
    }

    private func activateExistingInstance() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let me = NSRunningApplication.current
        NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .first { $0.processIdentifier != me.processIdentifier }?
            .activate()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // appstage screenshot mode: render one state on-screen (synthetic den /
        // chat) and wait to be captured. Skips the status item and all live
        // services. Compiled in only for capture builds (-DAPPSTAGE).
        #if APPSTAGE
        if let state = AppStageCapture.state {
            AppStageCapture.run(state: state)
            return
        }
        #endif
        // Reel showcase: when launched with `--showcase`, record one 9:16 cycle
        // to the Desktop and quit. No menu bar, no dens, no live services.
        #if FILEMASTER_SHOWCASE
        if ShowcaseRunner.isActive {
            ShowcaseRunner.runAutomated()
            return
        }
        #endif
        // Clear any staging left over from a previous session before any tool
        // writes new output. Safe here: the instance lock means we're the only
        // FileMaster running, so nothing is mid-operation.
        Paths.clearStaging()
        setupMenuBar()
        _ = DenManager.shared
        GlobalShortcutManager.shared.start()
        ShakeDetector.shared.start()
        NotchDropController.shared.start()
        suppressAutoOpenedWindows()
    }

    // SwiftUI's `Window(id:)` scene auto-opens at launch. FileMaster is
    // LSUIElement — the pop-out settings window is opened on demand via the
    // popover's macwindow button. Close just that window if SwiftUI brought
    // it up, identified by `NSWindow.identifier` (SwiftUI sets it from the
    // scene id). A blanket `NSApp.windows` close would also kill the status
    // item's backing window and the menu bar would stop responding to clicks.
    // Dispatched async so the SwiftUI window exists by the time we look.
    private func suppressAutoOpenedWindows() {
        let targetID = SettingsPopoverView.windowID
        DispatchQueue.main.async {
            for window in NSApp.windows {
                guard let id = window.identifier?.rawValue, id.contains(targetID) else { continue }
                window.close()
            }
        }
    }

    private func setupMenuBar() {
        // FileMaster flips the click semantics relative to most menu-bar apps: the
        // left-click menu is the everyday surface (New Den, Recents, Notebooks)
        // and settings sit one right-click away. `activatesOnShow` is required —
        // the popover has text fields (provider URL/key, shortcut recorder) and
        // accessory apps don't activate from a status click, so without it the
        // fields never get keyboard focus.
        menuBar = MenuBarController(
            symbolName: "folder.fill",
            accessibilityLabel: "FileMaster",
            popoverSize: NSSize(width: 320, height: 420),
            rootView: SettingsPopoverView(),
            clickStyle: .leftClickMenu,
            activatesOnShow: true,
            menuProvider: { [weak self] in self?.buildMainMenu() }
        )
    }

    private func buildMainMenu() -> NSMenu {
        let menu = NSMenu()

        let newDenItem = NSMenuItem()
        newDenItem.title = "New Den"
        newDenItem.action = #selector(newDen)
        newDenItem.target = self
        newDenItem.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
        if let (key, mods) = newDenMenuShortcut() {
            newDenItem.keyEquivalent = key
            newDenItem.keyEquivalentModifierMask = mods
        }
        menu.addItem(newDenItem)

        let recents = RecentDensStore.shared.all
        let recentsItem = NSMenuItem(title: "Recents", action: nil, keyEquivalent: "")
        recentsItem.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
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
                    target: self,
                    symbol: "folder"
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
                target: self,
                symbol: "trash"
            ))
        }
        recentsItem.submenu = recentsMenu
        menu.addItem(recentsItem)

        if FileMasterSettings.shared.aiEnabled {
        let notebooks = NotebookStore.shared.notebooks
        let notebooksItem = NSMenuItem(title: "Notebooks", action: nil, keyEquivalent: "")
        notebooksItem.image = NSImage(systemSymbolName: "book.closed", accessibilityDescription: nil)
        let notebooksMenu = NSMenu(title: "Notebooks")
        if notebooks.isEmpty {
            let empty = NSMenuItem(title: "No Notebooks", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            notebooksMenu.addItem(empty)
        } else {
            for notebook in notebooks {
                let item = NSMenuItem(title: notebook.name, action: #selector(openNotebook(_:)),
                                      keyEquivalent: "", target: self, symbol: "book.closed")
                item.representedObject = notebook.id.uuidString
                item.toolTip = notebook.paths.joined(separator: "\n")
                notebooksMenu.addItem(item)
            }
            notebooksMenu.addItem(.separator())
            notebooksMenu.addItem(NSMenuItem(title: "Manage Notebooks…",
                                             action: #selector(manageNotebooks),
                                             keyEquivalent: "", target: self,
                                             symbol: "pencil"))
        }
        notebooksItem.submenu = notebooksMenu
        menu.addItem(notebooksItem)
        }

        menu.addItem(.separator())

        let emptyAll = NSMenuItem(title: "Empty All Dens", action: #selector(emptyAllDens),
                                  keyEquivalent: "", target: self, symbol: "trash")
        emptyAll.isEnabled = DenManager.shared.hasDens
        menu.addItem(emptyAll)

        let closeAll = NSMenuItem(title: "Close All Dens", action: #selector(closeAllDens),
                                  keyEquivalent: "", target: self, symbol: "xmark.circle")
        closeAll.isEnabled = DenManager.shared.hasDens
        menu.addItem(closeAll)

        menu.addItem(.separator())
        // Settings and Quit match Clonk's left-click menu — gearshape and
        // power, ⌘, and ⌘Q.
        menu.addItem(NSMenuItem(title: "Settings", action: #selector(showSettings),
                                keyEquivalent: ",", target: self, symbol: "gearshape"))

        #if FILEMASTER_SHOWCASE
        // Reel showcase — only in `--showcase` builds. Opens the preview window
        // with manual Play / Record controls.
        menu.addItem(NSMenuItem(title: "Reel Showcase…", action: #selector(showReel),
                                keyEquivalent: "", target: self, symbol: "video.fill"))
        #endif

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit",
                                  action: #selector(NSApplication.terminate(_:)),
                                  keyEquivalent: "q")
        quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(quitItem)

        return menu
    }

    @objc private func newDen() {
        DispatchQueue.main.async {
            DenManager.shared.newDen(placement: .nearCursor)
        }
    }

    private func newDenMenuShortcut() -> (String, NSEvent.ModifierFlags)? {
        let s = FileMasterSettings.shared
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

    @objc private func openNotebook(_ sender: NSMenuItem) {
        guard let idString = sender.representedObject as? String,
              let id = UUID(uuidString: idString),
              let notebook = NotebookStore.shared.notebook(id: id) else { return }
        let urls = notebook.existingURLs
        guard !urls.isEmpty else { NSSound.beep(); return }
        DenManager.shared.openAsk(with: urls)
    }

    @objc private func manageNotebooks() { NotebooksWindowController.showShared() }

    // The "Settings" item in the left-click menu opens the pop-out window
    // directly. The right-click popover is the quick-glance surface; clicking
    // "Settings" from the everyday menu is an explicit ask for the full view,
    // so skip the popover step entirely.
    @objc private func showSettings() {
        SettingsWindowOpener.open()
    }

    #if FILEMASTER_SHOWCASE
    @objc private func showReel() {
        ReelWindowOpener.open()
    }
    #endif
}

private extension NSMenuItem {
    /// Convenience that also sets `target` and an optional SF Symbol icon.
    /// Callers that need to drive `representedObject` / `toolTip` keep using
    /// the returned item — the helper just trims the boilerplate around the
    /// AppKit init shape.
    convenience init(title: String, action: Selector?, keyEquivalent: String,
                     target: AnyObject?, symbol: String? = nil) {
        self.init(title: title, action: action, keyEquivalent: keyEquivalent)
        self.target = target
        if let symbol {
            self.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
    }
}
