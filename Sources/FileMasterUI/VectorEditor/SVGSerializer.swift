import CoreGraphics
import Foundation

/// Turns an `SVGDocument` back into `.svg` text. Each element is emitted in its
/// native form (`<rect>`, `<circle>`, `<path>`, …) so output stays idiomatic and
/// compact; interactive transforms become `transform="matrix(...)"`, and paint
/// becomes presentation attributes (`fill`, `fill-opacity`, `stroke`, …). The
/// original `id` is preserved. This is the inverse of `SVGParser`, but since groups
/// were flattened on read, output is a flat list — still valid, just un-grouped.
enum SVGSerializer {

    static func string(_ doc: SVGDocument, decimals: Int = 3) -> String {
        let vb = doc.viewBox
        func f(_ v: CGFloat) -> String { SVGPathData.fmt(v, decimals) }

        var attrs = "xmlns=\"http://www.w3.org/2000/svg\""
        attrs += " viewBox=\"\(f(vb.minX)) \(f(vb.minY)) \(f(vb.width)) \(f(vb.height))\""
        if let w = doc.width { attrs += " width=\"\(f(w))\"" }
        if let h = doc.height { attrs += " height=\"\(f(h))\"" }

        var body = ""
        for el in doc.elements { body += "  " + element(el, decimals: decimals) + "\n" }

        return "<svg \(attrs)>\n\(body)</svg>\n"
    }

    static func data(_ doc: SVGDocument, decimals: Int = 3) -> Data {
        Data(string(doc, decimals: decimals).utf8)
    }

    // MARK: - Element

    private static func element(_ el: SVGElement, decimals: Int) -> String {
        func f(_ v: CGFloat) -> String { SVGPathData.fmt(v, decimals) }
        let (tag, geomAttrs) = geometry(el.geometry, decimals: decimals)
        var attrs = geomAttrs
        if let id = el.svgID { attrs = "id=\"\(id)\" " + attrs }
        attrs += styleAttrs(el.style)
        if !el.transform.isIdentity {
            let t = el.transform
            attrs += " transform=\"matrix(\(f(t.a)) \(f(t.b)) \(f(t.c)) \(f(t.d)) \(f(t.tx)) \(f(t.ty)))\""
        }
        return "<\(tag) \(attrs)/>"
    }

    private static func geometry(_ g: SVGElement.Geometry, decimals: Int) -> (tag: String, attrs: String) {
        func f(_ v: CGFloat) -> String { SVGPathData.fmt(v, decimals) }
        switch g {
        case .path(let data):
            return ("path", "d=\"\(SVGPathData.string(data, decimals: decimals))\"")
        case .rect(let r, let rx, let ry):
            var a = "x=\"\(f(r.minX))\" y=\"\(f(r.minY))\" width=\"\(f(r.width))\" height=\"\(f(r.height))\""
            if rx > 0 { a += " rx=\"\(f(rx))\"" }
            if ry > 0 { a += " ry=\"\(f(ry))\"" }
            return ("rect", a)
        case .circle(let c, let r):
            return ("circle", "cx=\"\(f(c.x))\" cy=\"\(f(c.y))\" r=\"\(f(r))\"")
        case .ellipse(let c, let rx, let ry):
            return ("ellipse", "cx=\"\(f(c.x))\" cy=\"\(f(c.y))\" rx=\"\(f(rx))\" ry=\"\(f(ry))\"")
        case .line(let p0, let p1):
            return ("line", "x1=\"\(f(p0.x))\" y1=\"\(f(p0.y))\" x2=\"\(f(p1.x))\" y2=\"\(f(p1.y))\"")
        case .polygon(let pts, let closed):
            let s = pts.map { "\(f($0.x)),\(f($0.y))" }.joined(separator: " ")
            return (closed ? "polygon" : "polyline", "points=\"\(s)\"")
        case .group(let children):
            // Flattened on read, so groups are rare; emit children wrapped if present.
            let inner = children.map { "    " + element($0, decimals: decimals) }.joined(separator: "\n")
            return ("g", ">\n\(inner)\n  </g")   // best-effort; not the common path
        }
    }

    // MARK: - Style

    private static func styleAttrs(_ s: Style) -> String {
        var out = ""
        out += " fill=\"" + (s.fill.map { SVGColor.hexString($0) } ?? "none") + "\""
        if let fill = s.fill, fill.a < 0.999 { out += " fill-opacity=\"\(SVGPathData.fmt(CGFloat(fill.a), 3))\"" }
        if let stroke = s.stroke {
            out += " stroke=\"\(SVGColor.hexString(stroke))\""
            out += " stroke-width=\"\(SVGPathData.fmt(s.strokeWidth, 3))\""
            if stroke.a < 0.999 { out += " stroke-opacity=\"\(SVGPathData.fmt(CGFloat(stroke.a), 3))\"" }
        }
        if s.fillRule != .nonzero { out += " fill-rule=\"\(s.fillRule.rawValue)\"" }
        if s.opacity < 0.999 { out += " opacity=\"\(SVGPathData.fmt(CGFloat(s.opacity), 3))\"" }
        return out
    }
}
