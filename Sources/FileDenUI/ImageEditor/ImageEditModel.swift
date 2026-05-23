import AppKit
import SwiftUI
import CoreImage
import Combine
import ImageIO
import UniformTypeIdentifiers

/// Drives the image editor for a single file: holds the live `EditState`, renders
/// downscaled GPU previews off the main actor (coalescing rapid slider drags),
/// keeps an undo/redo history, and exports the full-resolution result into a new
/// den — mirroring the app's stage-output-into-a-fresh-den convention.
@MainActor
final class ImageEditModel: ObservableObject {

    /// The left-rail sections. Background removal is a toggle inside Adjust.
    enum Tool: String, CaseIterable, Identifiable {
        case adjust, filters, crop, markup, export
        var id: String { rawValue }
        var label: String {
            switch self {
            case .adjust:  return "Adjust"
            case .filters: return "Filters"
            case .crop:    return "Crop"
            case .markup:  return "Markup"
            case .export:  return "Export"
            }
        }
        var icon: String {
            switch self {
            case .adjust:  return "slider.horizontal.3"
            case .filters: return "camera.filters"
            case .crop:    return "crop"
            case .markup:  return "pencil.tip.crop.circle"
            case .export:  return "square.and.arrow.up"
            }
        }
    }

    /// The active markup sub-tool while the Markup section is open.
    enum MarkupTool: String, CaseIterable, Identifiable {
        case pen, line, arrow, rect, ellipse, highlight, text, blackout, pixelate
        var id: String { rawValue }
        var label: String {
            switch self {
            case .pen: return "Pen"; case .line: return "Line"; case .arrow: return "Arrow"
            case .rect: return "Box"; case .ellipse: return "Oval"; case .highlight: return "Highlight"
            case .text: return "Text"; case .blackout: return "Redact"; case .pixelate: return "Pixelate"
            }
        }
        var icon: String {
            switch self {
            case .pen: return "scribble.variable"; case .line: return "line.diagonal"
            case .arrow: return "arrow.up.right"; case .rect: return "rectangle"
            case .ellipse: return "oval"; case .highlight: return "highlighter"
            case .text: return "textformat"; case .blackout: return "rectangle.fill"
            case .pixelate: return "circle.grid.3x3.fill"
            }
        }
    }

    let url: URL
    @Published private(set) var sourcePixelSize: CGSize

    @Published var state = EditState() { didSet { onStateChanged() } }
    @Published private(set) var preview: CGImage?
    /// Aspect ratio (w/h) of what `preview` currently shows, for canvas layout.
    @Published private(set) var previewAspect: CGFloat = 1
    @Published private(set) var isRendering = false
    @Published private(set) var isExporting = false
    @Published private(set) var backgroundRemovalUnavailable = false
    /// Style swatches for the filter strip — rendered once from the original image
    /// so they're stable while editing (they preview the look, not live tone).
    @Published private(set) var filterThumbs: [(preset: FilterPreset, image: CGImage)] = []

    @Published var activeTool: Tool = .adjust { didSet { if activeTool != oldValue { renderPreview() } } }
    @Published var markupTool: MarkupTool = .pen
    @Published var markupColor: RGBAColor = .red
    /// Stroke width (and, for text, font size) as a fraction of the longest side.
    @Published var markupWidth: Double = 0.006

    private var source: CIImage              // reloaded after an in-place overwrite
    private var bgRemoved: CIImage?           // cached subject isolation
    private var bgRemovedComputed = false

    private var undoStack: [EditState] = []
    private var redoStack: [EditState] = []
    /// Snapshot taken at the start of a continuous gesture (slider/crop drag) so
    /// the whole gesture collapses into one undo step.
    private var interactionBaseline: EditState?

    private var renderTask: Task<Void, Never>?
    private var lastPixelKey: PixelKey?
    /// Longest-side budget for preview renders; the view raises it to match the
    /// canvas so the image stays crisp without paying full-res cost on every drag.
    private var previewBudget: CGFloat = 1800

    // MARK: Init

    init?(url: URL) {
        guard let oriented = ImageEditEngine.loadOriented(url) else { return nil }
        self.url = url
        self.source = oriented
        self.sourcePixelSize = oriented.extent.size
        self.previewAspect = max(oriented.extent.width, 1) / max(oriented.extent.height, 1)
        renderPreview()
        generateFilterThumbs()
    }

