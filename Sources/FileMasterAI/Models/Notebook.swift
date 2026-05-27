import Foundation

/// A saved, named document library — the persistent half of the "both" corpus
/// model. Stores the source file paths; the searchable index for those files is
/// the same global one used by den-scoped asks, so reopening a notebook re-asks
/// instantly (no re-indexing unless a file changed).
public struct Notebook: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public var name: String
    public var paths: [String]
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, paths: [String],
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.paths = paths
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var urls: [URL] { paths.map { URL(fileURLWithPath: $0) } }

    /// Source files that still exist on disk.
    public var existingURLs: [URL] {
        urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
