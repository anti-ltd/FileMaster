import SwiftUI
import AppKit
import FileMasterUI

@main
struct FileMasterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // The pop-out settings window. The popover's macwindow button opens
        // this id via `@Environment(\.openWindow)`. A SwiftUI `Window` scene
        // (not a hand-built `NSWindow`) is what gives `NavigationSplitView`
        // the unified toolbar, transparent titlebar, and vibrant sidebar —
        // chrome that `NSWindow(contentViewController:)` can't reproduce.
        Window("FileMaster", id: SettingsPopoverView.windowID) {
            SettingsWindowRootView()
        }
        .defaultSize(width: 740, height: 560)
        .windowToolbarStyle(.unified)

        Settings { EmptyView() }
    }
}
