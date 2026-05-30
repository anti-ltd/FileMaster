import AppKit
import Combine
import CoreGraphics
import Foundation

/// Drives the vector editor for a single `.svg` file — the vector analogue of
/// `ImageEditModel`. Holds the live `SVGDocument`, an undo/redo history of whole-
/// document snapshots, the current selection, and the transform sliders for the
/// selected shape. Saving mirrors the raster editor: export into a fresh den, or
/// overwrite the original file in place.
///
/// Transform model: the Scale / Rotation / Move controls are **session-relative**.
/// Selecting a shape captures its current transform as a baseline (and its centre);
/// the sliders then express a delta about that centre, recomposed from the baseline
/// on every change so there's no cumulative drift. Reselecting resets them to
/// 100 % / 0° / (0,0). "Reset Shape" restores the element to its as-loaded form.
@MainActor
final class SVGEditModel: ObservableObject {

    enum Mode: String, CaseIterable, Identifiable {
        case shapes, nodes, export
        var id: String { rawValue }
        var label: String {
            switch self {
            case .shapes: return "Shapes"
            case .nodes:  return "Nodes"
            case .export: return "Export"
            }
        }
        var icon: String {
            switch self {
            case .shapes: return "square.on.circle"
            case .nodes:  return "point.topleft.down.to.point.bottomright.curvepath"
            case .export: return "square.and.arrow.up"
            }
        }
    }

    let url: URL
    let unsupportedCount: Int

    @Published var doc: SVGDocument
    @Published var selection: UUID?
    @Published var selectedNode: SVGGeometry.NodeHit?
    @Published var mode: Mode = .shapes
    @Published private(set) var isExporting = false

    // Session-relative transform controls for the selected shape.
    @Published var editScale: Double = 1 { didSet { if !configuring { applyEditTransform() } } }
    @Published var editRotation: Double = 0 { didSet { if !configuring { applyEditTransform() } } }
    @Published var editMoveX: Double = 0 { didSet { if !configuring { applyEditTransform() } } }
    @Published var editMoveY: Double = 0 { didSet { if !configuring { applyEditTransform() } } }

    private let original: SVGDocument
    private var undoStack: [SVGDocument] = []
    private var redoStack: [SVGDocument] = []
    private var interactionBaseline: SVGDocument?

    /// Baseline for the session-relative transform of the current selection.
    private var baselineTransform: Affine = .identity
    private var baselineCenter: CGPoint = .zero
    private var configuring = false      // suppress slider didSet while we reset them

    init?(url: URL) {
        guard let parsed = SVGParser.parse(contentsOf: url) else { return nil }
        self.url = url
        self.doc = parsed
        self.original = parsed
        self.unsupportedCount = parsed.unsupportedCount
    }

    var docAspect: CGFloat { doc.aspect }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var isPristine: Bool { doc == original }

    var selectedIndex: Int? {
        guard let sel = selection else { return nil }
        return doc.elements.firstIndex { $0.id == sel }
    }
    var selectedElement: SVGElement? { selectedIndex.map { doc.elements[$0] } }

    // MARK: - Undo / interaction (mirrors ImageEditModel)

    func apply(_ change: (inout SVGDocument) -> Void) {
        undoStack.append(doc)
        redoStack.removeAll()
        var d = doc
        change(&d)
        doc = d
    }

    func beginInteraction() { interactionBaseline = doc }

    func endInteraction() {
        if let base = interactionBaseline, base != doc {
            undoStack.append(base)
            redoStack.removeAll()
        }
        interactionBaseline = nil
    }

    func undo() {
        guard let d = undoStack.popLast() else { return }
        redoStack.append(doc); doc = d
        refreshSelectionState()
    }

    func redo() {
        guard let d = redoStack.popLast() else { return }
        undoStack.append(doc); doc = d
        refreshSelectionState()
    }

    func resetFile() {
        apply { $0 = original }
        select(nil)
    }

    // MARK: - Selection

    func select(_ id: UUID?) {
        selection = id
        selectedNode = nil
        configureSelectionBaseline()
    }

    private func configureSelectionBaseline() {
        configuring = true
        defer { configuring = false }
        editScale = 1; editRotation = 0; editMoveX = 0; editMoveY = 0
        if let el = selectedElement {
            baselineTransform = el.transform
            baselineCenter = SVGGeometry.bounds(of: el).center
        }
    }

    /// After undo/redo the selected id may have vanished; keep it only if present.
    private func refreshSelectionState() {
        if let sel = selection, !doc.elements.contains(where: { $0.id == sel }) {
            select(nil)
        } else {
            configureSelectionBaseline()
        }
    }

    // MARK: - Shape transform (session-relative)

