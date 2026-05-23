import SwiftUI
import AppKit

// MARK: - Crop overlay

/// Interactive crop frame drawn over the (uncropped) canvas: a dimmed exterior, a
/// rule-of-thirds grid, draggable corners, and a movable body. Writes the result
/// back to `model.state.cropRect` in normalised, top-left coordinates.
struct CropOverlay: View {
    @ObservedObject var model: ImageEditModel
    let imageRect: CGRect

    @State private var interacting = false

    private enum Corner { case tl, tr, bl, br }
    private let minSize: CGFloat = 0.06
    private let handle: CGFloat = 22

    private var rect: CGRect { model.state.cropRect ?? CGRect(x: 0, y: 0, width: 1, height: 1) }
    private var viewRect: CGRect { imageRect.denorm(rect) }

    var body: some View {
        ZStack {
            // Dimmed exterior with a hole over the crop.
            Canvas { ctx, _ in
                var path = Path(imageRect)
                path.addRect(viewRect)
                ctx.fill(path, with: .color(.black.opacity(0.45)), style: FillStyle(eoFill: true))
            }
            .allowsHitTesting(false)

            grid

            Rectangle()
                .strokeBorder(Color.white.opacity(0.95), lineWidth: 1.5)
                .frame(width: viewRect.width, height: viewRect.height)
                .position(x: viewRect.midX, y: viewRect.midY)
                .contentShape(Rectangle())
                .gesture(moveGesture)

            corner(.tl, at: CGPoint(x: viewRect.minX, y: viewRect.minY))
            corner(.tr, at: CGPoint(x: viewRect.maxX, y: viewRect.minY))
            corner(.bl, at: CGPoint(x: viewRect.minX, y: viewRect.maxY))
            corner(.br, at: CGPoint(x: viewRect.maxX, y: viewRect.maxY))
        }
    }

    private var grid: some View {
        Path { p in
            for i in 1...2 {
                let x = viewRect.minX + viewRect.width * CGFloat(i) / 3
                p.move(to: CGPoint(x: x, y: viewRect.minY)); p.addLine(to: CGPoint(x: x, y: viewRect.maxY))
                let y = viewRect.minY + viewRect.height * CGFloat(i) / 3
                p.move(to: CGPoint(x: viewRect.minX, y: y)); p.addLine(to: CGPoint(x: viewRect.maxX, y: y))
            }
        }
        .stroke(Color.white.opacity(0.4), lineWidth: 0.5)
        .allowsHitTesting(false)
    }

    private func corner(_ which: Corner, at point: CGPoint) -> some View {
        Circle()
            .fill(Color.white)
            .frame(width: 12, height: 12)
            .shadow(color: .black.opacity(0.4), radius: 2)
            .frame(width: handle, height: handle)        // larger hit area
            .contentShape(Rectangle())
            .position(point)
            .gesture(cornerGesture(which))
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                beginIfNeeded()
                let dx = value.translation.width / imageRect.width
                let dy = value.translation.height / imageRect.height
                var r = startRect ?? rect
                r.origin.x = (r.minX + dx).clampedTo(0, 1 - r.width)
                r.origin.y = (r.minY + dy).clampedTo(0, 1 - r.height)
                model.state.cropRect = r
            }
            .onEnded { _ in endInteraction() }
    }

    private func cornerGesture(_ which: Corner) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                beginIfNeeded()
                let n = imageRect.norm(value.location)
                var r = rect
                switch which {
                case .tl: r = CGRect(x: n.x, y: n.y, width: r.maxX - n.x, height: r.maxY - n.y)
                case .tr: r = CGRect(x: r.minX, y: n.y, width: n.x - r.minX, height: r.maxY - n.y)
                case .bl: r = CGRect(x: n.x, y: r.minY, width: r.maxX - n.x, height: n.y - r.minY)
                case .br: r = CGRect(x: r.minX, y: r.minY, width: n.x - r.minX, height: n.y - r.minY)
                }
                model.state.cropRect = clampMin(r)
            }
            .onEnded { _ in endInteraction() }
    }

    // Track the rect at gesture start so a move doesn't accumulate rounding drift.
    @State private var startRect: CGRect?

    private func beginIfNeeded() {
        guard !interacting else { return }
        interacting = true
        startRect = rect
        model.beginInteraction()
    }

    private func endInteraction() {
        interacting = false
        startRect = nil
        model.endInteraction()
    }

    /// Keep the crop at least `minSize` on each axis and inside the frame.
    private func clampMin(_ r: CGRect) -> CGRect {
        var rect = r
        if rect.width < minSize {
            rect.size.width = minSize
            rect.origin.x = min(rect.origin.x, 1 - minSize)
        }
        if rect.height < minSize {
            rect.size.height = minSize
            rect.origin.y = min(rect.origin.y, 1 - minSize)
        }
        rect.origin.x = rect.origin.x.clampedTo(0, 1 - rect.width)
        rect.origin.y = rect.origin.y.clampedTo(0, 1 - rect.height)
        return rect
    }
}

