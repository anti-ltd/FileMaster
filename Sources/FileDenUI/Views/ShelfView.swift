import SwiftUI
import UniformTypeIdentifiers
import AppKit
import QuickLookUI
import FileDenCore
import FileDenAI

// MARK: - Size notification
extension Notification.Name {
    static let shelfResizeRequested = Notification.Name("shelfResizeRequested")
    static let shelfCloseRequested  = Notification.Name("shelfCloseRequested")
    static let newDenRequested      = Notification.Name("newDenRequested")
    static let denClosed            = Notification.Name("denClosed")
    static let denEmptyRequested    = Notification.Name("denEmptyRequested")
    /// Posted with `[URL]` to open the Ask window for those documents.
    static let askAIRequested       = Notification.Name("askAIRequested")
    /// Posted with the controller's `ObjectIdentifier` when an Ask window closes.
    static let qaClosed             = Notification.Name("qaClosed")
}

struct ShelfView: View {
    var onClose: (() -> Void)? = nil
    var onResize: ((CGSize) -> Void)? = nil
    var onEmpty: ((@escaping () -> Void) -> Void)? = nil
    var onItemsReceived: (() -> Void)? = nil
    var onItemsChanged: ((Bool) -> Void)? = nil
    var onURLsChanged: (([URL]) -> Void)? = nil
    /// Called when the den enters (true) / leaves (false) inline Ask mode, so the
    /// window controller can make the panel key for text input.
    var onAskModeChanged: ((Bool) -> Void)? = nil
    var initialURLs: [URL] = []
    /// Open in the expanded grid immediately (used for screenshots).
    var initiallyExpanded: Bool = false
    /// Show the drop-target highlight immediately (used for screenshots).
    var initiallyTargeted: Bool = false
    /// Start in list mode instead of grid (used for screenshots).
    var initialViewMode: ExpandedViewMode = .grid
    /// Open straight into the image editor on this URL (used for screenshots).
    var initiallyEditingURL: URL? = nil

    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var settings = FileDenSettings.shared
    @State private var items: [ShelfItem] = []
    @State private var isTargeted = false
    @State private var isHovered = false
    @State private var isDragging = false
    @State private var dragMonitor: Any?
    @State private var keyMonitor: Any?
    @State private var hostWindow: NSWindow?
    @State private var isExpanded = false
    @State private var showShareDialog = false
    @State private var itemsDealt = false
    @State private var selection: Set<UUID> = []
    @State private var selectionAnchor: UUID? = nil
    @State private var viewMode: ExpandedViewMode = .grid
    @State private var isAsking = false
    @State private var askSession: QASession? = nil
    @State private var askURLs: [URL] = []
    @State private var viewingCitation: Citation? = nil
    @State private var isEditing = false
    /// While editing, the file list doubles as editor tabs: one cached model per
    /// image so switching back and forth preserves each image's edits.
    @State private var editModels: [URL: ImageEditModel] = [:]
    @State private var currentEditURL: URL? = nil

    enum ExpandedViewMode { case grid, list }

    private let compactSize = CGSize(width: 200, height: 200)
    private let expandedSize = CGSize(width: 340, height: 420)
    /// Size when Ask is open beside the file view: files (left) + Ask (right).
    private let askSize = CGSize(width: 740, height: 560)
    /// Size when a citation source is also open: files + Ask + source.
    private let askViewSize = CGSize(width: 1180, height: 640)
    /// Width Ask shrinks to when the source pane is showing.
    private let askPaneViewingWidth: CGFloat = 400
    /// Size when the image editor is open: files + viewer + controls panes.
    private let editSize = CGSize(width: 1180, height: 660)
    /// Width of the editor's third (controls) pane.
    private let editControlsWidth: CGFloat = 280

    /// The window size for the den's current mode.
    private var currentSize: CGSize {
        if isEditing { return editSize }
        if isAsking { return viewingCitation != nil ? askViewSize : askSize }
        return isExpanded ? expandedSize : compactSize
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 24)
                .fill(colorScheme == .dark
                    ? Color.white.opacity(0.03)
                    : Color.white.opacity(0.15))

