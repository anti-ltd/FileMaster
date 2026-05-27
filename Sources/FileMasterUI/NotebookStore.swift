import Foundation
import Combine
import FileMasterCore
import FileMasterAI

/// Persists saved ``Notebook``s as JSON under `Paths.notebooks` and publishes
/// changes to SwiftUI. Mirrors `RecentDensStore`'s simple file-backed approach.
@MainActor
final class NotebookStore: ObservableObject {
    static let shared = NotebookStore()

    @Published private(set) var notebooks: [Notebook] = []

    private let fileURL = Paths.notebooks.appendingPathComponent("notebooks.json")

    private init() { load() }

    func notebook(id: UUID) -> Notebook? { notebooks.first { $0.id == id } }

    @discardableResult
    func add(name: String, urls: [URL]) -> Notebook {
        let notebook = Notebook(name: name, paths: urls.map(\.path))
        notebooks.insert(notebook, at: 0)
        save()
        return notebook
    }

    func rename(_ id: UUID, to name: String) {
        mutate(id) { $0.name = name }
    }

    func setURLs(_ id: UUID, urls: [URL]) {
        mutate(id) { $0.paths = urls.map(\.path) }
    }

    func remove(_ id: UUID) {
        notebooks.removeAll { $0.id == id }
        save()
    }

    private func mutate(_ id: UUID, _ body: (inout Notebook) -> Void) {
        guard let index = notebooks.firstIndex(where: { $0.id == id }) else { return }
        var notebook = notebooks[index]
        body(&notebook)
        notebook.updatedAt = Date()
        notebooks[index] = notebook
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Notebook].self, from: data) else { return }
        notebooks = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(notebooks) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
