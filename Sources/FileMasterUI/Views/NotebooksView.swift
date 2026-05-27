import SwiftUI
import AppKit
import FileMasterAI

/// Manage saved notebooks: open (ask), rename, delete.
struct NotebooksView: View {
    @ObservedObject private var store = NotebookStore.shared
    let onOpen: (Notebook) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            if store.notebooks.isEmpty {
                empty
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(store.notebooks) { notebook in
                            row(notebook)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(minWidth: 380, minHeight: 320)
        .background(.background)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "books.vertical").foregroundStyle(.tint)
            Text("Notebooks").font(.system(size: 13, weight: .semibold))
            Spacer()
            Text("\(store.notebooks.count)").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: "books.vertical").font(.system(size: 28)).foregroundStyle(.secondary)
            Text("No notebooks yet.").font(.system(size: 13)).foregroundStyle(.secondary)
            Text("In a den, select documents and choose “Save as Notebook”.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
    }

    private func row(_ notebook: Notebook) -> some View {
        Button(action: { onOpen(notebook) }) {
            HStack(spacing: 10) {
                Image(systemName: "book.closed").font(.system(size: 16)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(notebook.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text("\(notebook.paths.count) \(notebook.paths.count == 1 ? "document" : "documents") · updated \(notebook.updatedAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { rename(notebook) } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless).help("Rename")
                Button { store.remove(notebook.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Delete")
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open and ask this notebook")
    }

    private func rename(_ notebook: Notebook) {
        if let name = promptForText(title: "Rename Notebook",
                                    message: "Enter a new name.",
                                    defaultValue: notebook.name, confirm: "Rename") {
            store.rename(notebook.id, to: name)
        }
    }
}
