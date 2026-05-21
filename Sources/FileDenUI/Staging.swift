import Foundation
import FileDenCore

/// Where generated files land before the user files them away.
///
/// Every tool that produces output (PDF ops, format conversions) writes into a
/// fresh per-operation directory under the app's staging area
/// (`~/Library/Application Support/counter-ltd/fileden/Staging`) and the caller
/// drops the results into a new den. Nothing is written next to the user's
/// originals until they drag it there; stale staging is purged at launch
/// (`Paths.clearStaging()`), so anything they don't keep is reclaimed.
enum Staging {

    /// A fresh per-operation directory for one operation's output. `tag` just
    /// makes the path legible (e.g. "PDF", "IMG", "VID").
    static func dir(_ tag: String) -> URL {
        let dir = Paths.staging
            .appendingPathComponent("\(tag)-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(4))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A non-colliding URL for `name` inside `dir`, appending " 2", " 3", … on clash.
    static func uniqueURL(in dir: URL, name: String) -> URL {
        let fm = FileManager.default
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var candidate = dir.appendingPathComponent(name)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            candidate = dir.appendingPathComponent(next)
            n += 1
        }
        return candidate
    }
}