            if isEditing, let url = currentEditURL, let editModel = editModels[url] {
                editSplitView(editModel, url: url)
                    .transition(.opacity)
            } else if isAsking {
                askSplitView
                    .transition(.opacity)
            } else if isExpanded {
                expandedView
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            } else {
                compactView
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .frame(width: currentSize.width, height: currentSize.height)
        .onHover { hovered in
            withAnimation(.easeInOut(duration: 0.2)) { isHovered = hovered }
            if !hovered { isDragging = false }
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(isTargeted ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 2)
        )
        .background(WindowAccessor { hostWindow = $0 })
        .onAppear { startDragMonitor(); startKeyMonitor() }
        .onDisappear { stopDragMonitor(); stopKeyMonitor() }
        .onChange(of: items.isEmpty) { _, empty in onItemsChanged?(empty) }
        .onChange(of: items.map(\.url)) { _, urls in onURLsChanged?(urls) }
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: isExpanded)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: isAsking)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: isEditing)
        .onChange(of: isExpanded) { _, expanded in
            postResize()
            if expanded {
                itemsDealt = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { itemsDealt = true }
            } else {
                isAsking = false
                isEditing = false
            }
        }
        .onChange(of: isAsking) { _, asking in
            if !asking { viewingCitation = nil }
            postResize()
            onAskModeChanged?(asking)
        }
        .onChange(of: isEditing) { _, editing in
            if !editing { editModels = [:]; currentEditURL = nil }
            postResize()
            // Make the den key so editor sliders/markup gestures receive input.
            onAskModeChanged?(editing)
        }
        .onChange(of: viewingCitation) { _, _ in postResize() }
        .onAppear {
            if items.isEmpty && !initialURLs.isEmpty {
                items = initialURLs.map { ShelfItem(url: $0) }
            }
            if initiallyExpanded { isExpanded = true }
            if initiallyTargeted { isTargeted = true }
            if initialViewMode == .list { viewMode = .list }
            if let editURL = initiallyEditingURL { enterEdit(url: editURL) }
            onEmpty? {
                if !items.isEmpty {
                    RecentDensStore.shared.record(urls: items.map(\.url))
                }
                withAnimation(.spring(duration: 0.3)) {
                    items.removeAll()
                    isExpanded = false
                }
            }
        }
        .confirmationDialog("Share as", isPresented: $showShareDialog) {
            Button("Individual Files & Folders") { shareAsFiles() }
            Button("ZIP Archive") { shareAsZip() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("One or more items is a directory.")
        }
    }

    // MARK: - Compact view

    private var compactView: some View {
        ZStack {
            VStack(spacing: 0) {
                grabHandle.padding(.top, 8)
                Spacer(minLength: 0)
                dropZone
                Spacer(minLength: 0)
                if !items.isEmpty {
                    Text(compactSubtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 60)
                        .padding(.bottom, 10)
                }
            }

            if !items.isEmpty {
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        if settings.aiEnabled && !askableURLs.isEmpty {
                            compactAskButton.padding(.leading, 10).padding(.bottom, 8)
                        }
                        if let url = editableURL {
                            compactEditButton(url)
                                .padding(.leading, askableURLs.isEmpty ? 10 : 0)
                                .padding(.bottom, 8)
                        }
                        Spacer()
                        shareButton.padding(.trailing, 10).padding(.bottom, 8)
                    }
                }
            }

            VStack {
                HStack {
                    Button(action: xButtonAction) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                            .background(.regularMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button(action: openFilePicker) {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                            .background(.regularMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("New Den") {
                            DispatchQueue.main.async {
                                DenManager.shared.newDen(placement: .nearCursor)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                Spacer()
            }
        }
        .frame(width: compactSize.width, height: compactSize.height)
    }

    // MARK: - Expanded view

    private var expandedView: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .center) {
                Button(action: { withAnimation { isExpanded = false } }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.plain)

                Spacer()

                VStack(spacing: 1) {
                    Text(headerTitle)
                        .font(.system(size: 13, weight: .semibold))
                    Text(totalSize)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                Button(action: openFilePicker) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 6)
            .background(WindowDragHandle())

            // View mode tabs
            HStack(spacing: 6) {
                viewModeTab(.grid, label: "Grid", icon: "square.grid.2x2")
                viewModeTab(.list, label: "List", icon: "list.bullet")
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 8)

            Divider().opacity(0.3)

            // Content
            ScrollView {
                ZStack {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selection.removeAll()
                            selectionAnchor = nil
                        }
                    if viewMode == .grid {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 12)], spacing: 16) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                ExpandedItemView(
                                    item: item,
                                    isSelected: selection.contains(item.id),
                                    isEditTab: isEditing && currentEditURL == item.url,
                                    onRemove: { remove(item) },
                                    onClick: { mods in handleItemClick(item, modifiers: mods) },
                                    onOpen: { NSWorkspace.shared.open(item.url) },
                                    dragURLs: { dragURLs(for: item) },
                                    actionsMenu: { host in actionsMenu(for: item, host: host) },
                                    onDragEnded: handleDragOut
                                )
                                    .scaleEffect(itemsDealt ? 1 : 0.4)
                                    .opacity(itemsDealt ? 1 : 0)
                                    .animation(
                                        .spring(response: 0.42, dampingFraction: 0.72)
                                        .delay(Double(index) * 0.06),
                                        value: itemsDealt
                                    )
                            }
                        }
                        .padding(16)
                    } else {
                        LazyVStack(spacing: 4) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                ExpandedListRowView(
                                    item: item,
                                    isSelected: selection.contains(item.id),
                                    isEditTab: isEditing && currentEditURL == item.url,
                                    onRemove: { remove(item) },
                                    onClick: { mods in handleItemClick(item, modifiers: mods) },
                                    onOpen: { NSWorkspace.shared.open(item.url) },
                                    dragURLs: { dragURLs(for: item) },
                                    actionsMenu: { host in actionsMenu(for: item, host: host) },
                                    onDragEnded: handleDragOut
                                )
                                    .opacity(itemsDealt ? 1 : 0)
                                    .animation(
                                        .easeOut(duration: 0.25).delay(Double(index) * 0.03),
                                        value: itemsDealt
                                    )
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
            }

            Divider().opacity(0.3)

            // Bottom bar
            HStack {
                Button(action: clearAll) {
                    Label("Clear", systemImage: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                Spacer()
                if settings.aiEnabled && !askableURLs.isEmpty {
                    Button(action: saveAsNotebook) {
                        Image(systemName: "book.closed")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Save these documents as a notebook to re-ask anytime")
                    .padding(.trailing, 6)
                }
                ActionsMenuButton(
                    urls: { selectedItems.map(\.url) },
                    onShare: { view in shareAll(from: view) },
                    onRemove: { removed in removeURLs(removed) },
                    onAsk: { urls in enterAsk(urls: urls) },
                    onEdit: { urls in if let u = urls.first { enterEdit(url: u) } }
                )
                .frame(width: 28, height: 22)
                .help("Actions")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Ask split (files left, Ask right)

    private var askSplitView: some View {
        HStack(spacing: 0) {
            expandedView
                .frame(width: expandedSize.width)
            Divider().opacity(0.4)
            if let citation = viewingCitation {
                askPane
                    .frame(width: askPaneViewingWidth)
                Divider().opacity(0.4)
                CitationPane(citation: citation,
                             onClose: { withAnimation { viewingCitation = nil } })
                    .frame(maxWidth: .infinity)
            } else {
                askPane
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(width: currentSize.width, height: currentSize.height)
    }

    private var askPane: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                if let s = askSession {
                    switch s.phase {
                    case .indexing:
                        ProgressView().controlSize(.small)
                        Text("Indexing \(s.fileCount) \(s.fileCount == 1 ? "document" : "documents")…")
                            .font(.system(size: 12, weight: .medium))
                    case .ready:
                        Image(systemName: "sparkles").foregroundStyle(.tint)
                        Text("\(s.fileCount) \(s.fileCount == 1 ? "document" : "documents") · offline")
                            .font(.system(size: 12, weight: .medium))
                    case .empty:
                        Image(systemName: "doc.questionmark").foregroundStyle(.secondary)
                        Text("No documents").font(.system(size: 12, weight: .medium))
                    case .failed:
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text("Error").font(.system(size: 12, weight: .medium))
                    }
                }
                Spacer()
                if let s = askSession {
                    Text(s.modelLabel)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.tertiary)
                }
                Button(action: { withAnimation { isAsking = false } }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Close Ask")
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 6)
            .background(WindowDragHandle())

            if let askSession {
                QAView(session: askSession,
                       onOpenCitation: { citation in withAnimation { viewingCitation = citation } })
            } else {
                Spacer()
            }
        }
    }

    // MARK: - Edit split (files left, editor right)

    private func editSplitView(_ model: ImageEditModel, url: URL) -> some View {
        HStack(spacing: 0) {
            expandedView
                .frame(width: expandedSize.width)
            Divider().opacity(0.4)
            // `.id(url)` rebuilds the viewer/controls per tab so transient gesture
            // state (in-progress markup, export fields) resets when switching images.
            ImageEditorView(model: model, onClose: { withAnimation { isEditing = false } })
                .frame(maxWidth: .infinity)
                .id(url)
            Divider().opacity(0.4)
            ImageEditorControlsPane(model: model)
                .frame(width: editControlsWidth)
                .id(url)
        }
        .frame(width: currentSize.width, height: currentSize.height)
    }

    /// Open the image editor beside the file view for `url`, or switch to it if
    /// already editing — the file list acts as editor tabs. Each image keeps its
    /// own cached model so its edits survive switching away and back.
    private func enterEdit(url: URL) {
        guard ImageConvert.isImage(url) else { NSSound.beep(); return }
        if editModels[url] == nil {
            guard let model = ImageEditModel(url: url) else { NSSound.beep(); return }
            editModels[url] = model
        }
        currentEditURL = url
        // Highlight the active tab in the list.
        if let id = items.first(where: { $0.url == url })?.id {
            selection = [id]; selectionAnchor = id
        }
        withAnimation {
            isExpanded = true
            isAsking = false
            isEditing = true
        }
    }

    /// Click handling for a file tile: while editing, clicking an image switches
    /// the active editor tab; otherwise it's normal selection.
    private func handleItemClick(_ item: ShelfItem, modifiers: NSEvent.ModifierFlags) {
        if isEditing, ImageConvert.isImage(item.url), !modifiers.contains(.command), !modifiers.contains(.shift) {
            enterEdit(url: item.url)
        } else {
            handleSelectionClick(item: item, modifiers: modifiers)
        }
    }

    /// Tell the host window to resize to the den's current mode.
    private func postResize() {
        let size = currentSize
        NotificationCenter.default.post(name: .shelfResizeRequested, object: size)
        onResize?(size)
    }

    @ViewBuilder
    private func viewModeTab(_ mode: ExpandedViewMode, label: String, icon: String) -> some View {
        let active = viewMode == mode
        Button(action: { withAnimation(.easeInOut(duration: 0.15)) { viewMode = mode } }) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(label).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(active ? Color.white : Color.primary.opacity(0.75))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(active ? Color.accentColor : Color.primary.opacity(0.08))
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color.primary.opacity(active ? 0 : 0.12), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Compact sub-views

    private var grabHandle: some View {
        ZStack {
            Capsule()
                .fill(Color.secondary.opacity(isDragging ? 0.65 : isHovered ? 0.35 : 0))
                .frame(width: isDragging ? 48 : 36, height: 5)
                .animation(.easeInOut(duration: 0.2), value: isHovered)
                .animation(.easeInOut(duration: 0.15), value: isDragging)
            WindowDragHandle()
                .frame(width: 120, height: 18)
        }
        .frame(width: 120, height: 18)
    }

    private var dropZone: some View {
        Group {
            if items.isEmpty {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(
                            Color.secondary.opacity(isTargeted ? 0.5 : 0.25),
                            style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                        )
                        .frame(width: 120, height: 120)
                        .animation(.easeInOut(duration: 0.15), value: isTargeted)

                    Image(systemName: "doc.fill")
                        .font(.system(size: 42))
                        .foregroundStyle(.secondary)
                        .opacity(isTargeted ? 0.35 : 0.12)
                        .animation(.easeInOut(duration: 0.15), value: isTargeted)
                }
            } else if items.count == 1 {
                ShelfItemView(item: items[0])
                    .overlay(
                        MultiURLDragView(
                            urls: { items.map(\.url) },
                            onTap: { _ in withAnimation { isExpanded = true } },
                            menu: { host in compactActionsMenu(host: host) },
                            onDragEnded: handleDragOut
                        )
                    )
            } else {
                StackedFilesView(items: items)
                    .overlay(
                        MultiURLDragView(
                            urls: { items.map(\.url) },
                            onTap: { _ in withAnimation { isExpanded = true } },
                            menu: { host in compactActionsMenu(host: host) },
                            onDragEnded: handleDragOut
                        )
                    )
            }
        }
    }

    private var shareButton: some View {
        ZStack {
            Circle()
                .fill(.regularMaterial)
                .frame(width: 28, height: 28)
            ActionsMenuButton(
                urls: { selectedItems.map(\.url) },
                onShare: { view in shareAll(from: view) },
                onRemove: { removed in removeURLs(removed) },
                onAsk: { urls in enterAsk(urls: urls) },
                onEdit: { urls in if let u = urls.first { enterEdit(url: u) } }
            )
            .frame(width: 20, height: 20)
        }
        .frame(width: 28, height: 28)
    }

    /// Compact-mode Ask button. Expands the den and opens Ask beside the files.
    private var compactAskButton: some View {
        Button(action: askAI) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .help("Ask questions about these files, offline")
    }

    /// Compact-mode Edit button — opens the image editor beside the files.
    private func compactEditButton(_ url: URL) -> some View {
        Button(action: { enterEdit(url: url) }) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .help("Edit this image")
    }

    private func removeURLs(_ urls: [URL]) {
        let set = Set(urls)
        withAnimation {
            items.removeAll { set.contains($0.url) }
        }
        for url in urls {
            if let id = items.first(where: { $0.url == url })?.id {
                selection.remove(id)
                if selectionAnchor == id { selectionAnchor = nil }
            }
            editModels[url] = nil
        }
        // If the edited tab was removed, switch to another image or leave editing.
        if let current = currentEditURL, set.contains(current) {
            if let next = items.first(where: { ImageConvert.isImage($0.url) })?.url {
                enterEdit(url: next)
            } else {
                withAnimation { isEditing = false }
            }
        }
    }

    /// When a staged file is dragged *out* of the den, drop its tile — but only
    /// when the drop actually relocated the file (a move, or a drag to Trash), so
    /// the tile no longer points at anything. A plain copy leaves the staged file
    /// in place, so we keep the tile; same for aliases and cancelled drags.
    /// Staged output is throwaway (purged at launch); user-owned files (outside
    /// Staging) are never auto-removed regardless of operation.
    private func handleDragOut(_ dragged: [URL], operation: NSDragOperation) {
        guard operation.contains(.move) || operation.contains(.delete) else { return }
        let stagingPath = Paths.staging.standardizedFileURL.path
        let staged = dragged.filter {
            $0.standardizedFileURL.path.hasPrefix(stagingPath + "/")
        }
        if !staged.isEmpty { removeURLs(staged) }
    }

    // MARK: - Helpers

    private var headerTitle: String {
        "\(items.count) \(items.count == 1 ? "Item" : "Items")"
    }

    private var compactSubtitle: String {
        guard !items.isEmpty else { return "" }
        if items.count == 1 { return items[0].name }
        var dirs = 0
        var files = 0
        for it in items {
            if it.url.isDirectoryItem { dirs += 1 } else { files += 1 }
        }
        let fileLabel = files == 1 ? "File" : "Files"
        let dirLabel = dirs == 1 ? "Folder" : "Folders"
        if dirs == 0 { return "\(files) \(fileLabel)" }
        if files == 0 { return "\(dirs) \(dirLabel)" }
        return "\(files) \(fileLabel) / \(dirs) \(dirLabel)"
    }

    private var totalSize: String {
        let total = items.compactMap(\.url.allocatedSize).reduce(0, +)
        if total <= 0 { return "Zero KB" }
        return ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
    }

    private func remove(_ item: ShelfItem) {
        withAnimation { items.removeAll { $0.id == item.id } }
        selection.remove(item.id)
        if selectionAnchor == item.id { selectionAnchor = nil }
    }

    private func handleSelectionClick(item: ShelfItem, modifiers: NSEvent.ModifierFlags) {
        let isCmd = modifiers.contains(.command)
        let isShift = modifiers.contains(.shift)
        let isCtrl = modifiers.contains(.control)

        if isShift, let anchor = selectionAnchor,
           let from = items.firstIndex(where: { $0.id == anchor }),
           let to = items.firstIndex(where: { $0.id == item.id }) {
            let range = from <= to ? from...to : to...from
            let ids = items[range].map(\.id)
            if isCmd {
                selection.formUnion(ids)
            } else {
                selection = Set(ids)
            }
        } else if isCmd || isCtrl {
            if selection.contains(item.id) {
                selection.remove(item.id)
            } else {
                selection.insert(item.id)
            }
            selectionAnchor = item.id
        } else {
            selection = [item.id]
            selectionAnchor = item.id
        }
    }

    private func dragURLs(for item: ShelfItem) -> [URL] {
        if selection.count > 1 && selection.contains(item.id) {
            return items.filter { selection.contains($0.id) }.map(\.url)
        }
        return [item.url]
    }

    /// Full right-click action menu for an item in the expanded view. Acts on the
    /// whole selection when the right-clicked item is part of a multi-selection;
    /// otherwise just that item, which it also selects for visual feedback.
    private func actionsMenu(for item: ShelfItem, host: NSView) -> NSMenu {
        let targets: [URL]
        if selection.count > 1 && selection.contains(item.id) {
            targets = items.filter { selection.contains($0.id) }.map(\.url)
        } else {
            targets = [item.url]
            if selection != [item.id] {
                selection = [item.id]
                selectionAnchor = item.id
            }
        }
        return FileActions.buildMenu(
            for: targets,
            host: host,
            onShare: { view in shareAll(from: view) },
            onRemove: { removed in removeURLs(removed) },
            onRemoveFromDen: { removed in removeURLs(removed) },
            onEdit: { urls in if let u = urls.first { enterEdit(url: u) } }
        )
    }

    /// Right-click menu for the compact preview, which has no per-item selection:
    /// acts on every file in the den (the single file, or the whole stack).
    private func compactActionsMenu(host: NSView) -> NSMenu {
        FileActions.buildMenu(
            for: items.map(\.url),
            host: host,
            onShare: { view in shareAll(from: view) },
            onRemove: { removed in removeURLs(removed) },
            onRemoveFromDen: { removed in removeURLs(removed) },
            onEdit: { urls in if let u = urls.first { enterEdit(url: u) } }
        )
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
                    guard !items.contains(where: { $0.url == url }) else { return }
                    items.append(ShelfItem(url: url))
                    onItemsReceived?()
                }
            }
        }
        return true
    }

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                guard !items.contains(where: { $0.url == url }) else { continue }
                items.append(ShelfItem(url: url))
            }
        }
    }

    @State private var shareSourceView: NSView?
    @State private var shareTargets: [ShelfItem] = []

    private var selectedItems: [ShelfItem] {
        selection.isEmpty ? items : items.filter { selection.contains($0.id) }
    }

    /// Text-bearing files among the current selection (PDF/HTML/text/Markdown)
    /// that the offline Ask feature can search.
    private var askableURLs: [URL] {
        selectedItems.map(\.url).filter { TextExtractor.canExtract($0) }
    }

    /// The single image to edit: exactly one image among the current selection
    /// (the editor is single-image), or nil to hide the entry point.
    private var editableURL: URL? {
        let images = selectedItems.map(\.url).filter { ImageConvert.isImage($0) }
        return images.count == 1 ? images[0] : nil
    }

    private func askAI() { enterAsk(urls: askableURLs) }

    /// Open Ask beside the file view. Expands the den (from compact if needed)
    /// and splits the window: files on the left, Ask on the right. Builds a fresh
    /// session when the document set changes; otherwise reuses the open one so the
    /// previous answer is preserved. Shared by the compact Ask button and the
    /// "Ask AI…" actions-menu item.
    private func enterAsk(urls: [URL]) {
        let searchable = urls.filter { TextExtractor.canExtract($0) }
        guard !searchable.isEmpty else { return }
        if askSession == nil || askURLs != searchable {
            askSession = QASession(urls: searchable)
            askURLs = searchable
        }
        withAnimation {
            isExpanded = true
            isAsking = true
        }
    }

    /// Save the den's searchable documents as a named, persistent notebook.
    private func saveAsNotebook() {
        let urls = askableURLs
        guard !urls.isEmpty else { return }
        let suggested = urls.count == 1
            ? urls[0].deletingPathExtension().lastPathComponent
            : "\(urls[0].deletingPathExtension().lastPathComponent) +\(urls.count - 1)"
        if let name = promptForText(title: "Save as Notebook",
                                    message: "Name this set of \(urls.count) document\(urls.count == 1 ? "" : "s"). Reopen and ask it anytime from the menu bar.",
                                    defaultValue: suggested) {
            NotebookStore.shared.add(name: name, urls: urls)
        }
    }

    private func shareAll(from view: NSView) {
        shareSourceView = view
        let targets = selectedItems
        shareTargets = targets
        let hasDirectory = targets.contains { $0.url.isDirectoryItem }
        if hasDirectory {
            if FileDenSettings.shared.autoZipOnShare {
                shareAsZip()
            } else {
                showShareDialog = true
            }
        } else {
            presentSharePicker(items: targets.map(\.url) as [Any], from: view)
        }
    }

    private func shareAsFiles() {
        guard let view = shareSourceView else { return }
        presentSharePicker(items: shareTargets.map(\.url) as [Any], from: view)
    }

    private func shareAsZip() {
        guard let view = shareSourceView else { return }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileDen-\(Int(Date().timeIntervalSince1970)).zip")
        let paths = shareTargets.map { $0.url.path.shellEscaped }.joined(separator: " ")
        let result = shell("zip -rq \(tmp.path.shellEscaped) \(paths)")
        guard result == 0, FileManager.default.fileExists(atPath: tmp.path) else { return }
        presentSharePicker(items: [tmp] as [Any], from: view)
    }

    private func presentSharePicker(items: [Any], from view: NSView) {
        let picker = NSSharingServicePicker(items: items)
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    @discardableResult
    private func shell(_ command: String) -> Int32 {
        let proc = Process()
        proc.launchPath = "/bin/sh"
        proc.arguments = ["-c", command]
        proc.launch()
        proc.waitUntilExit()
        return proc.terminationStatus
    }

    private func xButtonAction() {
        if items.isEmpty {
            onClose?()
        } else {
            RecentDensStore.shared.record(urls: items.map(\.url))
            withAnimation(.spring(duration: 0.3)) {
                items.removeAll()
                isExpanded = false
            }
        }
    }

    private func clearAll() {
        if !items.isEmpty {
            RecentDensStore.shared.record(urls: items.map(\.url))
        }
        withAnimation(.spring(duration: 0.3)) {
            items.removeAll()
            isExpanded = false
        }
    }

    private func startDragMonitor() {
        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { event in
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isDragging = event.type == .leftMouseDragged
                }
            }
            return event
        }
    }

    private func stopDragMonitor() {
        if let monitor = dragMonitor {
            NSEvent.removeMonitor(monitor)
            dragMonitor = nil
        }
    }

    /// Space bar → Quick Look the current selection, mirroring Finder. Scoped to
    /// this den's window, and suppressed while typing (e.g. the Ask field).
    private func startKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            guard event.keyCode == 49,                       // space
                  !event.modifierFlags.contains(.command)
            else { return event }

            // Space while the Quick Look panel is focused → close it (toggle).
            if QLPreviewPanel.sharedPreviewPanelExists(),
               let panel = QLPreviewPanel.shared(),
               event.window === panel {
                panel.orderOut(nil)
                return nil
            }

            // Space in this den's expanded view → open the preview.
            guard isExpanded,
                  let host = hostWindow, event.window === host,
                  !(host.firstResponder is NSText)           // not editing text
            else { return event }
            quickLookSelection()
            return nil                                       // swallow the space
        }
    }

    private func stopKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    private func quickLookSelection() {
        QuickLookController.shared.preview(selectedItems.map(\.url))
    }
}

