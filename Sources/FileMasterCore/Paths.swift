import Foundation

/// On-disk home for everything FileMaster persists. Every counter-ltd app keeps its
/// files together under one org-scoped root so they're easy to find, back up, and
/// remove:
///
///   ~/Library/Application Support/counter-ltd/filemaster/
///
/// (Settings and the recents list still live in `UserDefaults`; this is the home
/// for actual files the app produces.)
public enum Paths {
#if APPSTAGE
    /// Capture-only build (appstage screenshots). Storage is forced to a
    /// throwaway directory so a capture run never reads or writes the user's real
    /// files, indices, or notebooks. Compiled out of normal/release builds.
    public static let appSupport: URL = {
        let fm = FileManager.default
        let dir: URL
        if let override = ProcessInfo.processInfo.environment["FILEMASTER_STATE_DIR"],
           !override.isEmpty {
            dir = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("filemaster-appstage", isDirectory: true)
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
#else
    /// The app's storage root. Created on first access.
    public static let appSupport: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("counter-ltd/filemaster", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()
#endif

    /// Scratch space for files produced by tools (PDF ops, conversions, archives)
    /// before the user files them away. It lives under the app root rather than
    /// the system temp dir so all of FileMaster's output stays in one predictable
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

    /// Home for the on-device "Ask" search indices (chunk text, embedding
    /// vectors, citation locators). Unlike `staging`, this is a durable cache:
    /// re-asking about an already-indexed file must be instant, so it is **not**
    /// cleared at launch. Created on first access.
    public static var indices: URL {
        let dir = appSupport.appendingPathComponent("Indices", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Home for saved Notebooks (persistent document libraries). Durable;
    /// not cleared at launch. Created on first access.
    public static var notebooks: URL {
        let dir = appSupport.appendingPathComponent("Notebooks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