    private func generateFilterThumbs() {
        let src = source
        Task.detached(priority: .utility) {
            var out: [(FilterPreset, CGImage)] = []
            for preset in FilterPreset.allCases {
                var img = src
                if let name = preset.ciFilterName {
                    img = src.applyingFilter(name, parameters: preset.params)
                }
                if let cg = ImageEditEngine.shared.cgImage(img, maxDimension: 150) {
                    out.append((preset, cg))
                }
            }
            let thumbs = out
            await MainActor.run { self.filterThumbs = thumbs }
        }
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    // MARK: Editing API

    /// Push the current state for undo, then mutate. Use for discrete actions
    /// (rotate, flip, add annotation, pick a preset).
    func apply(_ change: (inout EditState) -> Void) {
        undoStack.append(state)
        redoStack.removeAll()
        var s = state
        change(&s)
        state = s
    }

    /// Mark the start of a continuous gesture; the matching `endInteraction()`
    /// commits one undo step covering the whole drag.
    func beginInteraction() { interactionBaseline = state }

    func endInteraction() {
        if let base = interactionBaseline, base != state {
            undoStack.append(base)
            redoStack.removeAll()
        }
        interactionBaseline = nil
    }

    /// Live binding to a tone/geometry field that re-renders as it changes.
    func bind<V>(_ keyPath: WritableKeyPath<EditState, V>) -> Binding<V> {
        Binding(get: { self.state[keyPath: keyPath] },
                set: { self.state[keyPath: keyPath] = $0 })
    }

    func undo() {
        guard let s = undoStack.popLast() else { return }
        redoStack.append(state)
        state = s
    }

    func redo() {
        guard let s = redoStack.popLast() else { return }
        undoStack.append(state)
        state = s
    }

    func reset() { apply { $0 = EditState() } }

    /// Set the crop to a centred rectangle of the given pixel aspect ratio (w/h),
    /// or clear it (full frame) when `aspect` is nil.
    func setCropAspect(_ aspect: CGFloat?) {
        apply { s in
            guard let aspect else { s.cropRect = nil; return }
            let ratio = aspect / max(self.previewAspect, 0.0001)   // normalised w/h
            var nw: CGFloat = 1, nh: CGFloat = 1
            if ratio >= 1 { nh = 1 / ratio } else { nw = ratio }
            s.cropRect = CGRect(x: (1 - nw) / 2, y: (1 - nh) / 2, width: nw, height: nh)
        }
    }

    func addAnnotation(_ annotation: Annotation) {
        apply { $0.annotations.append(annotation) }
    }

    func removeLastAnnotation() {
        guard !state.annotations.isEmpty else { return }
        apply { $0.annotations.removeLast() }
    }

    func toggleBackgroundRemoval() {
        if !state.removeBackground { ensureBackgroundRemoved() }
        apply { $0.removeBackground.toggle() }
    }

    /// Raise the preview resolution budget to match the on-screen canvas.
    func setPreviewBudget(_ pixels: CGFloat) {
        let rounded = (pixels * (NSScreen.main?.backingScaleFactor ?? 2)).rounded()
        guard rounded > previewBudget * 1.15 || rounded < previewBudget * 0.6 else { return }
        previewBudget = max(rounded, 600)
        renderPreview()
    }

    // MARK: Rendering

    /// Re-render only when the pixel-affecting subset of the state changed (vector
    /// annotations are drawn live by the overlay, so a freehand drag doesn't churn
    /// the GPU). Crop mode renders the *uncropped* frame so the overlay can sit
    /// over the full image.
    private func onStateChanged() {
        let key = PixelKey(state: state, cropMode: activeTool == .crop, budget: previewBudget)
        guard key != lastPixelKey else { return }
        renderPreview()
    }

    private func renderPreview() {
        renderTask?.cancel()
        let inCrop = activeTool == .crop
        var s = state
        if inCrop { s.cropRect = nil }                 // show full frame under the crop overlay
        lastPixelKey = PixelKey(state: state, cropMode: inCrop, budget: previewBudget)

        let src = source
        let bg = bgRemoved
        let budget = previewBudget
        isRendering = true
        renderTask = Task.detached(priority: .userInitiated) {
            let composed = ImageEditEngine.shared.composed(source: src, bgRemoved: bg, state: s)
            let cg = ImageEditEngine.shared.cgImage(composed, maxDimension: budget)
            await MainActor.run {
                guard !Task.isCancelled else { return }
                if let cg {
                    self.preview = cg
                    self.previewAspect = CGFloat(cg.width) / CGFloat(max(cg.height, 1))
                }
                self.isRendering = false
            }
        }
    }

    private func ensureBackgroundRemoved() {
        guard !bgRemovedComputed else { return }
        bgRemovedComputed = true
        let src = source
        Task.detached(priority: .userInitiated) {
            let result = ImageEditEngine.shared.removeBackground(from: src)
            await MainActor.run {
                self.bgRemoved = result
                self.backgroundRemovalUnavailable = (result == nil)
                if result == nil, self.state.removeBackground {
                    self.apply { $0.removeBackground = false }
                } else if self.state.removeBackground {
                    self.renderPreview()
                }
            }
        }
    }

    // MARK: Export

    /// Encode the full-resolution result and open it in a new den. Returns the
    /// staged URL, or nil if rendering/encoding failed.
    @discardableResult
    func export(format: ImageConvert.Format, quality: Double, scale: Double) async -> URL? {
        isExporting = true
        defer { isExporting = false }

        let s = state
        let src = source
        let bg = state.removeBackground ? bgRemoved : nil
        let annotations = state.annotations
        let stem = url.deletingPathExtension().lastPathComponent

        let result: URL? = await Task.detached(priority: .userInitiated) {
            let composed = ImageEditEngine.shared.composed(source: src, bgRemoved: bg, state: s)
            let maxDim: CGFloat? = scale < 0.999
                ? max(composed.extent.width, composed.extent.height) * CGFloat(scale)
                : nil
            guard var cg = ImageEditEngine.shared.cgImage(composed, maxDimension: maxDim) else { return nil }
            cg = AnnotationBaker.bake(annotations, onto: cg)
            return Self.encode(cg, format: format, quality: quality, stem: stem)
        }.value

        if let result { DenManager.shared.openDen(with: [result]) }
        else { NSSound.beep() }
        return result
    }

    /// Re-encode the edited result back onto the original file, in its original
    /// format. Destructive — the previous contents are gone. Because `source`
    /// reads the file lazily, we reload from the freshly written file and reset to
    /// a pristine state afterwards (the edits now live in the file itself).
    @discardableResult
    func overwriteOriginal(quality: Double, scale: Double) async -> Bool {
        isExporting = true
        defer { isExporting = false }

        let s = state
        let src = source
        let bg = state.removeBackground ? bgRemoved : nil
        let annotations = state.annotations
        let target = url
        let format = Self.originalFormat(for: target)

        let ok = await Task.detached(priority: .userInitiated) { () -> Bool in
            let composed = ImageEditEngine.shared.composed(source: src, bgRemoved: bg, state: s)
            let maxDim: CGFloat? = scale < 0.999
                ? max(composed.extent.width, composed.extent.height) * CGFloat(scale)
                : nil
            guard var cg = ImageEditEngine.shared.cgImage(composed, maxDimension: maxDim) else { return false }
            cg = AnnotationBaker.bake(annotations, onto: cg)
            return Self.writeInPlace(cg, to: target, format: format, quality: quality)
        }.value

        guard ok else { NSSound.beep(); return false }

        if let reloaded = ImageEditEngine.loadOriented(target) {
            source = reloaded
            sourcePixelSize = reloaded.extent.size
        }
        bgRemoved = nil
        bgRemovedComputed = false
        undoStack = []
        redoStack = []
        filterThumbs = []
        state = EditState()        // didSet → re-render the now-pristine file
        generateFilterThumbs()
        return true
    }

    /// The original file's own format (so an in-place overwrite keeps its type),
    /// falling back to PNG when the OS can't re-encode it.
    private static func originalFormat(for url: URL) -> ImageConvert.Format {
        for f in ImageConvert.Format.allCases where f.matches(url) && ImageConvert.canEncode(f) {
            return f
        }
        return .png
    }

    /// Encode `image` and atomically replace the file at `url`.
    private nonisolated static func writeInPlace(_ image: CGImage, to url: URL,
                                                 format: ImageConvert.Format, quality: Double) -> Bool {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, format.typeID as CFString, 1, nil) else { return false }
        var options: [CFString: Any] = [:]
        if format.isLossy { options[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return false }
        return (try? (data as Data).write(to: url, options: .atomic)) != nil
    }

    /// Write `image` to the staging area as `format`. PNG/TIFF ignore quality and
    /// keep alpha (so background-removed cut-outs stay transparent).
    private nonisolated static func encode(_ image: CGImage, format: ImageConvert.Format,
                                           quality: Double, stem: String) -> URL? {
        let dir = Staging.dir("IMG")
        let dest = Staging.uniqueURL(in: dir, name: "\(stem) edited.\(format.ext)")
        guard let destination = CGImageDestinationCreateWithURL(
            dest as CFURL, format.typeID as CFString, 1, nil) else { return nil }
        var options: [CFString: Any] = [:]
        if format.isLossy { options[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        return CGImageDestinationFinalize(destination) ? dest : nil
    }

    /// The pixel-affecting fingerprint, so non-redaction annotation edits don't
    /// trigger a GPU re-render (the SwiftUI overlay shows those live).
    private struct PixelKey: Equatable {
        var geometry: [Double]
        var tone: [Double]
        var preset: FilterPreset
        var removeBackground: Bool
        var redactions: [String]
        var cropMode: Bool
        var budget: CGFloat

        init(state s: EditState, cropMode: Bool, budget: CGFloat) {
            let crop = s.cropRect ?? CGRect(x: -1, y: -1, width: -1, height: -1)
            geometry = [Double(s.rotationQuarters), s.straighten, s.flipH ? 1 : 0, s.flipV ? 1 : 0,
                        Double(crop.minX), Double(crop.minY), Double(crop.width), Double(crop.height)]
            tone = [s.exposure, s.brightness, s.contrast, s.saturation, s.vibrance,
                    s.warmth, s.highlights, s.shadows, s.sharpness]
            preset = s.preset
            removeBackground = s.removeBackground
            redactions = s.annotations.filter { $0.isRedaction }.map { "\($0.id)\($0.kind)" }
            self.cropMode = cropMode
            self.budget = budget
        }
    }
}