// MARK: - Expanded item

struct ExpandedItemView: View {
    let item: ShelfItem
    let isSelected: Bool
    var isEditTab: Bool = false
    let onRemove: () -> Void
    let onClick: (NSEvent.ModifierFlags) -> Void
    let onOpen: () -> Void
    let dragURLs: () -> [URL]
    let actionsMenu: (NSView) -> NSMenu?
    var onDragEnded: ([URL], NSDragOperation) -> Void = { _, _ in }
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if isDirectory {
                        ThumbnailView(url: item.url, size: CGSize(width: 144, height: 176), contentMode: .fit)
                            .frame(width: 72, height: 88)
                    } else {
                        ThumbnailView(url: item.url, size: CGSize(width: 144, height: 176), contentMode: .fill)
                            .frame(width: 72, height: 88)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                    .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 2)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.accentColor.opacity(highlighted ? 0.28 : 0))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(Color.accentColor.opacity(highlighted ? 0.9 : 0),
                                                  lineWidth: isEditTab ? 2.5 : 2)
                            )
                            .padding(-6)
                    )
                    .overlay(
                        MultiURLDragView(urls: dragURLs, onTap: onClick, onDoubleClick: onOpen,
                                         menu: actionsMenu, onDragEnded: onDragEnded)
                    )

                if isHovered {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                            .background(Color(nsColor: .windowBackgroundColor), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .offset(x: 6, y: -6)
                    .transition(.scale.combined(with: .opacity))
                }
            }

            Text(item.name)
                .font(.system(size: 10))
                .lineLimit(1)
                .foregroundStyle(highlighted ? .primary : .secondary)
                .frame(width: 80)

            Text(fileSize)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .onHover { h in withAnimation(.easeInOut(duration: 0.15)) { isHovered = h } }
    }

    private var highlighted: Bool { isSelected || isEditTab }
    private var isDirectory: Bool { item.url.isDirectoryItem }

    private var fileSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(item.url.allocatedSize ?? 0), countStyle: .file)
    }
}

