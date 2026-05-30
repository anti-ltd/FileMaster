import AppKit
import Foundation

extension RGBAColor {
    /// Build from an `NSColor` (e.g. a SwiftUI `ColorPicker` selection), converting
    /// into sRGB so the stored components match what gets written to the file.
    init(nsColor: NSColor) {
        let c = nsColor.usingColorSpace(.sRGB) ?? nsColor
        self.init(Double(c.redComponent), Double(c.greenComponent),
                  Double(c.blueComponent), Double(c.alphaComponent))
    }
}

/// Parse / format the subset of CSS colour syntax that appears in SVG fills and
/// strokes: `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`, `rgb()/rgba()`, `none`,
/// `currentColor`, `transparent`, and the common named colours. Returns `nil` for
/// `none`/`transparent` (the model's "no paint"), so callers map nil → `fill="none"`.
enum SVGColor {

    /// Parse a paint value. Returns nil for "none"/"transparent" (no paint).
    static func parse(_ raw: String) -> RGBAColor?? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.isEmpty { return .some(nil) }       // treated as inherit-default by caller
        if s == "none" || s == "transparent" { return .some(nil) }
        if s == "currentcolor" { return .some(.black) }

        if s.hasPrefix("#") { return hex(String(s.dropFirst())).map { .some($0) } }
        if s.hasPrefix("rgb") { return rgbFunc(s).map { .some($0) } }
        if let named = named[s] { return .some(named) }
        return nil                                // unrecognised → caller keeps default
    }

    /// Format as `#rrggbb` (plus `fill-opacity` handled separately by the serializer
    /// when alpha < 1, so we keep the hex compact).
    static func hexString(_ c: RGBAColor) -> String {
        func ch(_ v: Double) -> String { String(format: "%02x", Int((v * 255).rounded())) }
        return "#\(ch(c.r))\(ch(c.g))\(ch(c.b))"
    }

    // MARK: - Helpers

    private static func hex(_ h: String) -> RGBAColor? {
        let chars = Array(h)
        func v(_ i: Int) -> Double? {
            guard i < chars.count, let n = Int(String(chars[i]), radix: 16) else { return nil }
            return Double(n) / 15
        }
        func v2(_ i: Int) -> Double? {
            guard i + 1 < chars.count, let n = Int(String(chars[i...i+1]), radix: 16) else { return nil }
            return Double(n) / 255
        }
        switch chars.count {
        case 3:
            guard let r = v(0), let g = v(1), let b = v(2) else { return nil }
            return RGBAColor(r, g, b, 1)
        case 4:
            guard let r = v(0), let g = v(1), let b = v(2), let a = v(3) else { return nil }
            return RGBAColor(r, g, b, a)
        case 6:
            guard let r = v2(0), let g = v2(2), let b = v2(4) else { return nil }
            return RGBAColor(r, g, b, 1)
        case 8:
            guard let r = v2(0), let g = v2(2), let b = v2(4), let a = v2(6) else { return nil }
            return RGBAColor(r, g, b, a)
        default:
            return nil
        }
    }

    private static func rgbFunc(_ s: String) -> RGBAColor? {
        guard let open = s.firstIndex(of: "("), let close = s.firstIndex(of: ")") else { return nil }
        let inner = s[s.index(after: open)..<close]
        let parts = inner.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard parts.count >= 3 else { return nil }
        func comp(_ str: String) -> Double {
            if str.hasSuffix("%") { return (Double(str.dropLast()) ?? 0) / 100 }
            return (Double(str) ?? 0) / 255
        }
        let r = comp(parts[0]), g = comp(parts[1]), b = comp(parts[2])
        let a = parts.count >= 4 ? (Double(parts[3]) ?? 1) : 1
        return RGBAColor(r, g, b, a)
    }

    private static let named: [String: RGBAColor] = [
        "black": .black, "white": .white, "red": RGBAColor(1, 0, 0),
        "green": RGBAColor(0, 0.5, 0), "lime": RGBAColor(0, 1, 0),
        "blue": RGBAColor(0, 0, 1), "yellow": RGBAColor(1, 1, 0),
        "cyan": RGBAColor(0, 1, 1), "aqua": RGBAColor(0, 1, 1),
        "magenta": RGBAColor(1, 0, 1), "fuchsia": RGBAColor(1, 0, 1),
        "gray": RGBAColor(0.5, 0.5, 0.5), "grey": RGBAColor(0.5, 0.5, 0.5),
        "silver": RGBAColor(0.75, 0.75, 0.75), "maroon": RGBAColor(0.5, 0, 0),
        "olive": RGBAColor(0.5, 0.5, 0), "navy": RGBAColor(0, 0, 0.5),
        "purple": RGBAColor(0.5, 0, 0.5), "teal": RGBAColor(0, 0.5, 0.5),
        "orange": RGBAColor(1, 0.65, 0),
    ]
}
