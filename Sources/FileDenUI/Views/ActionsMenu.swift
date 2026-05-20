import SwiftUI
import AppKit
import QuickLookUI
import FileDenCore

struct ActionsMenuButton: NSViewRepresentable {
    var title: String? = nil
    let urls: () -> [URL]
    let onShare: (NSView) -> Void
    let onRemove: ([URL]) -> Void

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
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(urls: urls, onShare: onShare, onRemove: onRemove)
    }

    final class Coordinator: NSObject {
        var urls: () -> [URL]
        var onShare: (NSView) -> Void
        var onRemove: ([URL]) -> Void

        init(urls: @escaping () -> [URL],
             onShare: @escaping (NSView) -> Void,
             onRemove: @escaping ([URL]) -> Void) {
            self.urls = urls
            self.onShare = onShare
            self.onRemove = onRemove
        }

        @objc func tapped(_ sender: NSButton) {
            let list = urls()
            guard !list.isEmpty else { return }
            let menu = FileActions.buildMenu(
                for: list,
                host: sender,
                onShare: onShare,
                onRemove: onRemove
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
        onRemove: @escaping ([URL]) -> Void
    ) -> NSMenu {
        let menu = NSMenu()
        let bridge = ActionBridge(urls: urls, host: host, onShare: onShare, onRemove: onRemove)
        objc_setAssociatedObject(menu, &ActionBridge.assocKey, bridge, .OBJC_ASSOCIATION_RETAIN)

        let hasDir = urls.contains { isDirectory($0) }
        let allImages = urls.allSatisfy { isImage($0) } && !urls.isEmpty
        let allPrintable = urls.allSatisfy { isPrintable($0) } && !urls.isEmpty
        let allArchives = urls.allSatisfy { isArchive($0) } && !urls.isEmpty

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
        }

        menu.addItem(.separator())

        menu.addItem(item("Share…", "square.and.arrow.up",
                          #selector(ActionBridge.share), bridge))

        menu.addItem(.separator())

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

    init(urls: [URL], host: NSView,
         onShare: @escaping (NSView) -> Void,
         onRemove: @escaping ([URL]) -> Void) {
        self.urls = urls
        self.host = host
        self.onShare = onShare
        self.onRemove = onRemove
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
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileDen-\(Int(Date().timeIntervalSince1970)).zip")
        let paths = urls.map { $0.path.shellEscaped }.joined(separator: " ")
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "zip -rq \(tmp.path.shellEscaped) \(paths)"]
        try? task.run()
        task.waitUntilExit()
        if FileManager.default.fileExists(atPath: tmp.path) {
            NSWorkspace.shared.activateFileViewerSelecting([tmp])
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
}
