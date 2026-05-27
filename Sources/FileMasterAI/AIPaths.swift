import Foundation
import FileMasterCore

/// File locations for the Ask feature, layered on ``Paths``.
public enum AIPaths {
    /// The single global search index. One database keyed by file path +
    /// fingerprint, so the same file dropped into different dens (or saved into a
    /// notebook) reuses one index.
    public static var indexDB: URL {
        Paths.indices.appendingPathComponent("index.sqlite")
    }
}
