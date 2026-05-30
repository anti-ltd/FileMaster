import AppKit
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Vision

/// Traces a raster image into an editable `SVGDocument`, entirely on-device — no
/// network, no model. The pipeline mirrors how classic tracers (and the costly
/// web tools) work, using Apple's `VNDetectContoursRequest` for the heavy lifting:
///
///   1. downscale to a working budget (contours don't need full res),
///   2. quantise to a small palette (posterise → histogram → nearest-colour map),
///   3. for each palette colour, build a binary mask and detect its contours,
///   4. simplify each contour (Douglas–Peucker) and emit one `<path>` per colour,
///      with holes as extra subpaths under an even-odd fill.
///
/// Best for flat artwork — logos, icons, screenshots, illustrations. Photographs
/// produce thousands of contours and trace poorly; the panel says so.
enum RasterVectorizer {

    struct Options: Equatable {
        /// Palette size. 2 ≈ line-art/silhouette; 6 is a good default for flat art.
        var colorCount: Int = 6
        /// Contour fidelity 0…1 — higher keeps more points (less simplification).
        var detail: Double = 0.5
        /// Drop regions smaller than this fraction of the image area (de-speckle).
        var minRegionArea: Double = 0.0008
    }

    /// Longest working side. Caps cost and is plenty for clean contours.
    static let workingBudget: CGFloat = 1024

    // MARK: - Public

    /// Trace `url` and stage the resulting `.svg` into a fresh den directory. Returns
    /// the written URL, or nil on failure. File-in / file-out, like `ImageUpscale`.
    static func vectorizeToFile(_ url: URL, options: Options,
                                progress: (Double) -> Void) -> URL? {
        progress(0.05)
        guard let cg = loadDownscaled(url, budget: workingBudget) else { return nil }
        guard let doc = vectorize(cg, options: options, progress: { progress(0.05 + 0.85 * $0) }) else { return nil }
        let stem = url.deletingPathExtension().lastPathComponent
        let dest = Staging.uniqueURL(in: Staging.dir("IMG"), name: "\(stem) vectorized.svg")
        guard (try? SVGSerializer.data(doc).write(to: dest)) != nil else { return nil }
        progress(1.0)
        return dest
    }

    /// Trace a `CGImage` into a document. Exposed for tests and the live panel.
    static func vectorize(_ image: CGImage, options: Options,
                          progress: (Double) -> Void = { _ in }) -> SVGDocument? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let rgba = pixels(of: image) else { return nil }

        // Palette + per-pixel assignment (255 = transparent / unassigned).
        let palette = buildPalette(rgba: rgba, count: max(2, options.colorCount))
        guard !palette.isEmpty else { return nil }
        let assign = assignPixels(rgba: rgba, palette: palette)

        let minArea = Double(w * h) * options.minRegionArea
        // Largest coverage first, so big background regions paint under details.
        let order = palette.indices.sorted { coverage(assign, $0) > coverage(assign, $1) }

