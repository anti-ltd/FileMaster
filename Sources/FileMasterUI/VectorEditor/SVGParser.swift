import CoreGraphics
import Foundation

/// Reads `.svg` text into an editable `SVGDocument` using Foundation's SAX
/// `XMLParser` — on-device, dependency-free, already linked. Shape elements become
/// `SVGElement`s in document order (z-order). `<g>` groups are **flattened**: their
/// transform composes onto each child and their presentation attributes inherit
/// down, so the editor works with one flat, hit-testable list. Unsupported elements
/// (text, gradients, `<use>`, `<image>`, …) are counted and dropped.
enum SVGParser {

    static func parse(_ text: String) -> SVGDocument? {
        guard let data = text.data(using: .utf8) else { return nil }
        let parser = XMLParser(data: data)
        let delegate = Delegate()
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        guard let viewBox = delegate.resolvedViewBox else { return nil }
        return SVGDocument(viewBox: viewBox,
                           width: delegate.declaredWidth,
                           height: delegate.declaredHeight,
                           elements: delegate.elements,
                           unsupportedCount: delegate.unsupportedCount)
    }

    static func parse(contentsOf url: URL) -> SVGDocument? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(text)
    }

    /// Inherited paint/transform context, pushed per `<g>`/`<svg>`.
    private struct Context {
        var transform: CGAffineTransform
        var fill: RGBAColor?
        var fillSet: Bool
        var stroke: RGBAColor?
        var strokeSet: Bool
        var strokeWidth: CGFloat
        var fillRule: Style.FillRule
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var elements: [SVGElement] = []
        var unsupportedCount = 0
        var declaredWidth: CGFloat?
        var declaredHeight: CGFloat?
        private var viewBox: CGRect?
        private var stack: [Context] = [Context(transform: .identity, fill: .black,
                                                fillSet: false, stroke: nil, strokeSet: false,
                                                strokeWidth: 1, fillRule: .nonzero)]

        /// Fall back to declared width/height when no viewBox is present.
        var resolvedViewBox: CGRect? {
            if let vb = viewBox { return vb }
            if let w = declaredWidth, let h = declaredHeight { return CGRect(x: 0, y: 0, width: w, height: h) }
            return nil
        }

        private let shapeTags: Set<String> = ["path", "rect", "circle", "ellipse", "polygon", "polyline", "line"]
        private let containerTags: Set<String> = ["svg", "g"]
        private let ignorableTags: Set<String> = ["title", "desc", "metadata"]

        func parser(_ parser: XMLParser, didStartElement el: String, namespaceURI: String?,
                    qualifiedName: String?, attributes attrs: [String: String]) {
            let name = el.lowercased()

            if name == "svg" {
                if let vb = attrs["viewBox"] { viewBox = Self.parseViewBox(vb) }
                declaredWidth = attrs["width"].flatMap { Self.length($0) }
                declaredHeight = attrs["height"].flatMap { Self.length($0) }
            }

            if containerTags.contains(name) {
                stack.append(merged(parent: stack.last!, attrs: attrs))
                return
            }

            if shapeTags.contains(name) {
                let ctx = merged(parent: stack.last!, attrs: attrs)
                if let geom = Self.geometry(name: name, attrs: attrs) {
                    let style = Style(fill: ctx.fill, stroke: ctx.stroke,
                                      strokeWidth: ctx.strokeWidth,
                                      opacity: Double(attrs["opacity"] ?? "") ?? 1,
                                      fillRule: ctx.fillRule)
                    elements.append(SVGElement(svgID: attrs["id"], geometry: geom,
                                               style: style, transform: Affine(ctx.transform)))
                }
                return
            }

            if !ignorableTags.contains(name) { unsupportedCount += 1 }
        }

        func parser(_ parser: XMLParser, didEndElement el: String, namespaceURI: String?,
                    qualifiedName: String?) {
            if containerTags.contains(el.lowercased()), stack.count > 1 { stack.removeLast() }
        }

        // MARK: Style/transform inheritance

        private func merged(parent: Context, attrs: [String: String]) -> Context {
            var c = parent
            // Own transform composes onto the inherited one (child coords map through
            // the parent's transform first).
            if let t = attrs["transform"].map(Self.parseTransform) {
                c.transform = t.concatenating(parent.transform)
            }
            let inline = Self.inlineStyle(attrs["style"])
            func val(_ key: String) -> String? { inline[key] ?? attrs[key] }

            if let raw = val("fill"), let parsed = SVGColor.parse(raw) { c.fill = parsed; c.fillSet = true }
            if let raw = val("stroke"), let parsed = SVGColor.parse(raw) { c.stroke = parsed; c.strokeSet = true }
            if let raw = val("stroke-width"), let w = Self.length(raw) { c.strokeWidth = w }
            if let raw = val("fill-rule"), let r = Style.FillRule(rawValue: raw) { c.fillRule = r }
            return c
        }

        // MARK: Geometry per tag

        private static func geometry(name: String, attrs: [String: String]) -> SVGElement.Geometry? {
            func n(_ k: String) -> CGFloat { length(attrs[k] ?? "") ?? 0 }
            switch name {
            case "path":
                guard let d = attrs["d"], !d.isEmpty else { return nil }
                let data = SVGPathData.parse(d)
                return data.subpaths.isEmpty ? nil : .path(data)
            case "rect":
                return .rect(CGRect(x: n("x"), y: n("y"), width: n("width"), height: n("height")),
                             rx: n("rx"), ry: attrs["ry"] != nil ? n("ry") : n("rx"))
            case "circle":
                return .circle(center: CGPoint(x: n("cx"), y: n("cy")), r: n("r"))
            case "ellipse":
                return .ellipse(center: CGPoint(x: n("cx"), y: n("cy")), rx: n("rx"), ry: n("ry"))
            case "line":
                return .line(CGPoint(x: n("x1"), y: n("y1")), CGPoint(x: n("x2"), y: n("y2")))
            case "polygon", "polyline":
                let pts = parsePoints(attrs["points"] ?? "")
                return pts.isEmpty ? nil : .polygon(pts, closed: name == "polygon")
            default:
                return nil
            }
        }

        // MARK: Attribute scanners

        private static func parseViewBox(_ s: String) -> CGRect? {
            let v = s.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
            guard v.count == 4 else { return nil }
            return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
        }

        /// Strip a unit suffix (px/pt/…) and read the number; % is unsupported (rare
        /// in editable artwork) and returns nil.
        static func length(_ s: String) -> CGFloat? {
            let t = s.trimmingCharacters(in: .whitespaces)
            if t.hasSuffix("%") { return nil }
            let stripped = t.replacingOccurrences(of: "px", with: "")
                .replacingOccurrences(of: "pt", with: "")
                .trimmingCharacters(in: .whitespaces)
            return Double(stripped).map { CGFloat($0) }
        }

        private static func parsePoints(_ s: String) -> [CGPoint] {
            let nums = s.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" || $0 == "\t" })
                .compactMap { Double($0) }
            var pts: [CGPoint] = []
            var i = 0
            while i + 1 < nums.count { pts.append(CGPoint(x: nums[i], y: nums[i + 1])); i += 2 }
            return pts
        }

        private static func inlineStyle(_ s: String?) -> [String: String] {
            guard let s else { return [:] }
            var out: [String: String] = [:]
            for decl in s.split(separator: ";") {
                let kv = decl.split(separator: ":", maxSplits: 1)
                guard kv.count == 2 else { continue }
                out[kv[0].trimmingCharacters(in: .whitespaces)] =
                    kv[1].trimmingCharacters(in: .whitespaces)
            }
            return out
        }

        /// Parse a `transform` list (matrix/translate/scale/rotate/skewX/skewY),
        /// folding so the list reads left-to-right as SVG specifies.
        static func parseTransform(_ s: String) -> CGAffineTransform {
            var result = CGAffineTransform.identity
            var scanner = s[...]
            while let open = scanner.firstIndex(of: "(") {
                let fn = scanner[scanner.startIndex..<open]
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ,\n\t"))
                guard let close = scanner[open...].firstIndex(of: ")") else { break }
                let argStr = scanner[scanner.index(after: open)..<close]
                let args = argStr.split(whereSeparator: { $0 == " " || $0 == "," })
                    .compactMap { Double($0) }.map { CGFloat($0) }
                let t = transform(fn: fn.lowercased(), args: args)
                result = t.concatenating(result)
                scanner = scanner[scanner.index(after: close)...]
            }
            return result
        }

        private static func transform(fn: String, args a: [CGFloat]) -> CGAffineTransform {
            switch fn {
            case "matrix" where a.count == 6:
                return CGAffineTransform(a: a[0], b: a[1], c: a[2], d: a[3], tx: a[4], ty: a[5])
            case "translate":
                return CGAffineTransform(translationX: a.first ?? 0, y: a.count > 1 ? a[1] : 0)
            case "scale":
                return CGAffineTransform(scaleX: a.first ?? 1, y: a.count > 1 ? a[1] : (a.first ?? 1))
            case "rotate" where a.count >= 3:
                let ang = a[0] * .pi / 180
                return CGAffineTransform(translationX: a[1], y: a[2])
                    .rotated(by: ang)
                    .translatedBy(x: -a[1], y: -a[2])
            case "rotate":
                return CGAffineTransform(rotationAngle: (a.first ?? 0) * .pi / 180)
            case "skewx":
                return CGAffineTransform(a: 1, b: 0, c: tan((a.first ?? 0) * .pi / 180), d: 1, tx: 0, ty: 0)
            case "skewy":
                return CGAffineTransform(a: 1, b: tan((a.first ?? 0) * .pi / 180), c: 0, d: 1, tx: 0, ty: 0)
            default:
                return .identity
            }
        }
    }
}
