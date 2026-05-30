import CoreGraphics
import Foundation

/// Parses an SVG path `d` string into the editor's node form and serializes it
/// back. The node form is all-cubic (`PathNode` with optional bezier handles), so
/// this is where the messy parts of the grammar get normalised once:
///
///   * relative commands (`m l c …`) resolve against a running point,
///   * `H/V` become lines, `Q/T` are promoted to cubics, `A` arcs flattened to cubics,
///   * `S`/`T` reflect the previous control point,
///   * implicit command repeats (`L 1 2 3 4` → two lines) and SVG number quirks
///     (`1.5.5`, leading-dot, exponents, sign-as-separator) are handled by the scanner.
///
/// The serializer emits only absolute `M`/`L`/`C`/`Z` — the lossless minimal set —
/// so the model's all-cubic form maps straight back out.
enum SVGPathData {

    // MARK: - Parse

    static func parse(_ d: String) -> PathData {
        var sub: [PathData.Subpath] = []
        var nodes: [PathNode] = []
        var closed = false

        var cur = CGPoint.zero          // running point
        var start = CGPoint.zero        // current subpath start (for Z / relative reset)
        var lastCubicCtrl: CGPoint?     // 2nd control of previous C/S, for S reflection
        var lastQuadCtrl: CGPoint?      // control of previous Q/T, for T reflection

        var scanner = Scanner(d)

        func flushSubpath() {
            if !nodes.isEmpty { sub.append(.init(nodes: nodes, closed: closed)) }
            nodes = []; closed = false
        }

        while let cmd = scanner.command() {
            let rel = cmd.isLowercase
            switch cmd.lowercased() {
            case "m":
                // First pair is a moveto; any extra pairs are implicit linetos.
                guard let p0 = scanner.point(rel: rel, from: cur) else { break }
                flushSubpath()
                cur = p0; start = p0
                nodes.append(PathNode(anchor: cur))
                lastCubicCtrl = nil; lastQuadCtrl = nil
                while let p = scanner.point(rel: rel, from: cur) {
                    appendLine(to: p, &nodes); cur = p
                    lastCubicCtrl = nil; lastQuadCtrl = nil
                }

            case "l":
                while let p = scanner.point(rel: rel, from: cur) {
                    appendLine(to: p, &nodes); cur = p
                    lastCubicCtrl = nil; lastQuadCtrl = nil
                }

            case "h":
                while let x = scanner.number() {
                    let p = CGPoint(x: rel ? cur.x + x : x, y: cur.y)
                    appendLine(to: p, &nodes); cur = p
                    lastCubicCtrl = nil; lastQuadCtrl = nil
                }

            case "v":
                while let y = scanner.number() {
                    let p = CGPoint(x: cur.x, y: rel ? cur.y + y : y)
                    appendLine(to: p, &nodes); cur = p
                    lastCubicCtrl = nil; lastQuadCtrl = nil
                }

            case "c":
                while let c1 = scanner.point(rel: rel, from: cur),
                      let c2 = scanner.point(rel: rel, from: cur),
                      let p  = scanner.point(rel: rel, from: cur) {
                    appendCubic(c1: c1, c2: c2, to: p, &nodes)
                    cur = p; lastCubicCtrl = c2; lastQuadCtrl = nil
                }

            case "s":
                while let c2 = scanner.point(rel: rel, from: cur),
                      let p  = scanner.point(rel: rel, from: cur) {
                    let c1 = reflect(lastCubicCtrl, about: cur)
                    appendCubic(c1: c1, c2: c2, to: p, &nodes)
                    cur = p; lastCubicCtrl = c2; lastQuadCtrl = nil
                }

            case "q":
                while let qc = scanner.point(rel: rel, from: cur),
                      let p  = scanner.point(rel: rel, from: cur) {
                    let (c1, c2) = quadToCubic(from: cur, control: qc, to: p)
                    appendCubic(c1: c1, c2: c2, to: p, &nodes)
                    cur = p; lastQuadCtrl = qc; lastCubicCtrl = nil
                }

            case "t":
                while let p = scanner.point(rel: rel, from: cur) {
                    let qc = reflect(lastQuadCtrl, about: cur)
                    let (c1, c2) = quadToCubic(from: cur, control: qc, to: p)
                    appendCubic(c1: c1, c2: c2, to: p, &nodes)
                    cur = p; lastQuadCtrl = qc; lastCubicCtrl = nil
                }

            case "a":
                // rx ry xRot largeArc sweep x y
                while let rx = scanner.number(), let ry = scanner.number(),
                      let rot = scanner.number(),
                      let large = scanner.flag(), let sweep = scanner.flag(),
                      let end = scanner.point(rel: rel, from: cur) {
                    for (c1, c2, p) in arcToCubics(from: cur, rx: rx, ry: ry,
                                                   xRotDeg: rot, largeArc: large,
                                                   sweep: sweep, to: end) {
                        appendCubic(c1: c1, c2: c2, to: p, &nodes)
                        cur = p
                    }
                    lastCubicCtrl = nil; lastQuadCtrl = nil
                }

            case "z":
                closed = true
                if !nodes.isEmpty { cur = start }
                flushSubpath()
                lastCubicCtrl = nil; lastQuadCtrl = nil

            default:
                break
            }
        }
        flushSubpath()
        return PathData(subpaths: sub)
    }

