import CoreGraphics
import Foundation

/// The full, value-typed description of an editable SVG scene. Pure data — the
/// parser produces one, the editor snapshots it for undo/redo, and the serializer
/// turns it back into `.svg` text. This is the vector analogue of the raster
/// editor's `EditState`: deterministic in, deterministic out.
///
/// All geometry lives in **SVG user space** (the `viewBox` coordinate system,
/// top-left origin, y-down), *not* normalised — the canvas maps user space to the
/// fitted view rect at draw time (see `SVGGeometry.viewTransform`). Keeping the
/// native units means coordinates round-trip to the file byte-for-byte (modulo
/// formatting) and the on-screen "Move X/Y" steppers read sensible numbers.
struct SVGDocument: Equatable {
    /// The editing coordinate system: x, y, width, height in user space.
    var viewBox: CGRect
    /// Declared `width`/`height` attributes in px, kept only for serialization so
    /// a round-trip preserves the document's intended display size. nil → omit.
    var width: CGFloat?
    var height: CGFloat?
    /// Flat, z-ordered list (index 0 painted first). Groups carry their children.
    var elements: [SVGElement]
    /// Elements the parser saw but can't edit (text, gradients, <use>, …). Kept as
    /// a count only, surfaced in the editor so the user knows the file had more.
    var unsupportedCount: Int = 0

    var aspect: CGFloat { viewBox.width / max(viewBox.height, 1) }
}

/// One editable SVG element: a geometry, a paint style, and a local affine
/// transform applied over the geometry. Interactive move/scale/rotate live in
/// `transform` (we don't bake them into the geometry) so the readouts stay stable
/// and paths aren't re-tessellated on every drag.
struct SVGElement: Identifiable, Equatable {
    /// Editor identity — stable across edits, distinct from the SVG `id` attribute.
    let id: UUID
    /// Original `id=""` attribute, preserved on round-trip (nil if absent).
    var svgID: String?
    var geometry: Geometry
    var style: Style
    var transform: Affine

    init(id: UUID = UUID(), svgID: String? = nil,
         geometry: Geometry, style: Style = .init(), transform: Affine = .identity) {
        self.id = id; self.svgID = svgID
        self.geometry = geometry; self.style = style; self.transform = transform
    }

    /// The shape primitives the editor understands. `group` nests children whose
    /// transforms compose with this element's.
    enum Geometry: Equatable {
        case path(PathData)
        case rect(CGRect, rx: CGFloat, ry: CGFloat)
        case circle(center: CGPoint, r: CGFloat)
        case ellipse(center: CGPoint, rx: CGFloat, ry: CGFloat)
        case polygon([CGPoint], closed: Bool)   // closed → <polygon>, open → <polyline>
        case line(CGPoint, CGPoint)
        case group([SVGElement])

        var typeName: String {
            switch self {
            case .path:    return "Path"
            case .rect:    return "Rectangle"
            case .circle:  return "Circle"
            case .ellipse: return "Ellipse"
            case .polygon(_, let closed): return closed ? "Polygon" : "Polyline"
            case .line:    return "Line"
            case .group:   return "Group"
            }
        }
    }
}

/// Paint attributes. `nil` fill/stroke means "none". sRGB colours reuse the
/// raster editor's value-typed `RGBAColor` (see `ImageEditEngine.swift`) so the
/// whole document stays `Equatable`.
struct Style: Equatable {
    var fill: RGBAColor? = .black
    var stroke: RGBAColor? = nil
    var strokeWidth: CGFloat = 1
    var opacity: Double = 1
    var fillRule: FillRule = .nonzero

    enum FillRule: String, Equatable { case nonzero, evenodd }
}

/// A 2-D affine transform stored as its six components. `CGAffineTransform` is
/// `Equatable`, but storing the raw components keeps the model's equality stable
/// and serializes cleanly to `matrix(a b c d e f)`.
struct Affine: Equatable {
    var a, b, c, d, tx, ty: CGFloat

    static let identity = Affine(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    init(a: CGFloat, b: CGFloat, c: CGFloat, d: CGFloat, tx: CGFloat, ty: CGFloat) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.tx = tx; self.ty = ty
    }
    init(_ t: CGAffineTransform) { self.init(a: t.a, b: t.b, c: t.c, d: t.d, tx: t.tx, ty: t.ty) }

    var cg: CGAffineTransform { CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty) }

    var isIdentity: Bool { cg.isIdentity }
}

// MARK: - Path data

/// A parsed `<path>` as one or more subpaths. This is the node-level form the
/// editor manipulates; `SVGPathData` converts it to/from a `d` string.
struct PathData: Equatable {
    var subpaths: [Subpath]

    struct Subpath: Equatable {
        var nodes: [PathNode]
        var closed: Bool
    }
}

/// One on-curve anchor plus its optional off-curve cubic-bezier control handles,
/// stored as **absolute** points in user space. This is the canonical form: every
/// segment between consecutive nodes is a cubic (a straight line is a node with no
/// outgoing handle followed by a node with no incoming handle). Quadratics are
/// promoted to cubics and arcs flattened to cubics at parse time, so the editor
/// only ever deals with cubics.
struct PathNode: Equatable {
    var anchor: CGPoint
    var controlIn: CGPoint?
    var controlOut: CGPoint?

    init(anchor: CGPoint, controlIn: CGPoint? = nil, controlOut: CGPoint? = nil) {
        self.anchor = anchor; self.controlIn = controlIn; self.controlOut = controlOut
    }
}
