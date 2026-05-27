import Foundation
import AppKit

/// One file or folder parked in a den.
public struct ShelfItem: Identifiable, Sendable {
    public let id: UUID
    public let url: URL

    public init(url: URL) {
        self.id = UUID()
        self.url = url
    }

    public var name: String { url.lastPathComponent }

    @MainActor
    public var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }
}

public extension URL {
    /// True if this URL points at a directory on disk. Returns false on error.
    var isDirectoryItem: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    /// Allocated size on disk in bytes, recursive for directories. Nil on error.
    var allocatedSize: Int? {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey]
        guard let v = try? resourceValues(forKeys: keys) else { return nil }
        return v.isDirectory == true ? v.totalFileAllocatedSize : v.fileSize
    }

    /// The children of this directory, as they should appear once expanded into
    /// a den. Hidden entries (dotfiles, `.DS_Store`) are always skipped, and
    /// bundles (`.app`, `.key`, …) are treated as opaque leaves rather than
    /// folders to descend into. Returns an empty array if this isn't a readable
    /// directory.
    ///
    /// - When `recursive` is false: the immediate children, both files and
    ///   subfolders, sorted by name.
    /// - When `recursive` is true: every leaf in the whole tree — files and
    ///   bundles from this folder and all of its sub-, sub-sub-folders, etc. —
    ///   flattened, with the intermediate folders themselves dropped.
    func expandedContents(recursive: Bool) -> [URL] {
        let fm = FileManager.default
        guard isDirectoryItem else { return [] }

        if !recursive {
            let children = (try? fm.contentsOfDirectory(
                at: self,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])) ?? []
            return children.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
        }

        guard let walker = fm.enumerator(
            at: self,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }

        var leaves: [URL] = []
        for case let url as URL in walker {
            let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            let isFolder = vals?.isDirectory ?? false
            let isPackage = vals?.isPackage ?? false
            // Keep files and opaque bundles; plain folders are walked but not kept.
            if !isFolder || isPackage { leaves.append(url) }
        }
        return leaves
    }
}
