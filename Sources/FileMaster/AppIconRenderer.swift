import AppKit
import SwiftUI

// Shared icon geometry across every Anti Limited app: a full-bleed
// continuous-corner "squircle" — the exact shape SwiftUI's
// RoundedRectangle(.continuous) produces, so every app icon reads with the
// same corner radius.
func iconSquircle(_ rect: CGRect, ratio: CGFloat = 0.2237) -> CGPath {
    RoundedRectangle(cornerRadius: min(rect.width, rect.height) * ratio, style: .continuous)
        .path(in: rect).cgPath
}

// Draws the FileMaster app icon procedurally into an .iconset folder.
// Invoked by `make icon` via the `--icon <dir>` command-line flag.
//
// Subject: a fanned stack of paper documents on a deep-charcoal squircle with
// a warm bronze radial glow — the "den" metaphor in icon form.
enum AppIconRenderer {
    static func run(directory: String) {
        let dir = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // The full Apple iconset matrix: 16/32/128/256/512 @ 1x and 2x.
        let specs: [(base: Int, scale: Int)] = [
            (16, 1), (16, 2), (32, 1), (32, 2), (128, 1),
            (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
        ]
        for spec in specs {
            let px = spec.base * spec.scale
            guard let data = png(size: CGFloat(px)) else { continue }
            let name = spec.scale == 1
                ? "icon_\(spec.base)x\(spec.base).png"
                : "icon_\(spec.base)x\(spec.base)@2x.png"
            try? data.write(to: dir.appendingPathComponent(name))
        }
        FileHandle.standardError.write(Data("Icon written to \(directory)\n".utf8))
    }

    private static func png(size: CGFloat) -> Data? {
        let px = Int(size)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        draw(in: ctx.cgContext, size: size)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    private static func draw(in cg: CGContext, size: CGFloat) {
        let space = CGColorSpaceCreateDeviceRGB()
        func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
            CGColor(red: r, green: g, blue: b, alpha: a)
        }

        // ── Background squircle (full-bleed, shared geometry) ────────────────
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        let bg = iconSquircle(rect)

        cg.saveGState()
        cg.addPath(bg)
        cg.clip()

        // Deep charcoal base — near-black with a faint warm bias so the bronze
        // glow doesn't feel like a separate layer.
        let bgGrad = CGGradient(colorsSpace: space, colors: [
            rgb(0.18, 0.15, 0.12),
            rgb(0.09, 0.07, 0.05),
            rgb(0.04, 0.03, 0.02),
        ] as CFArray, locations: [0, 0.55, 1])!
        cg.drawLinearGradient(bgGrad,
                              start: CGPoint(x: rect.minX, y: rect.maxY),
                              end: CGPoint(x: rect.maxX, y: rect.minY),
                              options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

        // Warm bronze radial glow centred slightly low — "light from below the
        // stack" feeling. Matches the warmth tone in the banner.
        let glow = CGGradient(colorsSpace: space, colors: [
            rgb(0.91, 0.59, 0.24, 0.55),     // accentTo from appstage
            rgb(0.65, 0.40, 0.15, 0.18),
            rgb(0.91, 0.59, 0.24, 0.0),
        ] as CFArray, locations: [0, 0.5, 1])!
        cg.drawRadialGradient(glow,
                              startCenter: CGPoint(x: rect.midX, y: rect.midY - size * 0.06),
                              startRadius: 0,
                              endCenter: CGPoint(x: rect.midX, y: rect.midY - size * 0.06),
                              endRadius: rect.width * 0.6, options: [])
        cg.restoreGState()

        // Continuous rim around the squircle — faint constant stroke for
        // visibility, with a glassy top-highlight/bottom-shade gradient layered
        // on top (lifted verbatim from Clonk so all our icons read the same
        // bevel).
        cg.saveGState()
        cg.addPath(bg)
        cg.setLineWidth(size * 0.008)
        cg.setStrokeColor(rgb(1, 1, 1, 0.18))
        cg.strokePath()
        cg.restoreGState()

        cg.saveGState()
        cg.addPath(bg)
        cg.setLineWidth(size * 0.012)
        cg.replacePathWithStrokedPath()
        cg.clip()
        let edgeGrad = CGGradient(colorsSpace: space, colors: [
            rgb(1, 1, 1, 0.32),
            rgb(1, 1, 1, 0.0),
            rgb(0, 0, 0, 0.45),
        ] as CFArray, locations: [0, 0.5, 1])!
        cg.drawLinearGradient(edgeGrad, start: CGPoint(x: 0, y: rect.maxY),
                              end: CGPoint(x: 0, y: rect.minY), options: [])
        cg.restoreGState()

        // ── Paper stack ──────────────────────────────────────────────────────
        //
        // Three documents fanned out behind the front sheet — like cards held
        // in a hand. Each sheet is a tall, rounded portrait page. The back two
        // are rotated outward and shaded darker; the front sheet carries the
        // text-line motif and a folded top-right corner.

        // Compositional centre of the stack — slightly above geometric centre
        // so the radial glow underneath reads as light from below.
        let cx = rect.midX
        let cy = rect.midY + size * 0.02

        // Page dimensions: ~38% × 47% of the icon, portrait (5:7).
        let pageW = size * 0.38
        let pageH = size * 0.50
        let pageR = pageW * 0.08            // page corner radius
        let fold  = pageW * 0.18            // folded-corner length

        // Pre-build the page silhouette once; reused for each layer.
        let frontRect = CGRect(x: cx - pageW / 2, y: cy - pageH / 2,
                               width: pageW, height: pageH)

        // Helper — draw one page rotated about (cx, cy) with the given fill
        // gradient, optional folded corner, and an outer drop-shadow.
        func drawPage(angle: CGFloat,
                      offset: CGSize,
                      topColor: CGColor,
                      bottomColor: CGColor,
                      foldCorner: Bool,
                      drawLines: Bool) {
            cg.saveGState()
            cg.translateBy(x: cx + offset.width, y: cy + offset.height)
            cg.rotate(by: angle)
            cg.translateBy(x: -cx, y: -cy)

            // Drop shadow lifts each sheet off the one behind it.
            cg.setShadow(offset: CGSize(width: 0, height: -size * 0.012),
                         blur: size * 0.035,
                         color: rgb(0, 0, 0, 0.55))

            // Page silhouette — with an optional folded top-right corner
            // (where the triangle is "missing" from the page outline).
            let path = CGMutablePath()
            if foldCorner {
                let r = pageR
                let f = fold
                // Bottom-left, up the left edge, across the top to the fold-
                // start, diagonal down to the fold-end, then down to bottom.
                let bl  = CGPoint(x: frontRect.minX, y: frontRect.minY)
                let tlA = CGPoint(x: frontRect.minX, y: frontRect.maxY - r)
                let tlB = CGPoint(x: frontRect.minX + r, y: frontRect.maxY)
                let foldStart = CGPoint(x: frontRect.maxX - f, y: frontRect.maxY)
                let foldEnd   = CGPoint(x: frontRect.maxX, y: frontRect.maxY - f)
                let brA = CGPoint(x: frontRect.maxX, y: frontRect.minY + r)
                let brB = CGPoint(x: frontRect.maxX - r, y: frontRect.minY)
                let blEnd = CGPoint(x: frontRect.minX + r, y: frontRect.minY)
                path.move(to: bl)
                path.addLine(to: tlA)
                path.addArc(tangent1End: CGPoint(x: frontRect.minX, y: frontRect.maxY),
                            tangent2End: tlB, radius: r)
                path.addLine(to: foldStart)
                path.addLine(to: foldEnd)
                path.addLine(to: brA)
                path.addArc(tangent1End: CGPoint(x: frontRect.maxX, y: frontRect.minY),
                            tangent2End: brB, radius: r)
                path.addLine(to: blEnd)
                path.addArc(tangent1End: CGPoint(x: frontRect.minX, y: frontRect.minY),
                            tangent2End: bl, radius: r)
                path.closeSubpath()
            } else {
                path.addPath(CGPath(roundedRect: frontRect, cornerWidth: pageR,
                                    cornerHeight: pageR, transform: nil))
            }

            // Paper fill — soft top-to-bottom gradient so the page has volume.
            cg.saveGState()
            cg.addPath(path)
            cg.clip()
            let pageGrad = CGGradient(colorsSpace: space, colors: [
                topColor, bottomColor,
            ] as CFArray, locations: [0, 1])!
            cg.drawLinearGradient(pageGrad,
                                  start: CGPoint(x: frontRect.midX, y: frontRect.maxY),
                                  end: CGPoint(x: frontRect.midX, y: frontRect.minY),
                                  options: [])
            cg.restoreGState()

            // Stop shadowing further strokes/fills on this page.
            cg.setShadow(offset: .zero, blur: 0, color: nil)

            // Folded-corner triangle, drawn slightly darker to read as the back
            // of the curled page.
            if foldCorner {
                let tri = CGMutablePath()
                tri.move(to: CGPoint(x: frontRect.maxX - fold, y: frontRect.maxY))
                tri.addLine(to: CGPoint(x: frontRect.maxX, y: frontRect.maxY - fold))
                tri.addLine(to: CGPoint(x: frontRect.maxX - fold,
                                        y: frontRect.maxY - fold))
                tri.closeSubpath()
                cg.addPath(tri)
                cg.setFillColor(rgb(0.78, 0.76, 0.72))
                cg.fillPath()

                // A thin shadow at the inner fold line for depth.
                cg.move(to: CGPoint(x: frontRect.maxX - fold, y: frontRect.maxY))
                cg.addLine(to: CGPoint(x: frontRect.maxX - fold,
                                       y: frontRect.maxY - fold))
                cg.addLine(to: CGPoint(x: frontRect.maxX, y: frontRect.maxY - fold))
                cg.setStrokeColor(rgb(0, 0, 0, 0.18))
                cg.setLineWidth(size * 0.003)
                cg.strokePath()
            }

            // Text lines — five short horizontal bars, ragged-right like real
            // body copy. Only on the front sheet; back sheets stay blank so the
            // icon doesn't get noisy at small sizes.
            if drawLines {
                cg.saveGState()
                cg.addPath(path)
                cg.clip()
                let lineX = frontRect.minX + pageW * 0.14
                let lineW = pageW * 0.72
                let widths: [CGFloat] = [0.95, 0.80, 0.88, 0.70, 0.55]
                let topLineY = frontRect.maxY - pageH * 0.30
                let gap = pageH * 0.08
                let thickness = max(size * 0.012, 1)
                cg.setFillColor(rgb(0.42, 0.40, 0.36, 0.85))
                for (i, w) in widths.enumerated() {
                    let y = topLineY - CGFloat(i) * gap
                    let r = CGRect(x: lineX, y: y - thickness / 2,
                                   width: lineW * w, height: thickness)
                    cg.fill(r)
                }
                cg.restoreGState()
            }

            // 1-pixel inner edge highlight along the top — bevels the sheet.
            cg.saveGState()
            cg.addPath(path)
            cg.setLineWidth(size * 0.004)
            cg.setStrokeColor(rgb(1, 1, 1, 0.55))
            cg.strokePath()
            cg.restoreGState()

            cg.restoreGState()
        }

        // Back-left sheet — rotated a little CCW, pushed up-left.
        drawPage(angle:  0.16,
                 offset: CGSize(width: -size * 0.030, height:  size * 0.014),
                 topColor:    rgb(0.78, 0.76, 0.72),
                 bottomColor: rgb(0.55, 0.53, 0.49),
                 foldCorner: false,
                 drawLines:  false)

        // Back-right sheet — rotated CW, pushed up-right.
        drawPage(angle: -0.18,
                 offset: CGSize(width:  size * 0.030, height:  size * 0.018),
                 topColor:    rgb(0.78, 0.76, 0.72),
                 bottomColor: rgb(0.55, 0.53, 0.49),
                 foldCorner: false,
                 drawLines:  false)

        // Front sheet — upright, brightest, text lines, folded corner.
        drawPage(angle: 0,
                 offset: .zero,
                 topColor:    rgb(0.96, 0.94, 0.90),
                 bottomColor: rgb(0.85, 0.82, 0.76),
                 foldCorner: true,
                 drawLines:  true)
    }
}
