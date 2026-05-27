import SwiftUI
import AppKit

/// The image editor's **viewer pane** — the middle pane in the den's edit layout.
/// It's primarily for *seeing* the image: a header (with undo/redo/reset/close),
/// capsule tool tabs, and the live GPU-rendered canvas carrying the spatial crop
/// and markup overlays. The per-tool knobs live in `ImageEditorControlsPane`, the
/// third pane to the right (see `ShelfView.editSplitView`).
struct ImageEditorView: View {
    @ObservedObject var model: ImageEditModel
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
            Image(systemName: "wand.and.stars").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.url.lastPathComponent)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                Text(statusLine)
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if model.isRendering || model.isExporting {
                ProgressView().controlSize(.small)
            }
            iconButton("arrow.uturn.backward", help: "Undo", enabled: model.canUndo) { model.undo() }
            iconButton("arrow.uturn.forward", help: "Redo", enabled: model.canRedo) { model.redo() }
            iconButton("arrow.counterclockwise", help: "Reset all edits",
                       enabled: !model.state.isPristine) { model.reset() }
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
        let p = model.sourcePixelSize
        return "\(Int(p.width))×\(Int(p.height)) · on-device"
    }

    // MARK: - Canvas

    private var canvas: some View {
        GeometryReader { geo in
            let fit = FitRect.make(aspect: model.previewAspect, in: geo.size)
            ZStack {
                Checkerboard()
                    .frame(width: fit.width, height: fit.height)
                    .position(x: fit.midX, y: fit.midY)
                    .opacity(model.state.removeBackground ? 1 : 0)

                if let cg = model.preview {
                    Image(decorative: cg, scale: 1, orientation: .up)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: fit.width, height: fit.height)
                        .position(x: fit.midX, y: fit.midY)
                        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                }

                // Live vector annotations (redactions are baked into the preview).
                AnnotationOverlay(annotations: model.state.annotations, imageRect: fit)

                if model.activeTool == .crop {
                    CropOverlay(model: model, imageRect: fit)
                } else if model.activeTool == .markup {
                    MarkupCanvas(model: model, imageRect: fit)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .onAppear { model.setPreviewBudget(max(geo.size.width, geo.size.height)) }
            .onChange(of: geo.size) { _, s in model.setPreviewBudget(max(s.width, s.height)) }
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

// MARK: - Canvas geometry

/// Aspect-fit a rect of the given width/height ratio inside `size`, centred.
enum FitRect {
    static func make(aspect: CGFloat, in size: CGSize) -> CGRect {
        guard aspect > 0, size.width > 0, size.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let containerAspect = size.width / size.height
        var w = size.width, h = size.height
        if aspect > containerAspect { h = w / aspect } else { w = h * aspect }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }
}

/// Map a normalised point/rect (0…1, top-left origin) to/from a view-space rect.
extension CGRect {
    func denorm(_ p: CGPoint) -> CGPoint {
        CGPoint(x: minX + p.x * width, y: minY + p.y * height)
    }
    func norm(_ p: CGPoint) -> CGPoint {
        CGPoint(x: ((p.x - minX) / width).clamped01, y: ((p.y - minY) / height).clamped01)
    }
    func denorm(_ r: CGRect) -> CGRect {
        CGRect(x: minX + r.minX * width, y: minY + r.minY * height,
               width: r.width * width, height: r.height * height)
    }
}

extension CGFloat { var clamped01: CGFloat { Swift.min(1, Swift.max(0, self)) } }

// MARK: - Checkerboard (transparency backdrop)

/// The familiar grey checkerboard shown behind transparent pixels (after
/// background removal) so the cut-out is legible.
struct Checkerboard: View {
    var square: CGFloat = 10
    var body: some View {
        Canvas { ctx, size in
            let cols = Int(size.width / square) + 1
            let rows = Int(size.height / square) + 1
            for row in 0..<rows {
                for col in 0..<cols where (row + col) % 2 == 0 {
                    let rect = CGRect(x: CGFloat(col) * square, y: CGFloat(row) * square,
                                      width: square, height: square)
                    ctx.fill(Path(rect), with: .color(.gray.opacity(0.28)))
                }
            }
        }
        .background(Color(white: 0.92))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Annotation overlay (live vector preview)

/// Draws the committed non-redaction annotations over the canvas using SwiftUI's
/// `Canvas`, so they stay crisp and interactive without a GPU re-render.
struct AnnotationOverlay: View {
    let annotations: [Annotation]
    let imageRect: CGRect

    var body: some View {
        Canvas { ctx, _ in
            for a in annotations where !a.isRedaction {
                AnnotationDraw.draw(a, in: &ctx, imageRect: imageRect)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Shared SwiftUI-`Canvas` drawing for annotations — used by both the committed
/// overlay and the in-progress markup preview so they look identical.
enum AnnotationDraw {
    static func draw(_ a: Annotation, in ctx: inout GraphicsContext, imageRect: CGRect) {
        let longest = max(imageRect.width, imageRect.height)
        let lineWidth = max(a.width * longest, 1)
        let color = Color(a.color.nsColor)
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        func p(_ n: CGPoint) -> CGPoint { imageRect.denorm(n) }
        func r(_ n: CGRect) -> CGRect { imageRect.denorm(n) }

        switch a.kind {
        case .freehand(let pts):
            guard pts.count > 1 else { return }
            var path = Path()
            path.move(to: p(pts[0]))
            for pt in pts.dropFirst() { path.addLine(to: p(pt)) }
            ctx.stroke(path, with: .color(color), style: style)

        case .line(let from, let to):
            var path = Path(); path.move(to: p(from)); path.addLine(to: p(to))
            ctx.stroke(path, with: .color(color), style: style)

        case .arrow(let from, let to):
            drawArrow(from: p(from), to: p(to), lineWidth: lineWidth, color: color, in: &ctx)

        case .rect(let rect):
            ctx.stroke(Path(r(rect)), with: .color(color), style: style)

        case .ellipse(let rect):
            ctx.stroke(Path(ellipseIn: r(rect)), with: .color(color), style: style)

        case .highlight(let rect):
            ctx.fill(Path(r(rect)), with: .color(color.opacity(0.35)))

        case .text(let string, let at, let fontFraction):
            let resolved = ctx.resolve(Text(string)
                .font(.system(size: max(fontFraction * longest, 6), weight: .semibold))
                .foregroundColor(color))
            ctx.draw(resolved, at: p(at), anchor: .topLeading)

        case .redactBlackout, .redactPixelate:
            break
        }
    }

    private static func drawArrow(from: CGPoint, to: CGPoint, lineWidth: CGFloat,
                                  color: Color, in ctx: inout GraphicsContext) {
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        var shaft = Path(); shaft.move(to: from); shaft.addLine(to: to)
        ctx.stroke(shaft, with: .color(color), style: style)
        let angle = atan2(to.y - from.y, to.x - from.x)
        let head = max(lineWidth * 4, 8)
        let wing = CGFloat.pi / 7
        var headPath = Path()
        headPath.move(to: to)
        headPath.addLine(to: CGPoint(x: to.x - head * cos(angle - wing), y: to.y - head * sin(angle - wing)))
        headPath.move(to: to)
        headPath.addLine(to: CGPoint(x: to.x - head * cos(angle + wing), y: to.y - head * sin(angle + wing)))
        ctx.stroke(headPath, with: .color(color), style: style)
    }
}
