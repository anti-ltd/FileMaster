// Reel showcase — compiled only in `--showcase` builds (FILEMASTER_SHOWCASE).
// See Makefile: `make showcase`. Never included in production builds.
//
// Manual path: opens the "FileMaster Reel" preview window (with Play / Record
// buttons) from the menu-bar "Reel Showcase…" item. `SettingsWindowRootView`
// installs the bridge via `.background(ReelWindowOpenerBridge())` (also gated
// by FILEMASTER_SHOWCASE) so the AppKit menu can drive SwiftUI's `openWindow`.
//
// The fully-automated `--showcase` launch (see ShowcaseRunner) doesn't use any
// of this — it records straight to a hidden window. This is only for tweaking
// the reel by eye.

#if FILEMASTER_SHOWCASE

import AppKit
import SwiftUI

public enum ReelWindowID {
    public static let id = "filemaster-reel"
}

@MainActor
public enum ReelWindowOpener {
    public static var action: OpenWindowAction?
    public static func open() {
        guard let action else { NSSound.beep(); return }
        action(id: ReelWindowID.id)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            for window in NSApp.windows {
                guard let id = window.identifier?.rawValue, id.contains(ReelWindowID.id) else { continue }
                window.makeKeyAndOrderFront(nil)
                break
            }
        }
    }
}

struct ReelWindowOpenerBridge: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { ReelWindowOpener.action = openWindow }
    }
}

#endif
