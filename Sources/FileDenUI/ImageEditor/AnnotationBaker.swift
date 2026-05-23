import AppKit
import CoreGraphics
import CoreText

/// Draws the vector annotations onto a rendered bitmap at export time. The live
/// editor draws the same shapes in SwiftUI for interactivity; this is the
/// permanent, resolution-independent bake. Redactions are *not* handled here —
/// those are burned into the pixels by the CI pipeline so they can't be peeled
/// back off the exported file.
enum AnnotationBaker {

    /// Return a new CGImage with every non-redaction annotation painted on top.
    /// No-op (returns the input) when there's nothing to draw.
    static func bake(_ annotations: [Annotation], onto image: CGImage) -> CGImage {
        let drawable = annotations.filter { !$0.isRedaction }
        guard !drawable.isEmpty else { return image }

        let w = image.width, h = image.height
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }

        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Annotations are normalised top-left; flip into CG's bottom-left space.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        let size = CGSize(width: w, height: h)
        for a in drawable { draw(a, in: ctx, size: size) }
        return ctx.makeImage() ?? image
    }

    private static func draw(_ a: Annotation, in ctx: CGContext, size: CGSize) {
        let longest = max(size.width, size.height)
        let lineWidth = max(a.width * longest, 1)
        let color = a.color.nsColor.cgColor
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineWidth(lineWidth)

        func p(_ n: CGPoint) -> CGPoint { CGPoint(x: n.x * size.width, y: n.y * size.height) }
        func r(_ n: CGRect) -> CGRect {
            CGRect(x: n.minX * size.width, y: n.minY * size.height,
                   width: n.width * size.width, height: n.height * size.height)
        }

        switch a.kind {
        case .freehand(let pts):
            guard pts.count > 1 else { return }
            ctx.beginPath()
            ctx.move(to: p(pts[0]))
            for pt in pts.dropFirst() { ctx.addLine(to: p(pt)) }
            ctx.strokePath()

        case .line(let from, let to):
            ctx.beginPath(); ctx.move(to: p(from)); ctx.addLine(to: p(to)); ctx.strokePath()

        case .arrow(let from, let to):
            drawArrow(from: p(from), to: p(to), lineWidth: lineWidth, in: ctx)

        case .rect(let rect):
            ctx.stroke(r(rect))

        case .ellipse(let rect):
            ctx.strokeEllipse(in: r(rect))

        case .highlight(let rect):
            ctx.setFillColor(a.color.nsColor.withAlphaComponent(0.35).cgColor)
            ctx.fill(r(rect))

        case .text(let string, let at, let fontFraction):
            drawText(string, at: p(at), fontSize: max(fontFraction * longest, 6),
                     color: a.color.nsColor, in: ctx, size: size)

        case .redactBlackout, .redactPixelate:
            break   // handled in the CI pipeline
        }
    }

    private static func drawArrow(from: CGPoint, to: CGPoint, lineWidth: CGFloat, in ctx: CGContext) {
        ctx.beginPath(); ctx.move(to: from); ctx.addLine(to: to); ctx.strokePath()
        let angle = atan2(to.y - from.y, to.x - from.x)
        let head = max(lineWidth * 4, 8)
        let wing = CGFloat.pi / 7
        let p1 = CGPoint(x: to.x - head * cos(angle - wing), y: to.y - head * sin(angle - wing))
        let p2 = CGPoint(x: to.x - head * cos(angle + wing), y: to.y - head * sin(angle + wing))
        ctx.beginPath()
        ctx.move(to: to); ctx.addLine(to: p1)
        ctx.move(to: to); ctx.addLine(to: p2)
        ctx.strokePath()
    }

    private static func drawText(_ string: String, at: CGPoint, fontSize: CGFloat,
                                 color: NSColor, in ctx: CGContext, size: CGSize) {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let attributed = NSAttributedString(string: string, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed)
        // The context is y-down (top-left origin); `at` is the text box's top-left,
        // so the baseline sits `ascent` *below* it (larger y). The counter-flip in
        // the text matrix keeps the glyphs upright.
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: at.x, y: at.y + font.ascender)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
