import CoreGraphics
import Foundation

/// The bridge between an `SVGDocument` (user space) and the on-screen canvas.
/// Builds `CGPath`s for drawing, maps user space ⇄ the fitted view rect (reusing
/// `FitRect` from the raster editor), and hit-tests shapes and path nodes. Pure
/// geometry — no drawing, no SwiftUI — so it's shared by the canvas, the selection
/// overlay, and the node overlay.
enum SVGGeometry {

    /// Affine mapping document user space → the fitted view rect. Aspect is already
    /// preserved by `FitRect`, so x/y scales match.
    static func viewTransform(viewBox vb: CGRect, fit: CGRect) -> CGAffineTransform {
        let sx = fit.width / max(vb.width, 0.0001)
        let sy = fit.height / max(vb.height, 0.0001)
        var t = CGAffineTransform.identity
        t = t.translatedBy(x: fit.minX, y: fit.minY)
        t = t.scaledBy(x: sx, y: sy)
        t = t.translatedBy(x: -vb.minX, y: -vb.minY)
        return t
    }

    // MARK: - Paths

    /// The element's path in user space with its own transform applied — ready to
    /// stroke/fill after composing the view transform.
    static func cgPath(for el: SVGElement) -> CGPath {
        let local = localPath(el.geometry)
        if el.transform.isIdentity { return local }
        var t = el.transform.cg
        return local.copy(using: &t) ?? local
    }

    /// Untransformed geometry path (local/object space).
    static func localPath(_ g: SVGElement.Geometry) -> CGPath {
        let path = CGMutablePath()
        switch g {
        case .path(let data):
            for sp in data.subpaths { append(sp, to: path) }
        case .rect(let r, let rx, let ry):
            if rx > 0 || ry > 0 {
                path.addRoundedRect(in: r, cornerWidth: max(rx, ry), cornerHeight: max(rx, ry))
            } else {
                path.addRect(r)
            }
        case .circle(let c, let r):
            path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        case .ellipse(let c, let rx, let ry):
            path.addEllipse(in: CGRect(x: c.x - rx, y: c.y - ry, width: 2 * rx, height: 2 * ry))
        case .line(let p0, let p1):
            path.move(to: p0); path.addLine(to: p1)
        case .polygon(let pts, let closed):
            guard let first = pts.first else { break }
            path.move(to: first)
            for p in pts.dropFirst() { path.addLine(to: p) }
            if closed { path.closeSubpath() }
        case .group(let children):
            for child in children { path.addPath(cgPath(for: child)) }
        }
        return path
    }

    private static func append(_ sp: PathData.Subpath, to path: CGMutablePath) {
        guard let first = sp.nodes.first else { return }
        path.move(to: first.anchor)
        for i in 1..<max(sp.nodes.count, 1) {
            curve(from: sp.nodes[i - 1], to: sp.nodes[i], in: path)
        }
        if sp.closed {
            if let last = sp.nodes.last, last.controlOut != nil || sp.nodes[0].controlIn != nil {
                curve(from: last, to: sp.nodes[0], in: path)
            }
            path.closeSubpath()
        }
    }

    private static func curve(from a: PathNode, to b: PathNode, in path: CGMutablePath) {
        if a.controlOut == nil && b.controlIn == nil {
            path.addLine(to: b.anchor)
        } else {
            path.addCurve(to: b.anchor, control1: a.controlOut ?? a.anchor,
                          control2: b.controlIn ?? b.anchor)
        }
    }

    // MARK: - Bounds

    /// User-space bounding box of the element's geometry (transform applied).
    static func bounds(of el: SVGElement) -> CGRect {
        let b = cgPath(for: el).boundingBoxOfPath
        return b.isNull ? .zero : b
    }

    // MARK: - Hit testing (all points in user space)

    /// Topmost element under `p`, searching front-to-back. Filled shapes test
    /// containment; thin/open shapes test a tolerance-stroked outline.
    static func hitTest(_ p: CGPoint, in doc: SVGDocument, tolerance: CGFloat) -> UUID? {
        for el in doc.elements.reversed() {
            let path = cgPath(for: el)
            if el.style.fill != nil, path.contains(p, using: el.style.fillRule == .evenodd ? .evenOdd : .winding) {
                return el.id
            }
            let stroked = path.copy(strokingWithWidth: max(el.style.strokeWidth, tolerance * 2),
                                    lineCap: .round, lineJoin: .round, miterLimit: 10)
            if stroked.contains(p) { return el.id }
        }
        return nil
    }

    /// Which node/handle of a selected path lies nearest `p` within `tolerance`.
    /// `transform` is the element's affine (handles are stored pre-transform).
    static func hitTestNode(_ p: CGPoint, path: PathData, transform: CGAffineTransform,
                            tolerance: CGFloat) -> NodeHit? {
        var best: (hit: NodeHit, dist: CGFloat)?
        func consider(_ pt: CGPoint?, _ hit: NodeHit) {
            guard let pt else { return }
            let tp = pt.applying(transform)
            let d = hypot(tp.x - p.x, tp.y - p.y)
            if d <= tolerance, best == nil || d < best!.dist { best = (hit, d) }
        }
        for (si, sp) in path.subpaths.enumerated() {
            for (ni, node) in sp.nodes.enumerated() {
                // Prefer handles over anchors when overlapping (they sit on top).
                consider(node.controlIn, .controlIn(sub: si, idx: ni))
                consider(node.controlOut, .controlOut(sub: si, idx: ni))
                consider(node.anchor, .anchor(sub: si, idx: ni))
            }
        }
        return best?.hit
    }

    enum NodeHit: Equatable {
        case anchor(sub: Int, idx: Int)
        case controlIn(sub: Int, idx: Int)
        case controlOut(sub: Int, idx: Int)
    }
}
