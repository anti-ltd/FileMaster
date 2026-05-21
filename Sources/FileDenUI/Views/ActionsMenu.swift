import SwiftUI
import AppKit
import QuickLookUI
import FileDenCore
import FileDenAI

struct ActionsMenuButton: NSViewRepresentable {
    var title: String? = nil
    let urls: () -> [URL]
    let onShare: (NSView) -> Void
    let onRemove: ([URL]) -> Void
    /// Called when "Ask AI…" is chosen, so the owning den can open Ask inline.
    var onAsk: (([URL]) -> Void)? = nil

    func makeNSView(context: Context) -> NSButton {
        let b = NSButton()
        b.isBordered = false
        b.target = context.coordinator
        b.action = #selector(Coordinator.tapped(_:))
        b.contentTintColor = .secondaryLabelColor
        if let title {
            b.title = title
            b.bezelStyle = .inline
            b.font = .systemFont(ofSize: 12, weight: .medium)
        } else {
            let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            b.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Actions")?
                .withSymbolConfiguration(cfg)
            b.imagePosition = .imageOnly
            b.imageScaling = .scaleProportionallyUpOrDown
            b.bezelStyle = .regularSquare
            b.isTransparent = false
            (b.cell as? NSButtonCell)?.imageDimsWhenDisabled = false
        }
        return b
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        if let title, nsView.title != title { nsView.title = title }
        context.coordinator.urls = urls
        context.coordinator.onShare = onShare
        context.coordinator.onRemove = onRemove
        context.coordinator.onAsk = onAsk
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(urls: urls, onShare: onShare, onRemove: onRemove, onAsk: onAsk)
    }

    final class Coordinator: NSObject {
        var urls: () -> [URL]
        var onShare: (NSView) -> Void
        var onRemove: ([URL]) -> Void
        var onAsk: (([URL]) -> Void)?

        init(urls: @escaping () -> [URL],
             onShare: @escaping (NSView) -> Void,
             onRemove: @escaping ([URL]) -> Void,
             onAsk: (([URL]) -> Void)? = nil) {
            self.urls = urls
            self.onShare = onShare
            self.onRemove = onRemove
            self.onAsk = onAsk
        }

        @objc func tapped(_ sender: NSButton) {
            let list = urls()
            guard !list.isEmpty else { return }
            let menu = FileActions.buildMenu(
                for: list,
                host: sender,
                onShare: onShare,
                onRemove: onRemove,
                onAsk: onAsk
            )
            menu.popUp(positioning: nil,
                       at: NSPoint(x: 0, y: sender.bounds.height + 4),
                       in: sender)
        }
    }
}