        var elements: [SVGElement] = []
        for (step, ci) in order.enumerated() {
            progress(Double(step) / Double(order.count))
            guard let mask = maskImage(assign: assign, color: UInt8(ci), width: w, height: h) else { continue }
            let paths = contours(of: mask, width: w, height: h, detail: options.detail, minArea: minArea)
            guard !paths.subpaths.isEmpty else { continue }
            elements.append(SVGElement(
                geometry: .path(paths),
                style: Style(fill: palette[ci], stroke: nil, strokeWidth: 1, opacity: 1, fillRule: .evenodd)))
        }
        progress(1.0)
        guard !elements.isEmpty else { return nil }
        return SVGDocument(viewBox: CGRect(x: 0, y: 0, width: w, height: h),
                           width: CGFloat(w), height: CGFloat(h), elements: elements)
    }

    // MARK: - Loading / pixels

    private static func loadDownscaled(_ url: URL, budget: CGFloat) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: budget,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// RGBA8 (premultiplied-last) pixel buffer for the image, row-major.
    private static func pixels(of image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buf
    }

    // MARK: - Palette

    /// Posterise to a coarse grid, histogram the buckets, take the most-populous
    /// `count`, and use each bucket's mean colour as the palette entry.
    private static func buildPalette(rgba: [UInt8], count: Int) -> [RGBAColor] {
        let levels = 6                              // per-channel quantisation buckets
        var sumR = [Int: Int](), sumG = [Int: Int](), sumB = [Int: Int](), pop = [Int: Int]()
        var i = 0
        while i < rgba.count {
            defer { i += 4 }
            if rgba[i + 3] < 128 { continue }        // skip transparent
            let r = Int(rgba[i]), g = Int(rgba[i + 1]), b = Int(rgba[i + 2])
            let key = (r * levels / 256) * levels * levels + (g * levels / 256) * levels + (b * levels / 256)
            pop[key, default: 0] += 1
            sumR[key, default: 0] += r; sumG[key, default: 0] += g; sumB[key, default: 0] += b
        }
        let top = pop.sorted { $0.value > $1.value }.prefix(count)
        return top.map { (key, n) in
            RGBAColor(Double(sumR[key]!) / Double(n) / 255,
                      Double(sumG[key]!) / Double(n) / 255,
                      Double(sumB[key]!) / Double(n) / 255, 1)
        }
    }

    /// Per-pixel nearest-palette index (255 = transparent / unassigned).
    private static func assignPixels(rgba: [UInt8], palette: [RGBAColor]) -> [UInt8] {
        let n = rgba.count / 4
        var out = [UInt8](repeating: 255, count: n)
        let pr = palette.map { $0.r * 255 }, pg = palette.map { $0.g * 255 }, pb = palette.map { $0.b * 255 }
        for p in 0..<n {
            let i = p * 4
            if rgba[i + 3] < 128 { continue }
            let r = Double(rgba[i]), g = Double(rgba[i + 1]), b = Double(rgba[i + 2])
            var best = 0, bestD = Double.greatestFiniteMagnitude
            for c in palette.indices {
                let d = (r - pr[c]) * (r - pr[c]) + (g - pg[c]) * (g - pg[c]) + (b - pb[c]) * (b - pb[c])
                if d < bestD { bestD = d; best = c }
            }
            out[p] = UInt8(best)
        }
        return out
    }

    private static func coverage(_ assign: [UInt8], _ color: Int) -> Int {
        assign.reduce(0) { $1 == UInt8(color) ? $0 + 1 : $0 }
    }

    /// Build a grayscale CGImage where the colour's region is dark (0) on white
    /// (255) — so `VNDetectContoursRequest`'s default dark-on-light tracing outlines
    /// exactly that region.
    private static func maskImage(assign: [UInt8], color: UInt8, width w: Int, height h: Int) -> CGImage? {
        var buf = [UInt8](repeating: 255, count: w * h)
        for p in 0..<(w * h) where assign[p] == color { buf[p] = 0 }
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        return ctx.makeImage()
    }

    // MARK: - Contours

    private static func contours(of mask: CGImage, width w: Int, height h: Int,
                                 detail: Double, minArea: Double) -> PathData {
        let request = VNDetectContoursRequest()
        request.contrastAdjustment = 1
        request.maximumImageDimension = Int(workingBudget)
        let handler = VNImageRequestHandler(cgImage: mask, options: [:])
        guard (try? handler.perform([request])) != nil,
              let obs = request.results?.first else { return PathData(subpaths: []) }

        // Simplification tolerance in user units; higher detail → smaller epsilon.
        let eps = max(0.5, (1 - detail) * 4)
        var subpaths: [PathData.Subpath] = []

        func emit(_ contour: VNContour) {
            let pts = contour.normalizedPoints.map {
                CGPoint(x: CGFloat($0.x) * CGFloat(w), y: (1 - CGFloat($0.y)) * CGFloat(h))
            }
            guard pts.count >= 3 else { return }
            if abs(shoelaceArea(pts)) < minArea { return }
            let simplified = douglasPeucker(pts, epsilon: eps)
            guard simplified.count >= 3 else { return }
            subpaths.append(.init(nodes: simplified.map { PathNode(anchor: $0) }, closed: true))
        }

        for top in obs.topLevelContours {
            emit(top)
            for child in top.childContours { emit(child) }   // holes
        }
        return PathData(subpaths: subpaths)
    }

    private static func shoelaceArea(_ pts: [CGPoint]) -> Double {
        guard pts.count > 2 else { return 0 }
        var a = 0.0
        for i in 0..<pts.count {
            let j = (i + 1) % pts.count
            a += Double(pts[i].x * pts[j].y - pts[j].x * pts[i].y)
        }
        return a / 2
    }

    /// Ramer–Douglas–Peucker polyline simplification.
    private static func douglasPeucker(_ pts: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard pts.count > 2 else { return pts }
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true; keep[pts.count - 1] = true
        var stack = [(0, pts.count - 1)]
        while let (s, e) = stack.popLast() {
            var maxD: CGFloat = 0, idx = -1
            for i in (s + 1)..<e {
                let d = perpDistance(pts[i], pts[s], pts[e])
                if d > maxD { maxD = d; idx = i }
            }
            if maxD > epsilon, idx != -1 {
                keep[idx] = true
                stack.append((s, idx)); stack.append((idx, e))
            }
        }
        return pts.enumerated().filter { keep[$0.offset] }.map { $0.element }
    }

    private static func perpDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        if len < 1e-6 { return hypot(p.x - a.x, p.y - a.y) }
        return abs(dy * p.x - dx * p.y + b.x * a.y - b.y * a.x) / len
    }
}
