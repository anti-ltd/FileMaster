import SwiftUI
import AppKit
import FileMasterUI

// Dev tool: `--icon <dir>` renders the AppIcon.iconset folder, then exits.
// The handler runs before `App` body composition by intercepting argv on the
// AppDelegate's `applicationDidFinishLaunching`. See FileMasterUI/AppDelegate.
@main
struct FileMasterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // Run the icon renderer synchronously *before* SwiftUI's App lifecycle
        // touches anything. This matches Clonk's pattern but moves the check
        // out of AppDelegate so it works without an event loop, which keeps
        // `make icon` fast and headless.
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--icon"), idx + 1 < args.count {
            AppIconRenderer.run(directory: args[idx + 1])
            exit(0)
        }
    }

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

        #if FILEMASTER_SHOWCASE
        // Reel showcase — only in `--showcase` builds. The preview window with
        // manual Play / Record controls. See Sources/FileMasterUI/Showcase.
        Window("FileMaster Reel", id: ReelWindowID.id) {
            ReelSceneView()
                .onAppear { NSApp.setActivationPolicy(.regular) }
                .onDisappear { NSApp.setActivationPolicy(.accessory) }
        }
        .defaultSize(width: 360, height: 712)
        .windowResizability(.contentSize)
        #endif

        Settings { EmptyView() }
    }
}
