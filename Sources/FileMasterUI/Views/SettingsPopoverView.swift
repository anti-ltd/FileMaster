import SwiftUI
import AppKit
import FileMasterCore
import FileMasterAI
import iUX_MacOS

// FileMaster's settings UI exists in two flavours that share one tab catalogue:
//
//   • `SettingsPopoverView`     — the menu-bar popover (segmented bar). It
//                                  carries the pop-out button that opens…
//   • `SettingsWindowRootView`  — a standalone window with a sidebar of the
//                                  same tabs.
//
// The per-tab bodies live in `SettingsTabContent` so the two surfaces stay
// identical without duplication.

public struct SettingsPopoverView: View {
    /// Scene id for the pop-out window. Wired up in `FileMasterApp` and used by
    /// iUX's pop-out button to open the window via `@Environment(\.openWindow)`.
    public static let windowID = "filemaster-settings"

    @State private var selectedTab = SettingsTab.settings

    public init() {}

    public var body: some View {
        // The popover shell (segmented tab switcher + fixed-width content
        // column) is iUX's `SettingsPopover`. FileMaster's popover is narrower
        // than the shared default — 320pt fits the activation menu without
        // wrapping — so pass an explicit width. The `popOutWindowID` parameter
        // is what gives the bar its "open in window" button on the right.
        SettingsPopover(
            selection: $selectedTab,
            width: 320,
            popOutWindowID: Self.windowID
        ) { tab in
            SettingsTabContent(tab: tab)
        }
    }
}

/// The window companion to the popover — a sidebar of the same tabs, same
/// per-tab content. Used inside the SwiftUI `Window` scene declared in
/// `FileMasterApp`; promoted to `.regular` activation while visible so the
/// otherwise-accessory app can accept clicks and surface in Cmd-Tab.
public struct SettingsWindowRootView: View {
    // Selection lives here, not inside iUX's `SettingsWindow` — the generic
    // wrapper can't host the `@State` without `NavigationSplitView` dropping
    // sidebar clicks (rows render, but selection never updates).
    @State private var selection: SettingsTab? = .settings

    public init() {}

    public var body: some View {
        SettingsWindow(title: "FileMaster", selection: $selection) { tab in
            SettingsTabContent(tab: tab)
        }
        // LSUIElement keeps FileMaster out of the Dock and Cmd-Tab; while the
        // settings window is up we promote so it activates and accepts clicks,
        // then drop back so the Dock tile disappears with the window. Matches
        // Clonk's pattern.
        .onAppear { NSApp.setActivationPolicy(.regular) }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
        // Capture SwiftUI's `OpenWindowAction` so AppKit code (the menu-bar
        // "Settings" item) can open this window. The capture happens during
        // SwiftUI's brief auto-open at launch — the suppression in
        // `AppDelegate` closes the window right after, but the captured
        // action stays valid for the process lifetime.
        .background(SettingsWindowOpenerBridge())
    }
}

/// Bridges SwiftUI's `@Environment(\.openWindow)` to AppKit. AppKit menu
/// actions can't reach the SwiftUI environment, so we stash the action into
/// a `@MainActor` static at render time and call it from the AppDelegate.
@MainActor
public enum SettingsWindowOpener {
    public static var action: OpenWindowAction?

    /// Open the pop-out settings window and bring it forward. Safe to call
    /// from anywhere on the main actor.
    public static func open() {
        guard let action else { NSSound.beep(); return }
        action(id: SettingsPopoverView.windowID)
        NSApp.activate(ignoringOtherApps: true)
        // Make the new window key — `openWindow` brings it visible but not
        // key when the calling chain is an NSMenu action (the menu had
        // first-responder), and `List`-based sidebars need key status to
        // hit-test. Same fix as the popover's pop-out button.
        let id = SettingsPopoverView.windowID
        DispatchQueue.main.async {
            for window in NSApp.windows {
                guard let raw = window.identifier?.rawValue, raw.contains(id) else { continue }
                window.makeKeyAndOrderFront(nil)
                break
            }
        }
    }
}

private struct SettingsWindowOpenerBridge: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { SettingsWindowOpener.action = openWindow }
    }
}

// MARK: - Shared tab content

/// The per-tab body, shared between popover and window. Owns the live state
/// (permissions checks, animation triggers) so both surfaces stay in sync
/// without an extra view-model.
struct SettingsTabContent: View {
    let tab: SettingsTab

    @ObservedObject private var settings = FileMasterSettings.shared
    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var fullDiskAccessGranted = SettingsTabContent.checkFullDiskAccess()

    var body: some View {
        Group {
            switch tab {
            case .settings:     settingsTab
            case .intelligence: intelligenceTab
            case .about:        aboutTab
            }
        }
        .onAppear {
            accessibilityGranted = AXIsProcessTrusted()
            fullDiskAccessGranted = Self.checkFullDiskAccess()
        }
        .animation(.easeInOut(duration: 0.15), value: settings.hotkeyActivationEnabled)
        .animation(.easeInOut(duration: 0.15), value: settings.shakeActivationEnabled)
    }

