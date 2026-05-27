import Foundation

/// A snapshot of the contents of a recently-closed den.
///
/// Stored on disk so the user can reopen the same set of files from the menu bar
/// after closing a den (or relaunching the app).
public struct RecentDen: Identifiable, Codable, Sendable {
    public let id: UUID
    public let closedAt: Date
    public let paths: [String]

    public init(id: UUID = UUID(), closedAt: Date = Date(), paths: [String]) {
        self.id = id
        self.closedAt = closedAt
        self.paths = paths
    }

    public var urls: [URL] { paths.map { URL(fileURLWithPath: $0) } }

    /// Human label used in the Recents menu — "FileA.pdf + 3" for multi-item dens.
    public var title: String {
        guard let first = paths.first else { return "Empty" }
        let firstName = (first as NSString).lastPathComponent
        if paths.count == 1 { return firstName }
        return "\(firstName) + \(paths.count - 1)"
    }
}

/// Persists the user's most recent dens in `UserDefaults`.
///
/// A "den" is recorded when it is closed with files inside. Re-recording the same
/// set of paths moves it to the front rather than creating a duplicate. The store
/// is capped at ``maxRecents`` entries — older dens fall off the end.
public final class RecentDensStore {
    public static let shared = RecentDensStore()

    private let defaultsKey = "FileMaster.recentDens"
    private let maxRecents = 10

    private init() {}

    public private(set) var all: [RecentDen] {
        get {
            guard let data = UserDefaults.standard.data(forKey: defaultsKey),
                  let list = try? JSONDecoder().decode([RecentDen].self, from: data)
            else { return [] }
            return list
        }
        set {
            let trimmed = Array(newValue.prefix(maxRecents))
            guard let data = try? JSONEncoder().encode(trimmed) else { return }
            UserDefaults.standard.set(data, forKey: defaultsKey)
            NotificationCenter.default.post(name: .recentDensChanged, object: nil)
        }
    }

    /// Record the closing of a den. Duplicate path-sets are de-duplicated and
    /// surfaced to the top of the list.
    public func record(urls: [URL]) {
        let paths = urls.map(\.path).filter { !$0.isEmpty }
        guard !paths.isEmpty else { return }
        let key = Set(paths)
        var list = all.filter { Set($0.paths) != key }
        list.insert(RecentDen(paths: paths), at: 0)
        all = list
    }

    public func remove(id: UUID) {
        all = all.filter { $0.id != id }
    }

    public func clear() {
        all = []
    }
}

public extension Notification.Name {
    /// Posted when the recents list changes — observe to refresh menu UI.
    static let recentDensChanged = Notification.Name("recentDensChanged")
}