    /// Recompose the selected element's transform from its captured baseline plus
    /// the current scale/rotation (about the captured centre) and move.
    private func applyEditTransform() {
        guard let idx = selectedIndex else { return }
        let c = baselineCenter
        let r = editRotation * .pi / 180
        var delta = CGAffineTransform.identity
        delta = delta.translatedBy(x: c.x + editMoveX, y: c.y + editMoveY)
        delta = delta.rotated(by: r)
        delta = delta.scaledBy(x: editScale, y: editScale)
        delta = delta.translatedBy(x: -c.x, y: -c.y)
        let composed = baselineTransform.cg.concatenating(delta)
        doc.elements[idx].transform = Affine(composed)
    }

    /// After a committed transform edit (slider release or canvas-drag end), fold the
    /// session delta into a fresh baseline and reset the sliders to identity, so the
    /// next edit — whether slider or canvas — starts from the element's true state.
    func commitTransformEdit() {
        guard selectedElement != nil else { return }
        configureSelectionBaseline()
    }

    func setFill(_ color: RGBAColor?) {
        guard let idx = selectedIndex else { return }
        apply { $0.elements[idx].style.fill = color }
    }

    func setOpacity(_ value: Double) {
        guard let idx = selectedIndex else { return }
        doc.elements[idx].style.opacity = value     // bracketed by begin/endInteraction
    }

    func deleteSelection() {
        guard let idx = selectedIndex else { return }
        apply { $0.elements.remove(at: idx) }
        select(nil)
    }

    /// Restore the selected element to its as-loaded geometry/style/transform.
    func resetShape() {
        guard let sel = selection,
              let idx = doc.elements.firstIndex(where: { $0.id == sel }),
              let orig = original.elements.first(where: { $0.id == sel }) else { return }
        apply { $0.elements[idx] = orig }
        configureSelectionBaseline()
    }

    /// Drag-move on the canvas: translate the selection by a user-space delta from
    /// the interaction baseline. Bracketed by begin/endInteraction for one undo step.
    func translateSelection(by delta: CGSize, fromBaseline base: Affine) {
        guard let idx = selectedIndex else { return }
        let t = base.cg.concatenating(CGAffineTransform(translationX: delta.width, y: delta.height))
        doc.elements[idx].transform = Affine(t)
    }

    /// The selected element's transform, for capturing a drag baseline on the canvas.
    var selectedTransform: Affine? { selectedElement?.transform }

    // MARK: - Node editing

    /// Move a path node anchor or control handle to `userPoint` (user space). For an
    /// anchor, its attached handles follow by the same delta. Bracketed externally.
    func updateNode(_ hit: SVGGeometry.NodeHit, to userPoint: CGPoint) {
        guard let idx = selectedIndex,
              case .path(var data) = doc.elements[idx].geometry else { return }
        let inv = doc.elements[idx].transform.cg.inverted()
        let local = userPoint.applying(inv)

        switch hit {
        case .anchor(let s, let n):
            guard data.subpaths.indices.contains(s), data.subpaths[s].nodes.indices.contains(n) else { return }
            var node = data.subpaths[s].nodes[n]
            let d = CGPoint(x: local.x - node.anchor.x, y: local.y - node.anchor.y)
            node.anchor = local
            if let ci = node.controlIn { node.controlIn = CGPoint(x: ci.x + d.x, y: ci.y + d.y) }
            if let co = node.controlOut { node.controlOut = CGPoint(x: co.x + d.x, y: co.y + d.y) }
            data.subpaths[s].nodes[n] = node
        case .controlIn(let s, let n):
            guard data.subpaths.indices.contains(s), data.subpaths[s].nodes.indices.contains(n) else { return }
            data.subpaths[s].nodes[n].controlIn = local
        case .controlOut(let s, let n):
            guard data.subpaths.indices.contains(s), data.subpaths[s].nodes.indices.contains(n) else { return }
            data.subpaths[s].nodes[n].controlOut = local
        }
        doc.elements[idx].geometry = .path(data)
    }

    // MARK: - Save

    /// Serialize and stage into a fresh den (mirrors `ImageEditModel.export`).
    @discardableResult
    func export() async -> URL? {
        isExporting = true
        defer { isExporting = false }
        let stem = url.deletingPathExtension().lastPathComponent
        let data = SVGSerializer.data(doc)
        let dir = Staging.dir("IMG")
        let dest = Staging.uniqueURL(in: dir, name: "\(stem) edited.svg")
        guard (try? data.write(to: dest)) != nil else { NSSound.beep(); return nil }
        DenManager.shared.openDen(with: [dest])
        return dest
    }

    /// Overwrite the original file atomically, then reset to a pristine baseline
    /// (the edits now live in the file).
    @discardableResult
    func overwriteOriginal() async -> Bool {
        isExporting = true
        defer { isExporting = false }
        let data = SVGSerializer.data(doc)
        guard (try? data.write(to: url, options: .atomic)) != nil else { NSSound.beep(); return false }
        undoStack = []; redoStack = []
        return true
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