// MARK: - Markup canvas

/// Captures pointer input over the canvas to create annotations with the active
/// markup tool, showing a live preview of the in-progress shape and committing it
/// (one undo step) on release. Text is placed via a prompt on tap.
struct MarkupCanvas: View {
    @ObservedObject var model: ImageEditModel
    let imageRect: CGRect

    @State private var start: CGPoint?        // normalised
    @State private var current: CGPoint?      // normalised
    @State private var points: [CGPoint] = [] // normalised, freehand

    var body: some View {
        ZStack {
            Color.clear.contentShape(Rectangle())
            if let preview = inProgress {
                Canvas { ctx, _ in
                    var c = ctx
                    AnnotationDraw.draw(preview, in: &c, imageRect: imageRect)
                }
                .allowsHitTesting(false)
            }
        }
        .gesture(drag)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let n = imageRect.norm(value.location)
                if start == nil { start = imageRect.norm(value.startLocation) }
                current = n
                if model.markupTool == .pen { points.append(n) }
            }
            .onEnded { value in
                defer { start = nil; current = nil; points = [] }
                let s = start ?? imageRect.norm(value.startLocation)
                let e = imageRect.norm(value.location)
                let dragged = hypot(e.x - s.x, e.y - s.y) > 0.01

                if model.markupTool == .text {
                    placeText(at: dragged ? e : s)
                    return
                }
                guard let annotation = build(start: s, end: e, dragged: dragged) else { return }
                model.addAnnotation(annotation)
            }
    }

    /// The shape being drawn right now, for the live preview layer.
    private var inProgress: Annotation? {
        guard let s = start, let c = current else { return nil }
        if model.markupTool == .pen {
            return points.count > 1 ? annotation(.freehand(points)) : nil
        }
        return build(start: s, end: c, dragged: true)
    }

    private func build(start s: CGPoint, end e: CGPoint, dragged: Bool) -> Annotation? {
        let rect = CGRect(x: min(s.x, e.x), y: min(s.y, e.y),
                          width: abs(e.x - s.x), height: abs(e.y - s.y))
        switch model.markupTool {
        case .pen:       return points.count > 1 ? annotation(.freehand(points)) : nil
        case .line:      return dragged ? annotation(.line(s, e)) : nil
        case .arrow:     return dragged ? annotation(.arrow(s, e)) : nil
        case .rect:      return dragged ? annotation(.rect(rect)) : nil
        case .ellipse:   return dragged ? annotation(.ellipse(rect)) : nil
        case .highlight: return dragged ? annotation(.highlight(rect)) : nil
        case .blackout:  return dragged ? annotation(.redactBlackout(rect)) : nil
        case .pixelate:  return dragged ? annotation(.redactPixelate(rect)) : nil
        case .text:      return nil
        }
    }

    private func placeText(at point: CGPoint) {
        guard let string = promptForText(title: "Add Text",
                                         message: "This text is drawn onto the image.",
                                         defaultValue: "", confirm: "Add"),
              !string.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        model.addAnnotation(annotation(.text(string, point, max(model.markupWidth * 6, 0.03))))
    }

    private func annotation(_ kind: Annotation.Kind) -> Annotation {
        Annotation(kind: kind,
                   color: model.markupColor,
                   width: model.markupWidth)
    }
}

extension CGFloat {
    func clampedTo(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat { Swift.min(hi, Swift.max(lo, self)) }
}
