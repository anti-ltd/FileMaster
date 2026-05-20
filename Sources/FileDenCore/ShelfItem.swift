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
}
