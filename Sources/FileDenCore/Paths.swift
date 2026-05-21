import Foundation

/// On-disk home for everything FileDen persists. Every counter-ltd app keeps its
/// files together under one org-scoped root so they're easy to find, back up, and
/// remove:
///
///   ~/Library/Application Support/counter-ltd/fileden/
///
/// (Settings and the recents list still live in `UserDefaults`; this is the home
/// for actual files the app produces.)
public enum Paths {
    /// The app's storage root. Created on first access.
    public static let appSupport: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("counter-ltd/fileden", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// Scratch space for files produced by tools (PDF ops, conversions, archives)
    /// before the user files them away. It lives under the app root rather than
    /// the system temp dir so all of FileDen's output stays in one predictable
    /// place. Because Application Support isn't auto-reclaimed like `/tmp`,
    /// `clearStaging()` empties it at launch so nothing accumulates across runs.
    public static var staging: URL {
        appSupport.appendingPathComponent("Staging", isDirectory: true)
    }

    /// Remove leftover staging from previous sessions. Safe to call at launch:
    /// the single-instance lock guarantees no other process is mid-operation.
    public static func clearStaging() {
        try? FileManager.default.removeItem(at: staging)
    }
}