    // MARK: - Serialize

    static func string(_ path: PathData, decimals: Int = 3) -> String {
        var out = ""
        func f(_ v: CGFloat) -> String { Self.fmt(v, decimals) }
        func pt(_ p: CGPoint) -> String { "\(f(p.x)) \(f(p.y))" }

        for sp in path.subpaths {
            guard let first = sp_first(sp: sp) else { continue }
            out += "M \(pt(first.anchor))"
            let n = sp.nodes.count
            for i in 1..<max(n, 1) {
                segment(from: sp.nodes[i - 1], to: sp.nodes[i], into: &out, pt: pt)
            }
            if sp.closed {
                if n > 1 {
                    // Closing segment back to the start; emit an explicit curve only
                    // if it carries handles, otherwise let Z draw the line.
                    let last = sp.nodes[n - 1], head = sp.nodes[0]
                    if last.controlOut != nil || head.controlIn != nil {
                        segment(from: last, to: head, into: &out, pt: pt)
                    }
                }
                out += " Z"
            }
            out += " "
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    private static func sp_first(sp: PathData.Subpath) -> PathNode? { sp.nodes.first }

    private static func segment(from a: PathNode, to b: PathNode,
                                into out: inout String, pt: (CGPoint) -> String) {
        if a.controlOut == nil && b.controlIn == nil {
            out += " L \(pt(b.anchor))"
        } else {
            let c1 = a.controlOut ?? a.anchor
            let c2 = b.controlIn ?? b.anchor
            out += " C \(pt(c1)) \(pt(c2)) \(pt(b.anchor))"
        }
    }

    // MARK: - Node builders

    private static func appendLine(to p: CGPoint, _ nodes: inout [PathNode]) {
        nodes.append(PathNode(anchor: p))
    }

    private static func appendCubic(c1: CGPoint, c2: CGPoint, to p: CGPoint,
                                    _ nodes: inout [PathNode]) {
        if !nodes.isEmpty { nodes[nodes.count - 1].controlOut = c1 }
        nodes.append(PathNode(anchor: p, controlIn: c2))
    }

    private static func reflect(_ ctrl: CGPoint?, about p: CGPoint) -> CGPoint {
        guard let c = ctrl else { return p }     // no previous curve → control == point
        return CGPoint(x: 2 * p.x - c.x, y: 2 * p.y - c.y)
    }

    private static func quadToCubic(from: CGPoint, control q: CGPoint,
                                    to: CGPoint) -> (CGPoint, CGPoint) {
        let c1 = CGPoint(x: from.x + 2.0 / 3.0 * (q.x - from.x),
                         y: from.y + 2.0 / 3.0 * (q.y - from.y))
        let c2 = CGPoint(x: to.x + 2.0 / 3.0 * (q.x - to.x),
                         y: to.y + 2.0 / 3.0 * (q.y - to.y))
        return (c1, c2)
    }

    // MARK: - Arc → cubic (endpoint parameterisation, per SVG impl notes)

    private static func arcToCubics(from p0: CGPoint, rx rxIn: CGFloat, ry ryIn: CGFloat,
                                    xRotDeg: CGFloat, largeArc: Bool, sweep: Bool,
                                    to p1: CGPoint) -> [(CGPoint, CGPoint, CGPoint)] {
        var rx = abs(rxIn), ry = abs(ryIn)
        if rx < 1e-9 || ry < 1e-9 || (p0 == p1) {
            // Degenerate → straight line (a line is a cubic with handles on the ends).
            return [(p0, p1, p1)]
        }
        let phi = xRotDeg * .pi / 180
        let cosP = cos(phi), sinP = sin(phi)

        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1p =  cosP * dx + sinP * dy
        let y1p = -sinP * dx + cosP * dy

        // Scale radii up if they're too small to span the chord.
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 { let s = sqrt(lambda); rx *= s; ry *= s }

        let sign: CGFloat = (largeArc != sweep) ? 1 : -1
        let num = rx*rx*ry*ry - rx*rx*y1p*y1p - ry*ry*x1p*x1p
        let den = rx*rx*y1p*y1p + ry*ry*x1p*x1p
        let co = sign * sqrt(max(0, num / den))
        let cxp =  co * rx * y1p / ry
        let cyp = -co * ry * x1p / rx

        let cx = cosP * cxp - sinP * cyp + (p0.x + p1.x) / 2
        let cy = sinP * cxp + cosP * cyp + (p0.y + p1.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let len = sqrt((ux*ux + uy*uy) * (vx*vx + vy*vy))
            var a = acos(min(1, max(-1, dot / len)))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }

        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var dTheta = angle((x1p - cxp) / rx, (y1p - cyp) / ry,
                           (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && dTheta > 0 { dTheta -= 2 * .pi }
        if sweep && dTheta < 0 { dTheta += 2 * .pi }

        // Split into segments of ≤ 90° for accurate cubic approximation.
        let segCount = max(1, Int(ceil(abs(dTheta) / (.pi / 2))))
        let delta = dTheta / CGFloat(segCount)
        let t = 4.0 / 3.0 * tan(delta / 4)

        var result: [(CGPoint, CGPoint, CGPoint)] = []
        var angleStart = theta1
        func onArc(_ a: CGFloat) -> CGPoint {
            let x = cosP * rx * cos(a) - sinP * ry * sin(a) + cx
            let y = sinP * rx * cos(a) + cosP * ry * sin(a) + cy
            return CGPoint(x: x, y: y)
        }
        func deriv(_ a: CGFloat) -> CGPoint {
            let x = -cosP * rx * sin(a) - sinP * ry * cos(a)
            let y = -sinP * rx * sin(a) + cosP * ry * cos(a)
            return CGPoint(x: x, y: y)
        }
        for _ in 0..<segCount {
            let a2 = angleStart + delta
            let s = onArc(angleStart), e = onArc(a2)
            let ds = deriv(angleStart), de = deriv(a2)
            let c1 = CGPoint(x: s.x + t * ds.x, y: s.y + t * ds.y)
            let c2 = CGPoint(x: e.x - t * de.x, y: e.y - t * de.y)
            result.append((c1, c2, e))
            angleStart = a2
        }
        return result
    }

    // MARK: - Number formatting

    static func fmt(_ v: CGFloat, _ decimals: Int) -> String {
        if v.rounded() == v { return String(Int(v)) }
        var s = String(format: "%.\(decimals)f", v)
        // Trim trailing zeros and a dangling dot.
        while s.contains("."), s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    // MARK: - Scanner

    /// A tolerant scanner over a `d` string: yields command letters and SVG-flavoured
    /// numbers, treating commas/whitespace/sign as separators.
    private struct Scanner {
        private let s: [Character]
        private var i = 0
        init(_ str: String) { s = Array(str) }

        private mutating func skipSep() {
            while i < s.count, s[i] == " " || s[i] == "," || s[i] == "\n"
                    || s[i] == "\t" || s[i] == "\r" { i += 1 }
        }

        mutating func command() -> Character? {
            skipSep()
            guard i < s.count, s[i].isLetter else { return nil }
            let c = s[i]; i += 1
            return c
        }

        mutating func number() -> CGFloat? {
            skipSep()
            guard i < s.count else { return nil }
            var j = i
            var seenDot = false, seenDigit = false
            if s[j] == "+" || s[j] == "-" { j += 1 }
            while j < s.count {
                let c = s[j]
                if c.isNumber { seenDigit = true; j += 1 }
                else if c == ".", !seenDot { seenDot = true; j += 1 }
                else if (c == "e" || c == "E"), seenDigit {
                    j += 1
                    if j < s.count, s[j] == "+" || s[j] == "-" { j += 1 }
                } else { break }
            }
            guard seenDigit, let v = Double(String(s[i..<j])) else { return nil }
            i = j
            return CGFloat(v)
        }

        /// Arc flags are a single `0`/`1` and may be packed with no separator
        /// (`...1 1 ...` or `...11...`), so read exactly one digit.
        mutating func flag() -> Bool? {
            skipSep()
            guard i < s.count else { return nil }
            let c = s[i]
            guard c == "0" || c == "1" else { return nil }
            i += 1
            return c == "1"
        }

        mutating func point(rel: Bool, from cur: CGPoint) -> CGPoint? {
            let save = i
            guard let x = number(), let y = number() else { i = save; return nil }
            return rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
        }
    }
}
