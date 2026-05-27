import Foundation
import FileMasterAI

/// User-tunable settings, persisted to `UserDefaults` and observed by SwiftUI.
///
/// Each property writes through to `UserDefaults` on `didSet`, so flipping a
/// setting from anywhere (the popover, code, defaults write) takes effect
/// immediately for every observer.
final class FileMasterSettings: ObservableObject {
    static let shared = FileMasterSettings()

    /// When true, sharing a folder skips the format prompt and always zips.
    @Published var autoZipOnShare: Bool {
        didSet { UserDefaults.standard.set(autoZipOnShare, forKey: "autoZipOnShare") }
    }

    /// macOS virtual keycode for the global new-den hotkey. `-1` = unset.
    @Published var shortcutKeyCode: Int {
        didSet { UserDefaults.standard.set(shortcutKeyCode, forKey: "shortcutKeyCode") }
    }

    @Published var shortcutModifiers: Int {
        didSet { UserDefaults.standard.set(shortcutModifiers, forKey: "shortcutModifiers") }
    }

    @Published var hotkeyActivationEnabled: Bool {
        didSet { UserDefaults.standard.set(hotkeyActivationEnabled, forKey: "hotkeyActivationEnabled") }
    }

    @Published var shakeActivationEnabled: Bool {
        didSet { UserDefaults.standard.set(shakeActivationEnabled, forKey: "shakeActivationEnabled") }
    }

    @Published var notchActivationEnabled: Bool {
        didSet { UserDefaults.standard.set(notchActivationEnabled, forKey: "notchActivationEnabled") }
    }

    /// Master switch for the offline Ask feature. When false, all Ask/Notebook
    /// affordances are hidden and nothing is indexed.
    @Published var aiEnabled: Bool {
        didSet { UserDefaults.standard.set(aiEnabled, forKey: "aiEnabled") }
    }

    // MARK: - LLM provider

    /// Raw value of `LLMConfiguration.Provider` (e.g. "apple", "openai", "ollama", "llamacpp").
    @Published var llmProvider: String {
        didSet { UserDefaults.standard.set(llmProvider, forKey: "llmProvider") }
    }

    /// Base URL for the OpenAI-compatible endpoint. Empty = use provider default.
    @Published var llmBaseURL: String {
        didSet { UserDefaults.standard.set(llmBaseURL, forKey: "llmBaseURL") }
    }

    /// API key for the provider (required for OpenAI; leave empty for local servers).
    @Published var llmAPIKey: String {
        didSet { UserDefaults.standard.set(llmAPIKey, forKey: "llmAPIKey") }
    }

    /// Model name sent in requests (e.g. "gpt-4o-mini", "llama3.2").
    @Published var llmModel: String {
        didSet { UserDefaults.standard.set(llmModel, forKey: "llmModel") }
    }

    /// Builds an `LLMConfiguration` from the current settings.
    var llmConfiguration: LLMConfiguration {
        let provider = LLMConfiguration.Provider(rawValue: llmProvider) ?? .appleIntelligence
        return LLMConfiguration(provider: provider, baseURL: llmBaseURL, apiKey: llmAPIKey, model: llmModel)
    }

    var hasShortcut: Bool { shortcutKeyCode >= 0 }

    private init() {
        autoZipOnShare = UserDefaults.standard.bool(forKey: "autoZipOnShare")
        let storedCode = UserDefaults.standard.object(forKey: "shortcutKeyCode")
        shortcutKeyCode = storedCode != nil ? UserDefaults.standard.integer(forKey: "shortcutKeyCode") : -1
        shortcutModifiers = UserDefaults.standard.integer(forKey: "shortcutModifiers")
        hotkeyActivationEnabled = UserDefaults.standard.bool(forKey: "hotkeyActivationEnabled")
        shakeActivationEnabled = UserDefaults.standard.bool(forKey: "shakeActivationEnabled")
        notchActivationEnabled = UserDefaults.standard.bool(forKey: "notchActivationEnabled")
        // Both default on: the feature is available out of the box.
        aiEnabled = UserDefaults.standard.object(forKey: "aiEnabled") as? Bool ?? true
        llmProvider = UserDefaults.standard.string(forKey: "llmProvider")
            ?? LLMConfiguration.Provider.appleIntelligence.rawValue
        llmBaseURL = UserDefaults.standard.string(forKey: "llmBaseURL") ?? ""
        llmAPIKey  = UserDefaults.standard.string(forKey: "llmAPIKey")  ?? ""
        llmModel   = UserDefaults.standard.string(forKey: "llmModel")   ?? ""
    }
}