// MARK: - Expanded list row

struct ExpandedListRowView: View {
    let item: ShelfItem
    let isSelected: Bool
    var isEditTab: Bool = false
    let onRemove: () -> Void
    let onClick: (NSEvent.ModifierFlags) -> Void
    let onOpen: () -> Void
    let dragURLs: () -> [URL]
    let actionsMenu: (NSView) -> NSMenu?
    var onDragEnded: ([URL], NSDragOperation) -> Void = { _, _ in }
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            ThumbnailView(url: item.url, size: CGSize(width: 64, height: 64), contentMode: .fit)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? .primary : .primary)
                Text(fileSize)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            if isHovered {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(isSelected || isEditTab ? 0.22 : 0))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor.opacity(isSelected || isEditTab ? 0.8 : 0),
                                      lineWidth: isEditTab ? 2 : 1.5)
                )
        )
        .overlay(MultiURLDragView(urls: dragURLs, onTap: onClick, onDoubleClick: onOpen,
                                  menu: actionsMenu, onDragEnded: onDragEnded))
        .onHover { h in withAnimation(.easeInOut(duration: 0.15)) { isHovered = h } }
    }

    private var fileSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(item.url.allocatedSize ?? 0), countStyle: .file)
    }
}

// MARK: - Compact item views

struct ShelfItemView: View {
    let item: ShelfItem

