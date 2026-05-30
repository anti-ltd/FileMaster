import SwiftUI
import AppKit

/// The vector editor's **viewer pane** — the middle pane in the den's edit layout,
/// mirroring `ImageEditorView`. Header (undo/redo/reset-file/close) plus a native
/// canvas that draws the live `SVGDocument`, the selection box with scale/rotate
/// handles, and (in Nodes mode) the path's anchors and bezier control handles.
/// Interaction (select / move / scale / rotate / node-drag) is handled here; the
/// numeric controls live in `SVGEditorControlsPane`.
struct SVGEditorView: View {
    @ObservedObject var model: SVGEditModel
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            canvas
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "scribble.variable").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.url.lastPathComponent)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                Text(statusLine)
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if model.isExporting { ProgressView().controlSize(.small) }
            iconButton("arrow.uturn.backward", help: "Undo", enabled: model.canUndo) { model.undo() }
            iconButton("arrow.uturn.forward", help: "Redo", enabled: model.canRedo) { model.redo() }
            iconButton("arrow.counterclockwise", help: "Reset file",
                       enabled: !model.isPristine) { model.resetFile() }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Close editor")
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .background(WindowDragHandle())
    }

    private var statusLine: String {
        let vb = model.doc.viewBox
        let n = model.doc.elements.count
        var s = "\(Int(vb.width))×\(Int(vb.height)) · \(n) shape\(n == 1 ? "" : "s") · on-device"
        if model.unsupportedCount > 0 { s += " · \(model.unsupportedCount) not editable" }
        return s
    }

    // MARK: - Canvas

    private var canvas: some View {
        GeometryReader { geo in
            let fit = FitRect.make(aspect: model.docAspect, in: geo.size)
            let vt = SVGGeometry.viewTransform(viewBox: model.doc.viewBox, fit: fit)
            ZStack {
                Checkerboard()
                    .frame(width: fit.width, height: fit.height)
                    .position(x: fit.midX, y: fit.midY)
                    .opacity(0.5)

                SVGCanvas(doc: model.doc, viewTransform: vt, scale: fit.width / max(model.doc.viewBox.width, 1))

                if let el = model.selectedElement {
                    if model.mode == .nodes, case .path(let data) = el.geometry {
                        NodeOverlay(data: data, elementTransform: el.transform.cg,
                                    viewTransform: vt, selected: model.selectedNode)
                    } else {
                        SelectionOverlay(rect: SVGGeometry.bounds(of: el).applying(vt))
                    }
                }

                SVGInteractionLayer(model: model, fit: fit, viewTransform: vt)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func iconButton(_ symbol: String, help: String, enabled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(enabled ? Color.secondary : Color.secondary.opacity(0.3))
                .frame(width: 28, height: 28)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }
}

// MARK: - Shape canvas

/// Draws every element's `CGPath` mapped into the fitted view rect. Re-renders
/// cheaply from the value model on each change (same pattern as `AnnotationOverlay`).
private struct SVGCanvas: View {
    let doc: SVGDocument
    let viewTransform: CGAffineTransform
    let scale: CGFloat

    var body: some View {
        Canvas { ctx, _ in
            var vt = viewTransform
            for el in doc.elements {
                let userPath = SVGGeometry.cgPath(for: el)
                guard let viewPath = userPath.copy(using: &vt) else { continue }
                let path = Path(viewPath)
                ctx.opacity = el.style.opacity
                if let fill = el.style.fill {
                    ctx.fill(path, with: .color(Color(fill.nsColor)),
                             style: FillStyle(eoFill: el.style.fillRule == .evenodd))
                }
                if let stroke = el.style.stroke {
                    ctx.stroke(path, with: .color(Color(stroke.nsColor)),
                               lineWidth: max(el.style.strokeWidth * scale, 0.5))
                }
                ctx.opacity = 1
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Selection overlay

private struct SelectionOverlay: View {
    let rect: CGRect
    private let handle: CGFloat = 7

    var body: some View {
        ZStack {
            Rectangle()
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

            // Rotate knob tether + knob.
            Path { p in
                p.move(to: CGPoint(x: rect.midX, y: rect.minY))
                p.addLine(to: CGPoint(x: rect.midX, y: rect.minY - 22))
            }
            .stroke(Color.accentColor, lineWidth: 1)
            knob(at: CGPoint(x: rect.midX, y: rect.minY - 22), system: "arrow.clockwise")

            ForEach(corners, id: \.self) { c in
                Rectangle()
                    .fill(.white)
                    .frame(width: handle, height: handle)
                    .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1.5))
                    .position(c)
            }
        }
        .allowsHitTesting(false)
    }

    private var corners: [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
    }

    private func knob(at p: CGPoint, system: String) -> some View {
        Circle().fill(.white).frame(width: 16, height: 16)
            .overlay(Circle().stroke(Color.accentColor, lineWidth: 1.5))
            .overlay(Image(systemName: system).font(.system(size: 8, weight: .bold)).foregroundStyle(Color.accentColor))
            .position(p)
    }
}

// MARK: - Node overlay

private struct NodeOverlay: View {
    let data: PathData
    let elementTransform: CGAffineTransform
    let viewTransform: CGAffineTransform
    let selected: SVGGeometry.NodeHit?

    var body: some View {
        Canvas { ctx, _ in
            let m = elementTransform.concatenating(viewTransform)   // local → view
            for sp in data.subpaths {
                for node in sp.nodes {
                    let a = node.anchor.applying(m)
                    // Control tethers + handles.
                    for ctrl in [node.controlIn, node.controlOut].compactMap({ $0 }) {
                        let c = ctrl.applying(m)
                        var tether = Path(); tether.move(to: a); tether.addLine(to: c)
                        ctx.stroke(tether, with: .color(Color.accentColor.opacity(0.6)), lineWidth: 1)
                        ctx.fill(Path(ellipseIn: CGRect(x: c.x - 3.5, y: c.y - 3.5, width: 7, height: 7)),
                                 with: .color(Color.accentColor))
                    }
                    // Anchor square.
                    let r = CGRect(x: a.x - 4, y: a.y - 4, width: 8, height: 8)
                    ctx.fill(Path(r), with: .color(.white))
                    ctx.stroke(Path(r), with: .color(Color.accentColor), lineWidth: 1.5)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Interaction

/// Transparent gesture layer. Decides on drag-start what the gesture does based on
/// what's under the start point (a handle, the selected shape body, another shape,
/// or empty space), then drives the model. A zero-distance drag is a tap (select /
/// deselect). One drag = one undo step via the model's begin/endInteraction.
private struct SVGInteractionLayer: View {
    @ObservedObject var model: SVGEditModel
    let fit: CGRect
    let viewTransform: CGAffineTransform

    @State private var drag: Drag?

    private enum Drag {
        case tap(CGPoint)
        case move(base: Affine, startUser: CGPoint)
        case scale(center: CGPoint, startUser: CGPoint, baseScale: Double)
        case rotate(center: CGPoint, startUser: CGPoint, baseRot: Double)
        case node(SVGGeometry.NodeHit)
    }

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { handleChange($0) }
                .onEnded { handleEnd($0) })
    }

    private func toUser(_ p: CGPoint) -> CGPoint { p.applying(viewTransform.inverted()) }

    private func handleChange(_ g: DragGesture.Value) {
        let user = toUser(g.location)
        if case .none = drag { begin(at: g.startLocation) }

        switch drag {
        case .move(let base, let start):
            model.translateSelection(by: CGSize(width: user.x - start.x, height: user.y - start.y),
                                     fromBaseline: base)
        case .scale(let center, let start, let baseScale):
            let d0 = max(hypot(start.x - center.x, start.y - center.y), 0.0001)
            let d1 = hypot(user.x - center.x, user.y - center.y)
            model.editScale = max(0.05, baseScale * Double(d1 / d0))
        case .rotate(let center, let start, let baseRot):
            let a0 = atan2(start.y - center.y, start.x - center.x)
            let a1 = atan2(user.y - center.y, user.x - center.x)
            model.editRotation = baseRot + Double((a1 - a0) * 180 / .pi)
        case .node(let hit):
            model.updateNode(hit, to: user)
        case .tap, .none:
            break
        }
    }

    /// Classify the gesture from its start point.
    private func begin(at viewStart: CGPoint) {
        let user = toUser(viewStart)

        // Node mode: hit-test nodes of the selected path first.
        if model.mode == .nodes, let el = model.selectedElement,
           case .path(let data) = el.geometry,
           let hit = SVGGeometry.hitTestNode(viewStart.applying(viewTransform.inverted()),
                                             path: data, transform: el.transform.cg,
                                             tolerance: toleranceUser(12)) {
            model.selectedNode = hit
            model.beginInteraction()
            drag = .node(hit)
            return
        }

        // Selection handles (scale corners, rotate knob) take priority.
        if let el = model.selectedElement, model.mode == .shapes {
            let vb = SVGGeometry.bounds(of: el).applying(viewTransform)
            let center = toUser(CGPoint(x: vb.midX, y: vb.midY))
            if near(viewStart, CGPoint(x: vb.midX, y: vb.minY - 22), 12) {
                model.beginInteraction()
                drag = .rotate(center: center, startUser: user, baseRot: model.editRotation)
                return
            }
            for c in [CGPoint(x: vb.minX, y: vb.minY), CGPoint(x: vb.maxX, y: vb.minY),
                      CGPoint(x: vb.minX, y: vb.maxY), CGPoint(x: vb.maxX, y: vb.maxY)]
            where near(viewStart, c, 12) {
                model.beginInteraction()
                drag = .scale(center: center, startUser: user, baseScale: model.editScale)
                return
            }
        }

        // Otherwise hit-test a shape: select it and start a move, or empty → tap.
        if let id = SVGGeometry.hitTest(user, in: model.doc, tolerance: toleranceUser(4)) {
            if model.selection != id { model.select(id) }
            if let base = model.selectedTransform {
                model.beginInteraction()
                drag = .move(base: base, startUser: user)
            }
        } else {
            drag = .tap(viewStart)
        }
    }

    private func handleEnd(_ g: DragGesture.Value) {
        let moved = hypot(g.translation.width, g.translation.height) > 3
        switch drag {
        case .tap where !moved:
            // Tap on empty space deselects.
            let user = toUser(g.location)
            model.select(SVGGeometry.hitTest(user, in: model.doc, tolerance: toleranceUser(4)))
        case .move, .scale, .rotate, .node:
            model.endInteraction()
            model.commitTransformEdit()
        default:
            break
        }
        drag = nil
    }

    private func near(_ a: CGPoint, _ b: CGPoint, _ tol: CGFloat) -> Bool {
        hypot(a.x - b.x, a.y - b.y) <= tol
    }

    /// Convert a view-space pixel tolerance to user space (vt is uniform scale).
    private func toleranceUser(_ px: CGFloat) -> CGFloat {
        let s = max(viewTransform.a, 0.0001)
        return px / s
    }
}