    private var settingsTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingRow(
                title: "Auto-ZIP when sharing folders",
                subtitle: "Skip the share format prompt — always zip.",
                isOn: $settings.autoZipOnShare
            )

            Divider()

            activationSection
        }
    }

    // MARK: - Intelligence tab

    private var intelligenceTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingRow(
                title: "Enable Ask (offline AI)",
                subtitle: "Search and ask questions about your documents — fully offline, on this Mac.",
                isOn: $settings.aiEnabled
            )

            if settings.aiEnabled {
                Divider()

                providerSection

                Divider()

                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Search index")
                            .font(.system(size: 13))
                        Text("Cached text and embeddings for indexed files.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Clear", action: clearIndex)
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                }
            }
        }
        .animation(.easeInOut(duration: 0.15), value: settings.aiEnabled)
    }

    // MARK: - Provider section

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Text("Model")
                    .font(.system(size: 13))
                Spacer()
                Picker("", selection: $settings.llmProvider) {
                    ForEach(LLMConfiguration.Provider.allCases, id: \.rawValue) { p in
                        Text(p.displayName).tag(p.rawValue)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: settings.llmProvider) { _, _ in
                    settings.llmBaseURL = ""
                    settings.llmModel   = ""
                }
            }

            let selected = LLMConfiguration.Provider(rawValue: settings.llmProvider) ?? .appleIntelligence

            if selected == .none {
                Text("Document search only — AI written answers are disabled.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if selected == .appleIntelligence {
                intelligenceStatus
            } else {
                httpProviderFields(for: selected)
            }
        }
    }

    @ViewBuilder private func httpProviderFields(for provider: LLMConfiguration.Provider) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            providerField("Base URL", text: $settings.llmBaseURL,
                          placeholder: provider.defaultBaseURL, isSecure: false)
            providerField("Model", text: $settings.llmModel,
                          placeholder: provider.defaultModel, isSecure: false)
            if provider.requiresAPIKey {
                providerField("API Key", text: $settings.llmAPIKey,
                              placeholder: "sk-…", isSecure: true)
            }
        }
    }

    private func providerField(_ label: String, text: Binding<String>, placeholder: String, isSecure: Bool) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
            Group {
                if isSecure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11))
        }
    }

    @ViewBuilder private var intelligenceStatus: some View {
        let status = llmStatus
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: status.ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(status.ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(status.ok ? "On-device model ready" : "Written answers unavailable")
                    .font(.system(size: 12, weight: .semibold))
                Text(status.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !status.ok {
                    Button("Open System Settings", action: openIntelligenceSettings)
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }
            }
            Spacer()
        }
    }

    private var llmStatus: (ok: Bool, detail: String) {
        if Intelligence.isAvailable {
            return (true, "Answers are written on-device with Apple Intelligence. Retrieval and citations work regardless.")
        }
        return (false, Intelligence.unavailabilityReason
                ?? "The on-device model is unavailable. Ask still finds and cites source passages.")
    }

    private func openIntelligenceSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.AppleIntelligence-Settings.extension")
            ?? URL(string: "x-apple.systempreferences:")!
        NSWorkspace.shared.open(url)
    }

    private func clearIndex() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: Paths.indices, includingPropertiesForKeys: nil) else { return }
        for item in items { try? fm.removeItem(at: item) }
    }

    private func permissionSection(
        title: String,
        systemImage: String,
        description: String,
        statusIcon: String,
        statusText: String,
        statusColor: Color,
        actionTitle: String?,
        action: (() -> Void)?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.subheadline)

            Text(description)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .center, spacing: 8) {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                Text(statusText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(statusColor)
                Spacer()
                if let title = actionTitle, let action = action {
                    Button(title, action: action)
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                }
            }
        }
    }

    private func grantFullDiskAccess() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            fullDiskAccessGranted = Self.checkFullDiskAccess()
        }
    }

    static func checkFullDiskAccess() -> Bool {
        let candidates = [
            "~/Library/Safari/Bookmarks.plist",
            "~/Library/Safari/CloudTabs.db",
            "~/Library/Mail/V10/MailData/Accounts.plist",
            "/Library/Application Support/com.apple.TCC/TCC.db"
        ]
        for c in candidates {
            let path = (c as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: path)
            if let handle = try? FileHandle(forReadingFrom: url) {
                try? handle.close()
                return true
            }
        }
        return false
    }

    private func grantAccessibilityAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            accessibilityGranted = AXIsProcessTrusted()
            if accessibilityGranted {
                GlobalShortcutManager.shared.updateMonitor()
                ShakeDetector.shared.updateMonitor()
            }
        }
    }

    private var aboutTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "FileMaster")
                .font(.title3)
                .fontWeight(.semibold)

            // Pull the version from the bundle so it tracks
            // CFBundleShortVersionString on every release; fall back to "1.0"
            // for non-bundled / dev runs. Matches Clonk's about line.
            let version = Bundle.main
                .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
            Text("Anti Limited - Version \(version)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Divider()

            // Manual update check — same flow Clonk uses. Tapping the button is
            // the *only* trigger; nothing polls in the background.
            UpdatesRow(currentVersion: version)

            Divider()

            // Permissions live under About — same place Clonk surfaces them.
            // They're rarely-touched grant flows, not day-to-day settings.
            permissionSection(
                title: "Accessibility",
                systemImage: "lock.shield",
                description: "Hotkey and shake activation require Accessibility access to work globally.",
                statusIcon: accessibilityGranted ? "checkmark.seal.fill" : "xmark.seal.fill",
                statusText: accessibilityGranted ? "Granted" : "Not granted",
                statusColor: accessibilityGranted ? .green : .red,
                actionTitle: "Grant Access",
                action: grantAccessibilityAccess
            )

            Divider()

            permissionSection(
                title: "Full Disk Access",
                systemImage: "externaldrive.badge.person.crop",
                description: "If you want FileMaster to access protected folders when sharing, enable Full Disk Access for FileMaster.",
                statusIcon: fullDiskAccessGranted ? "checkmark.seal.fill" : "xmark.seal.fill",
                statusText: fullDiskAccessGranted ? "Granted" : "Not granted",
                statusColor: fullDiskAccessGranted ? .green : .red,
                actionTitle: fullDiskAccessGranted ? nil : "Grant Access",
                action: fullDiskAccessGranted ? nil : grantFullDiskAccess
            )

            Text("If the status does not update, open System Settings → Privacy & Security and enable FileMaster for the relevant section.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }

    // MARK: - Activation section

    private var activationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("New Den Activation")
                        .font(.system(size: 13))
                    Text("How to open a new Den.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                activationMenu
            }

            if settings.hotkeyActivationEnabled {
                hotkeyRow
                    .padding(.top, 2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var activationMenu: some View {
        Menu {
            Toggle(isOn: $settings.hotkeyActivationEnabled) {
                Label("Hotkey", systemImage: "keyboard")
            }
            Toggle(isOn: $settings.shakeActivationEnabled) {
                Label("Mouse Shake", systemImage: "arrow.left.and.right")
            }
            Toggle(isOn: $settings.notchActivationEnabled) {
                Label("Notch Drop", systemImage: "rectangle.topthird.inset.filled")
            }
        } label: {
            HStack(spacing: 3) {
                Text(activationSummary)
                    .font(.system(size: 12))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var activationSummary: String {
        let parts = [
            settings.hotkeyActivationEnabled ? "Hotkey" : nil,
            settings.shakeActivationEnabled  ? "Shake"  : nil,
            settings.notchActivationEnabled  ? "Notch"  : nil,
        ].compactMap { $0 }
        return parts.isEmpty ? "None" : parts.joined(separator: ", ")
    }

    // MARK: - Hotkey row

    private var hotkeyRow: some View {
        HStack {
            Text("Shortcut")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            ShortcutRecorderView()
                .frame(width: 96, height: 22)
        }
    }

    // MARK: - Toggle row

    private func settingRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}

// MARK: - Tabs

/// Drives both the popover's segmented bar and the pop-out window's sidebar
/// (via iUX's `SettingsTab`, which refines `SidebarItem`). One enum, two
/// surfaces.
public enum SettingsTab: String, CaseIterable, Identifiable, iUX_MacOS.SettingsTab {
    case settings
    case intelligence
    case about

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .settings:     return "Settings"
        case .intelligence: return "AI"
        case .about:        return "About"
        }
    }

    public var icon: String {
        switch self {
        case .settings:     return "gearshape"
        case .intelligence: return "sparkles"
        case .about:        return "info.circle"
        }
    }
}

// MARK: - Updates row

/// Owns its own state for the manual update check, matching Clonk's About tab.
/// No background polling; nothing fires until the user taps "Check for updates".
private struct UpdatesRow: View {
    let currentVersion: String
    @State private var checkState: UpdateCheckState = .idle

    private enum UpdateCheckState: Equatable {
        case idle
        case checking
        case upToDate(latest: String)
        case updateAvailable(VersionInfo)
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(action: runCheck) {
                    if case .checking = checkState {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Checking…")
                        }
                    } else {
                        Text("Check for updates")
                    }
                }
                .disabled(checkState == .checking)
                Spacer()
            }
            statusView
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch checkState {
        case .idle, .checking:
            EmptyView()
        case .upToDate(let latest):
            Label("Up to date (\(latest))", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 12))
        case .updateAvailable(let info):
            VStack(alignment: .leading, spacing: 4) {
                Label("Update available: \(info.version)", systemImage: "arrow.down.circle.fill")
                    .foregroundStyle(.tint)
                    .font(.system(size: 12))
                if let notes = info.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let url = info.resolvedDownloadURL() {
                    Button("Download…") { NSWorkspace.shared.open(url) }
                        .padding(.top, 2)
                }
            }
        case .failed(let message):
            Label("Check failed: \(message)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 11))
        }
    }

    private func runCheck() {
        checkState = .checking
        let local = currentVersion
        Task { @MainActor in
            do {
                let info = try await UpdateChecker.fetch()
                if UpdateChecker.isNewer(info.version, than: local) {
                    checkState = .updateAvailable(info)
                } else {
                    checkState = .upToDate(latest: info.version)
                }
            } catch {
                checkState = .failed(error.localizedDescription)
            }
        }
    }
}