    private var isDirectory: Bool { item.url.isDirectoryItem }

    var body: some View {
        if isDirectory {
            ThumbnailView(url: item.url, size: CGSize(width: 160, height: 160), contentMode: .fit)
                .frame(width: 90, height: 90)
        } else {
            ThumbnailView(url: item.url, size: CGSize(width: 160, height: 196), contentMode: .fill)
                .frame(width: 80, height: 98)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct StackedFilesView: View {
    let items: [ShelfItem]

    private static let rotations: [Double] = [-8, -3, 3]
    private static let offsets: [(CGFloat, CGFloat)] = [(-6, 6), (-2, 2), (0, 0)]

    var body: some View {
        ZStack {
            ForEach(Array(visibleItems.enumerated()), id: \.offset) { index, item in
                fileCard(item: item)
                    .rotationEffect(.degrees(Self.rotations[index]))
                    .offset(x: Self.offsets[index].0, y: Self.offsets[index].1)
                    .zIndex(Double(index))
            }
        }
        .frame(width: 110, height: 140)
    }

    private var visibleItems: [ShelfItem] { Array(items.prefix(3).reversed()) }

    private func fileCard(item: ShelfItem) -> some View {
        let isDir = item.url.isDirectoryItem
        return Group {
            if isDir {
                ThumbnailView(url: item.url, size: CGSize(width: 160, height: 160), contentMode: .fit)
                    .frame(width: 80, height: 80)
            } else {
                ThumbnailView(url: item.url, size: CGSize(width: 140, height: 172), contentMode: .fill)
                    .frame(width: 70, height: 86)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

// MARK: - Helpers

extension String {
    var shellEscaped: String { "'\(replacingOccurrences(of: "'", with: "'\\''"))'" }
}
