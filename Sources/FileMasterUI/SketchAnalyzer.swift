import AppKit
import Vision

/// Dimensions extracted from a hand-drawn sketch.
struct SketchInfo {
    /// largest extracted dimension → width (side to side)
    var widthCm:  Double
    /// middle extracted dimension → height (vertical)
    var heightCm: Double
    /// smallest extracted dimension → depth (front to back)
    var depthCm:  Double

    var dimensionLabel: String {
        "W \(fmt(widthCm)) × H \(fmt(heightCm)) × D \(fmt(depthCm)) cm"
    }

    private func fmt(_ v: Double) -> String {
        v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", v)
    }
}

/// Extracts dimensions from a hand-drawn sketch using on-device Vision OCR only.
/// No AI, no network — just text recognition and unit parsing.
enum SketchAnalyzer {

    static func analyze(_ image: CGImage) -> SketchInfo {
        // Try original orientation and 90°-rotated to catch text written at angles.
        var dims = recognizeDimensions(in: image)
        if let rotated = rotate90(image) {
            dims = merge(dims, recognizeDimensions(in: rotated))
        }
        return makeInfo(from: dims.sorted())
    }

    // MARK: - OCR

    private static func recognizeDimensions(in image: CGImage) -> [Double] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel       = .accurate
        req.usesLanguageCorrection = false
        req.recognitionLanguages   = ["en-US"]
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([req])

        let lines = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }

        // Pass 1 — strict: require an explicit unit suffix (60cm, 1.2m, …)
        let strict = lines.flatMap { parseLine($0, requireUnit: true) }
        if strict.count >= 2 { return strict }

        // Pass 2 — permissive: also accept bare numbers in the furniture range
        return lines.flatMap { parseLine($0, requireUnit: false) }
    }

    private static func parseLine(_ line: String, requireUnit: Bool) -> [Double] {
        let pattern = requireUnit
            ? #"(\d+(?:[.,]\d+)?)\s*(cm|mm|m\b|in|ft|"|')"#
            : #"(\d+(?:[.,]\d+)?)\s*(cm|mm|m\b|in|ft|"|')?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return []
        }
        var out: [Double] = []
        for m in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
            guard let nr = Range(m.range(at: 1), in: line),
                  var v = Double(String(line[nr]).replacingOccurrences(of: ",", with: "."))
            else { continue }

            var unit = "cm"
            if m.numberOfRanges > 2, let ur = Range(m.range(at: 2), in: line), !ur.isEmpty {
                unit = String(line[ur]).lowercased()
            } else if requireUnit { continue }

            switch unit {
            case "mm":       v /= 10
            case "m":        v *= 100
            case "in", "\"": v *= 2.54
            case "ft", "'":  v *= 30.48
            default: break
            }
            if v >= 20 && v <= 500 { out.append(v) }
        }
        return out
    }

    // MARK: - Dimension assignment (no shape inference)

    /// Assigns sorted dims to W/H/D with no furniture categorisation:
    /// largest → width, middle → height, smallest → depth.
    /// This lets proportions speak for themselves regardless of object type.
    private static func makeInfo(from s: [Double]) -> SketchInfo {
        switch s.count {
        case 0:
            return SketchInfo(widthCm: 80, heightCm: 75, depthCm: 60)
        case 1:
            let v = s[0]
            return SketchInfo(widthCm: v, heightCm: v * 0.9, depthCm: v * 0.7)
        case 2:
            return SketchInfo(widthCm: s[1], heightCm: s[1] * 0.85, depthCm: s[0])
        default:
            return SketchInfo(widthCm: s[2], heightCm: s[1], depthCm: s[0])
        }
    }

    // MARK: - Helpers

    private static func merge(_ a: [Double], _ b: [Double]) -> [Double] {
        var r = a
        for v in b where !r.contains(where: { abs($0 - v) < 2.0 }) { r.append(v) }
        return r
    }

    private static func rotate90(_ image: CGImage) -> CGImage? {
        let w = image.height, h = image.width
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: image.bitsPerComponent,
                                  bytesPerRow: 0,
                                  space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: image.bitmapInfo.rawValue) else { return nil }
        ctx.translateBy(x: CGFloat(w), y: 0)
        ctx.rotate(by: .pi / 2)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }
}
