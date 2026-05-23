#if APPSTAGE
import AppKit
import SwiftUI
import ImageIO
import FileDenCore
import FileDenAI

// Dev tool: render one UI state on-screen for appstage to screenshot, then keep
// running so the window can be captured. Activated by `--appstage <state>`.
//
// Everything is synthetic: the den holds throwaway placeholder files created in
// an isolated temp dir (Paths is forced there in APPSTAGE builds), and the Ask
// transcript is a pre-built conversation — the indexer and LLM never run. Real
// files, dens, indices and notebooks are never touched. Prints one line:
//
//   @@APPSTAGE_READY@@ {"window":<cgWindowID>,"w":W,"h":H,"slug":"<state>"}
//
// This whole file is compiled out of normal/release builds.
@MainActor
enum AppStageCapture {
    static let state: String? = {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--appstage"), i + 1 < args.count {
            return args[i + 1]
        }
        return nil
    }()

    static func run(state: String) {
        NSApp.setActivationPolicy(.accessory)

        let cornerRadius: CGFloat
        let inner: AnyView
        switch state {
        case "ask":
            let session = QASession(demoMessages: demoMessages(), fileCount: 3)
            inner = AnyView(QAView(session: session).frame(width: 440, height: 430))
            cornerRadius = 16
        case "compact":
            inner = AnyView(ShelfView(initialURLs: demoFiles(), initiallyExpanded: false))
            cornerRadius = 24
        case "drop":
            inner = AnyView(ShelfView(initialURLs: demoFiles(), initiallyExpanded: true,
                                      initiallyTargeted: true))
            cornerRadius = 24
        case "list":
            inner = AnyView(ShelfView(initialURLs: demoFiles(), initiallyExpanded: true,
                                      initialViewMode: .list))
            cornerRadius = 24
        case "pdf":
            inner = AnyView(ShelfView(initialURLs: pdfFiles(), initiallyExpanded: true))
            cornerRadius = 24
        case "convert":
            inner = AnyView(ShelfView(initialURLs: mediaFiles(), initiallyExpanded: true))
            cornerRadius = 24
        case let s where s.hasPrefix("edit"):
            if let model = ImageEditModel(url: demoImageURL()) {
                switch s {
                case "edit-filters":
                    model.activeTool = .filters
                    model.apply { $0.preset = .chrome }
                case "edit-crop":
                    model.activeTool = .crop
                    model.setCropAspect(16.0 / 9.0)
                case "edit-markup":
                    model.activeTool = .markup
                    model.addAnnotation(Annotation(kind: .arrow(CGPoint(x: 0.18, y: 0.25), CGPoint(x: 0.46, y: 0.52)), color: .red, width: 0.012))
                    model.addAnnotation(Annotation(kind: .rect(CGRect(x: 0.55, y: 0.18, width: 0.32, height: 0.34)), color: .yellow, width: 0.009))
                    model.addAnnotation(Annotation(kind: .text("Important!", CGPoint(x: 0.2, y: 0.08), 0.06), color: .white, width: 0.006))
                    model.addAnnotation(Annotation(kind: .redactBlackout(CGRect(x: 0.12, y: 0.78, width: 0.34, height: 0.1)), color: .black))
                case "edit-adjusted":
                    model.apply { $0.exposure = 0.7; $0.contrast = 1.25; $0.saturation = 1.6; $0.warmth = 0.5 }
                case "edit-export":
                    model.activeTool = .export
                default: break
                }
                inner = AnyView(
                    HStack(spacing: 0) {
                        ImageEditorView(model: model, onClose: {})
                            .frame(width: 560)
                        Divider().opacity(0.4)
                        ImageEditorControlsPane(model: model)
                            .frame(width: 280)
                    }
                    .frame(width: 841, height: 660))
            } else {
                inner = AnyView(Text("no demo image").frame(width: 841, height: 660))
            }
            cornerRadius = 16
        default: // "shelf"
            inner = AnyView(ShelfView(initialURLs: demoFiles(), initiallyExpanded: true))
            cornerRadius = 24
        }

        // Opaque backing so the den/chat material doesn't sample the desktop;
        // clipped to a rounded card; the window itself is transparent and sized
        // tight, so the capture is just the app's UI with transparent surround.
        let root = inner
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .environment(\.colorScheme, .dark)

        let host = NSHostingController(rootView: root)
        let window = CaptureWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 420),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.contentViewController = host
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // ShelfView expands in onAppear, so re-measure and size the window to the
        // settled content before reporting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            host.view.layoutSubtreeIfNeeded()
            let fit = host.view.fittingSize
            if fit.width > 80 && fit.height > 80 {
                window.setContentSize(fit)
                window.center()
            }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                let f = window.frame
                print(
                    "@@APPSTAGE_READY@@ {\"window\":\(window.windowNumber),"
                    + "\"w\":\(Int(f.width)),\"h\":\(Int(f.height)),\"slug\":\"\(state)\"}"
                )
                fflush(stdout)
            }
        }
    }

    // Throwaway placeholder files (real, empty) so the den shows proper type
    // icons via NSWorkspace without referencing any of the user's files.
    private static func demoFiles() -> [URL] {
        placeholders(["Q3 Report.pdf", "Brand Moodboard.png", "Contract.docx",
                       "Release Notes.md", "assets.zip"])
    }

    // A spread of PDF documents — triggers PDF Tools in the actions menu.
    private static func pdfFiles() -> [URL] {
        placeholders(["Annual Report.pdf", "Brand Guide.pdf",
                       "Press Kit.pdf", "Product Spec.pdf"])
    }

    // A spread of image + video files — triggers Convert Image / Convert Video.
    private static func mediaFiles() -> [URL] {
        placeholders(["hero.png", "product-shot.jpg", "walkthrough.mov",
                       "banner.webp", "thumbnail.heic"])
    }

    // A real, colourful test image so tone/crop/markup edits are visible.
    private static func demoImageURL() -> URL {
        let dir = Paths.appSupport.appendingPathComponent("DemoFiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("editor-demo.png")
        let w = 1280, h = 853
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return url }
        let colors = [CGColor(red: 0.10, green: 0.45, blue: 0.92, alpha: 1),
                      CGColor(red: 0.96, green: 0.42, blue: 0.30, alpha: 1)] as CFArray
        if let grad = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(grad, start: .zero,
                                   end: CGPoint(x: w, y: h), options: [])
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.85))
        ctx.fillEllipse(in: CGRect(x: 180, y: 360, width: 320, height: 320))
        ctx.setFillColor(CGColor(red: 1, green: 0.85, blue: 0.12, alpha: 0.92))
        ctx.fillEllipse(in: CGRect(x: 720, y: 150, width: 400, height: 400))
        ctx.setFillColor(CGColor(red: 0.15, green: 0.8, blue: 0.5, alpha: 0.9))
        ctx.fill(CGRect(x: 450, y: 80, width: 240, height: 240))
        guard let cg = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else { return url }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
        return url
    }

    private static func placeholders(_ names: [String]) -> [URL] {
        let dir = Paths.appSupport.appendingPathComponent("DemoFiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return names.map { name in
            let url = dir.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: Data())
            }
            return url
        }
    }

    // A pre-built, grounded answer with a citation — no indexer, no LLM.
    private static func demoMessages() -> [ChatMessage] {
        let docURL = Paths.appSupport
            .appendingPathComponent("DemoFiles/Q3 Report.pdf")
        let chunk = Chunk(
            sourceURL: docURL,
            ordinal: 2,
            text: "Revenue grew 24% quarter-over-quarter, driven mainly by enterprise renewals and the launch of the EU region.",
            locator: .pdfPage(index: 2, charRange: nil)
        )
        let citation = Citation(id: 1, chunk: StoredChunk(id: 1, chunk: chunk), score: 0.95)
        return [
            ChatMessage(role: .user, text: "What drove the revenue increase this quarter?"),
            ChatMessage(
                role: .assistant,
                text: "Revenue grew 24% quarter-over-quarter, driven mainly by enterprise renewals and the new EU region launch.",
                citations: [citation],
                isStreaming: false
            ),
        ]
    }
}

private final class CaptureWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
#endif