enum FileActions {
    static func buildMenu(
        for urls: [URL],
        host: NSView,
        onShare: @escaping (NSView) -> Void,
        onRemove: @escaping ([URL]) -> Void,
        onRemoveFromDen: (([URL]) -> Void)? = nil,
        onAsk: (([URL]) -> Void)? = nil
    ) -> NSMenu {
        let menu = NSMenu()
        let bridge = ActionBridge(urls: urls, host: host, onShare: onShare,
                                  onRemove: onRemove, onRemoveFromDen: onRemoveFromDen,
                                  onAsk: onAsk)
        objc_setAssociatedObject(menu, &ActionBridge.assocKey, bridge, .OBJC_ASSOCIATION_RETAIN)

        let hasDir = urls.contains { isDirectory($0) }
        let allImages = urls.allSatisfy { isImage($0) } && !urls.isEmpty
        let allPrintable = urls.allSatisfy { isPrintable($0) } && !urls.isEmpty
        let allArchives = urls.allSatisfy { isArchive($0) } && !urls.isEmpty
        let allPDFs = urls.allSatisfy { PDFTools.isPDF($0) } && !urls.isEmpty
        let allVideos = urls.allSatisfy { VideoConvert.isVideo($0) } && !urls.isEmpty
        // Offer Ask whenever the feature is enabled and the selection contains at
        // least one searchable file (the action filters to the supported subset).
        let anyAskable = FileDenSettings.shared.aiEnabled && urls.contains { TextExtractor.canExtract($0) }

        if anyAskable {
            menu.addItem(item("Ask AI…", "sparkles",
                              #selector(ActionBridge.askAI), bridge))
            menu.addItem(.separator())
        }

        menu.addItem(item("Open", "arrow.up.forward.app",
                          #selector(ActionBridge.openItems), bridge))
        menu.addItem(item("Quick Look", "eye",
                          #selector(ActionBridge.quickLook), bridge))
        menu.addItem(item("Reveal in Finder", "folder",
                          #selector(ActionBridge.reveal), bridge))

        menu.addItem(.separator())

        menu.addItem(item("Copy", "doc.on.doc",
                          #selector(ActionBridge.copyItems), bridge))
        menu.addItem(item("Duplicate", "plus.square.on.square",
                          #selector(ActionBridge.duplicate), bridge))
        menu.addItem(item("Copy Path", "link",
                          #selector(ActionBridge.copyPath), bridge))

        menu.addItem(.separator())

        if hasDir || urls.count > 1 {
            menu.addItem(item("Compress to ZIP", "archivebox",
                              #selector(ActionBridge.zip), bridge))
        }
        if allArchives {
            menu.addItem(item("Unarchive", "archivebox.fill",
                              #selector(ActionBridge.unarchive), bridge))
        }
        if allPrintable {
            menu.addItem(item("Print", "printer",
                              #selector(ActionBridge.printItems), bridge))
        }
        if allImages {
            menu.addItem(item("Set as Wallpaper", "photo.on.rectangle",
                              #selector(ActionBridge.wallpaper), bridge))
            menu.addItem(item("Combine to PDF", "doc.badge.plus",
                              #selector(ActionBridge.combinePDF), bridge))
            if let convert = convertImageMenu(bridge: bridge, urls: urls) {
                menu.addItem(convert)
            }
        }
        if allPDFs {
            menu.addItem(pdfToolsMenu(bridge: bridge, count: urls.count))
        }
        if allVideos {
            menu.addItem(convertVideoMenu(bridge: bridge, urls: urls))
        }

        menu.addItem(.separator())

        menu.addItem(item("Share…", "square.and.arrow.up",
                          #selector(ActionBridge.share), bridge))

        menu.addItem(.separator())

        if onRemoveFromDen != nil {
            menu.addItem(item("Remove from Den", "minus.circle",
                              #selector(ActionBridge.removeFromDen), bridge))
        }
        menu.addItem(item("Move to Trash", "trash",
                          #selector(ActionBridge.trash), bridge))

        return menu
    }

    private static func item(_ title: String, _ symbol: String,
                             _ sel: Selector, _ target: AnyObject) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = target
        i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return i
    }

    /// "PDF Tools" submenu. Merge needs at least two documents; the rest apply
    /// to any selection of PDFs. Results are staged into a new den.
    private static func pdfToolsMenu(bridge: ActionBridge, count: Int) -> NSMenuItem {
        let sub = NSMenu()
        if count >= 2 {
            sub.addItem(item("Merge PDFs", "square.stack.3d.up",
                             #selector(ActionBridge.mergePDF), bridge))
        }
        sub.addItem(item("Split into Pages", "rectangle.split.3x1",
                         #selector(ActionBridge.splitPDF), bridge))
        sub.addItem(item("Export Pages as Images", "photo.stack",
                         #selector(ActionBridge.exportPDFImages), bridge))
        sub.addItem(item("Extract Images", "photo.badge.arrow.down",
                         #selector(ActionBridge.extractPDFImages), bridge))
        sub.addItem(item("Extract Text", "doc.plaintext",
                         #selector(ActionBridge.extractPDFText), bridge))

        let parent = NSMenuItem(title: "PDF Tools", action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "doc.richtext", accessibilityDescription: nil)
        parent.submenu = sub
        return parent
    }

    /// "Convert Image" submenu. Visually-lossless format conversion; a target
    /// every selected file already is — or one this OS can't encode (WebP/AVIF
    /// vary by version) — gets hidden. Animated GIFs also get a → video item.
    /// Nil if nothing's left to offer.
    private static func convertImageMenu(bridge: ActionBridge, urls: [URL]) -> NSMenuItem? {
        let targets: [(ImageConvert.Format, Selector)] = [
            (.jpeg, #selector(ActionBridge.convertToJPEG)),
            (.heic, #selector(ActionBridge.convertToHEIC)),
            (.png,  #selector(ActionBridge.convertToPNG)),
            (.tiff, #selector(ActionBridge.convertToTIFF)),
            (.webp, #selector(ActionBridge.convertToWebP)),
            (.avif, #selector(ActionBridge.convertToAVIF)),
        ]
        let sub = NSMenu()
        for (format, selector) in targets
        where ImageConvert.canEncode(format) && !urls.allSatisfy({ format.matches($0) }) {
            sub.addItem(item("To \(format.label)", "photo", selector, bridge))
        }
        if urls.allSatisfy({ $0.pathExtension.lowercased() == "gif" }) {
            if !sub.items.isEmpty { sub.addItem(.separator()) }
            sub.addItem(item("To Video (MP4)", "film", #selector(ActionBridge.convertGIFToVideo), bridge))
        }
        guard !sub.items.isEmpty else { return nil }

        let parent = NSMenuItem(title: "Convert Image", action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        parent.submenu = sub
        return parent
    }

    /// "Convert Video" submenu. → HEVC re-encodes (smaller, visually lossless);
    /// → MP4/MOV rewrap losslessly when possible. Container targets matching the
    /// source extension are hidden. Results are staged into a new den.
    private static func convertVideoMenu(bridge: ActionBridge, urls: [URL]) -> NSMenuItem {
        let sub = NSMenu()
        sub.addItem(item("To HEVC (smaller)", "film",
                         #selector(ActionBridge.convertToHEVC), bridge))
        if !urls.allSatisfy({ $0.pathExtension.lowercased() == "mp4" }) {
            sub.addItem(item("To MP4", "film", #selector(ActionBridge.convertToMP4), bridge))
        }
        if !urls.allSatisfy({ $0.pathExtension.lowercased() == "mov" }) {
            sub.addItem(item("To MOV", "film", #selector(ActionBridge.convertToMOV), bridge))
        }
        sub.addItem(.separator())
        sub.addItem(item("To GIF", "photo.stack",
                         #selector(ActionBridge.convertToGIF), bridge))
        sub.addItem(item("Poster Frame", "photo",
                         #selector(ActionBridge.grabPoster), bridge))
        sub.addItem(.separator())
        sub.addItem(item("Extract Audio", "music.note",
                         #selector(ActionBridge.extractAudio), bridge))

        let parent = NSMenuItem(title: "Convert Video", action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        parent.submenu = sub
        return parent
    }

    static func isImage(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg", "gif", "heic", "tiff", "tif", "bmp", "webp"]
            .contains(url.pathExtension.lowercased())
    }

    static func isPrintable(_ url: URL) -> Bool {
        ["pdf", "png", "jpg", "jpeg", "tiff", "tif", "txt", "rtf"]
            .contains(url.pathExtension.lowercased())
    }

    static func isArchive(_ url: URL) -> Bool {
        ["zip", "tar", "gz", "tgz", "bz2"]
            .contains(url.pathExtension.lowercased())
    }

    static func isDirectory(_ url: URL) -> Bool { url.isDirectoryItem }
}

final class ActionBridge: NSObject {
    nonisolated(unsafe) static var assocKey: UInt8 = 0

    let urls: [URL]
    weak var host: NSView?
    let onShare: (NSView) -> Void
    let onRemove: ([URL]) -> Void
    let onRemoveFromDen: (([URL]) -> Void)?
    let onAsk: (([URL]) -> Void)?

    init(urls: [URL], host: NSView,
         onShare: @escaping (NSView) -> Void,
         onRemove: @escaping ([URL]) -> Void,
         onRemoveFromDen: (([URL]) -> Void)? = nil,
         onAsk: (([URL]) -> Void)? = nil) {
        self.urls = urls
        self.host = host
        self.onShare = onShare
        self.onRemove = onRemove
        self.onRemoveFromDen = onRemoveFromDen
        self.onAsk = onAsk
    }

    @objc func askAI() {
        let searchable = urls.filter { TextExtractor.canExtract($0) }
        let target = searchable.isEmpty ? urls : searchable
        // Prefer opening Ask inline within the owning den; fall back to a
        // standalone window when there's no den context (e.g. menu-bar paths).
        if let onAsk {
            onAsk(target)
        } else {
            NotificationCenter.default.post(name: .askAIRequested, object: target)
        }
    }

    @objc func openItems() { urls.forEach { NSWorkspace.shared.open($0) } }

    @objc func reveal() { NSWorkspace.shared.activateFileViewerSelecting(urls) }

    @objc func quickLook() {
        let task = Process()
        task.launchPath = "/usr/bin/qlmanage"
        task.arguments = ["-p"] + urls.map(\.path)
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        try? task.run()
    }

    @objc func copyItems() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls.map { $0 as NSURL })
    }

    @objc func copyPath() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    @objc func duplicate() {
        let fm = FileManager.default
        for url in urls {
            let base = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            let dir = url.deletingLastPathComponent()
            var n = 1
            var dest: URL
            repeat {
                let suffix = " copy" + (n == 1 ? "" : " \(n)")
                let name = ext.isEmpty ? "\(base)\(suffix)" : "\(base)\(suffix).\(ext)"
                dest = dir.appendingPathComponent(name)
                n += 1
            } while fm.fileExists(atPath: dest.path)
            try? fm.copyItem(at: url, to: dest)
        }
    }

    @objc func zip() {
        let archive = Staging.dir("ZIP")
            .appendingPathComponent("Archive-\(Int(Date().timeIntervalSince1970)).zip")
        let paths = urls.map { $0.path.shellEscaped }.joined(separator: " ")
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "zip -rq \(archive.path.shellEscaped) \(paths)"]
        try? task.run()
        task.waitUntilExit()
        if FileManager.default.fileExists(atPath: archive.path) {
            NSWorkspace.shared.activateFileViewerSelecting([archive])
        }
    }

    @objc func unarchive() {
        for url in urls {
            let dest = url.deletingPathExtension()
            try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            let task = Process()
            task.launchPath = "/usr/bin/unzip"
            task.arguments = ["-oq", url.path, "-d", dest.path]
            try? task.run()
            task.waitUntilExit()
        }
    }

    @objc func printItems() {
        let task = Process()
        task.launchPath = "/usr/bin/lpr"
        task.arguments = urls.map(\.path)
        try? task.run()
    }

    @objc func wallpaper() {
        guard let url = urls.first else { return }
        for screen in NSScreen.screens {
            try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
        }
    }

    @objc func share() {
        guard let host else { return }
        onShare(host)
    }

    @objc func removeFromDen() {
        onRemoveFromDen?(urls)
    }

    @objc func trash() {
        var removed: [URL] = []
        for url in urls {
            if (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil {
                removed.append(url)
            }
        }
        if !removed.isEmpty {
            DispatchQueue.main.async { [onRemove] in onRemove(removed) }
        }
    }

    // MARK: - PDF tools

    @objc func mergePDF()        { runStaged("Merging PDFs", batch: PDFTools.merge) }
    @objc func splitPDF()        { runStaged("Splitting PDF") { url, _ in PDFTools.splitPages([url]) } }
    @objc func exportPDFImages() { runStaged("Exporting pages") { url, _ in PDFTools.exportPageImages([url]) } }
    @objc func extractPDFImages(){ runStaged("Extracting images") { url, _ in PDFTools.extractImages([url]) } }
    @objc func extractPDFText()  { runStaged("Extracting text") { url, _ in PDFTools.extractText([url]) } }
    @objc func combinePDF()      { runStaged("Creating PDF", batch: PDFTools.combineToPDF) }

    // MARK: - Image conversion

    @objc func convertToJPEG() { runStaged("Converting to JPEG") { url, _ in ImageConvert.convert([url], to: .jpeg) } }
    @objc func convertToHEIC() { runStaged("Converting to HEIC") { url, _ in ImageConvert.convert([url], to: .heic) } }
    @objc func convertToPNG()  { runStaged("Converting to PNG")  { url, _ in ImageConvert.convert([url], to: .png) } }
    @objc func convertToTIFF() { runStaged("Converting to TIFF") { url, _ in ImageConvert.convert([url], to: .tiff) } }
    @objc func convertToWebP() { runStaged("Converting to WebP") { url, _ in ImageConvert.convert([url], to: .webp) } }
    @objc func convertToAVIF() { runStaged("Converting to AVIF") { url, _ in ImageConvert.convert([url], to: .avif) } }
    @objc func convertGIFToVideo() { runStaged("GIF → video") { url, progress in VideoConvert.gifToVideo(url, progress: progress) } }

    // MARK: - Video conversion

    @objc func convertToHEVC() { runStaged("Converting to HEVC") { url, progress in VideoConvert.toHEVC(url, progress: progress) } }
    @objc func convertToMP4()  { runStaged("Converting to MP4")  { url, progress in VideoConvert.toMP4(url, progress: progress) } }
    @objc func convertToMOV()  { runStaged("Converting to MOV")  { url, progress in VideoConvert.toMOV(url, progress: progress) } }
    @objc func extractAudio()  { runStaged("Extracting audio")   { url, progress in VideoConvert.extractAudio(url, progress: progress) } }
    @objc func convertToGIF()  { runStaged("Converting to GIF")  { url, progress in VideoConvert.toGIF(url, progress: progress) } }
    @objc func grabPoster()    { runStaged("Grabbing poster")    { url, progress in VideoConvert.posterFrame(url, progress: progress) } }

    /// Run a per-file operation off the main thread, showing a progress HUD and
    /// staging the combined output into a fresh den. `perFile` reports 0…1
    /// progress for the current file; overall progress blends it across the
    /// batch. Beeps if nothing was produced.
    private func runStaged(_ label: String,
                           perFile: @escaping (URL, @escaping (Double) -> Void) -> [URL]) {
        let inputs = urls
        let hud = MainActor.assumeIsolated { ProgressHUD(label: label) }
        DispatchQueue.global(qos: .userInitiated).async {
            var outputs: [URL] = []
            let total = Double(inputs.count)
            for (i, url) in inputs.enumerated() {
                outputs += perFile(url) { sub in
                    Task { @MainActor in hud.update((Double(i) + sub) / total) }
                }
                Task { @MainActor in hud.update(Double(i + 1) / total) }
            }
            let result = outputs
            Task { @MainActor in
                hud.finish()
                if result.isEmpty { NSSound.beep() }
                else { DenManager.shared.openDen(with: result) }
            }
        }
    }

    /// Variant for whole-batch operations (merge, combine) where per-file
    /// progress isn't meaningful; shows an indeterminate HUD.
    private func runStaged(_ label: String, batch: @escaping ([URL]) -> [URL]) {
        let inputs = urls
        let hud = MainActor.assumeIsolated { () -> ProgressHUD in
            let h = ProgressHUD(label: label); h.indeterminate(); return h
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = batch(inputs)
            Task { @MainActor in
                hud.finish()
                if result.isEmpty { NSSound.beep() }
                else { DenManager.shared.openDen(with: result) }
            }
        }
    }
}
