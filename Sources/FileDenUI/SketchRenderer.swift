import AppKit
import SceneKit
import CoreGraphics
import CoreText

/// Converts a sketch image into a 3D design-render PDF.
///
/// No furniture categories, no AI. Extracts the dimensions via Vision OCR,
/// renders a proportional massing form with SceneKit, and produces a design
/// sheet with orthographic views and dimension callouts — the same way
/// SVGGraphGenerator turns a numeric spec into a chart.
enum SketchRenderer {

    static func render(_ urls: [URL], progress: @escaping (Double) -> Void) -> [URL] {
        let dir = Staging.dir("3D")
        var out: [URL] = []

        for (i, url) in urls.enumerated() {
            progress(Double(i) / Double(urls.count))
            guard let ns = NSImage(contentsOf: url),
                  let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else { continue }

            let info = SketchAnalyzer.analyze(cg)
            progress((Double(i) + 0.4) / Double(urls.count))

            guard let render = buildPerspective(info: info) else { continue }
            progress((Double(i) + 0.85) / Double(urls.count))

            let stem = url.deletingPathExtension().lastPathComponent
            let dest = Staging.uniqueURL(in: dir, name: "\(stem) 3D Design.pdf")
            if writeDesignPDF(render: render, sketch: ns, info: info, to: dest) {
                out.append(dest)
            }
            progress(Double(i + 1) / Double(urls.count))
        }
        return out
    }

    // MARK: - SceneKit render

    private static func buildPerspective(info: SketchInfo) -> NSImage? {
        let w = CGFloat(info.widthCm)  / 100
        let h = CGFloat(info.heightCm) / 100
        let d = CGFloat(info.depthCm)  / 100

        let scene = SCNScene()

        // The form: a single proportional solid — chamfer scaled to the
        // smallest dimension so thick objects feel solid, thin ones feel crisp.
        let chamfer = min(w, h, d) * 0.06
        let form    = SCNBox(width: w, height: h, length: d, chamferRadius: chamfer)
        form.materials = [conceptMaterial()]
        let formNode = SCNNode(geometry: form)
        formNode.position = SCNVector3(0, h / 2, 0)
        scene.rootNode.addChildNode(formNode)

        // Ground — subtle shadow only, no geometry visible.
        let floor = SCNFloor()
        floor.reflectivity = 0.0
        let fm = SCNMaterial()
        fm.diffuse.contents = NSColor(white: 0.97, alpha: 1)
        floor.materials = [fm]
        scene.rootNode.addChildNode(SCNNode(geometry: floor))

        // Lighting — product-photography three-point.
        // Key: strong directional, casts the defining shadow.
        scene.rootNode.addChildNode(light(.directional, intensity: 1100,
                                          color: NSColor(white: 1.0, alpha: 1),
                                          euler: (-0.6, 0.5, 0), shadow: true))
        // Fill: soft, from opposite side — keeps shadow side readable.
        scene.rootNode.addChildNode(light(.directional, intensity: 320,
                                          color: NSColor(white: 0.75, alpha: 1),
                                          euler: (-0.2, -1.2, 0), shadow: false))
        // Rim: grazes the back-top edge — separates form from background.
        scene.rootNode.addChildNode(light(.directional, intensity: 250,
                                          color: NSColor(white: 0.9, alpha: 1),
                                          euler: (0.5, 2.8, 0), shadow: false))
        // Ambient: low enough to keep shadows but avoid jet-black faces.
        scene.rootNode.addChildNode(light(.ambient, intensity: 220,
                                          color: NSColor(white: 1.0, alpha: 1),
                                          euler: (0, 0, 0), shadow: false))

        // Camera: 3/4 angle that clearly shows all three dimensions.
        let cam = SCNCamera()
        cam.fieldOfView = 34
        cam.automaticallyAdjustsZRange = true
        let camNode = SCNNode(); camNode.camera = cam
        camNode.position = SCNVector3(w * 1.15 + 0.4, h * 1.05 + 0.25, d * 1.45 + 1.1)
        camNode.look(at: SCNVector3(0, h * 0.3, 0))
        scene.rootNode.addChildNode(camNode)

        scene.background.contents = NSColor(white: 0.98, alpha: 1)

        let renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = scene; renderer.pointOfView = camNode
        return renderer.snapshot(atTime: 0,
                                  with: CGSize(width: 1600, height: 1200),
                                  antialiasingMode: .multisampling4X)
    }

    /// Matte clay / concept-model material — neutral so the form reads clearly,
    /// not a material choice.
    private static func conceptMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents  = NSColor(red: 0.91, green: 0.89, blue: 0.86, alpha: 1)
        m.specular.contents = NSColor(white: 0.04, alpha: 1)
        m.lightingModel     = .lambert   // fully matte — only diffuse
        return m
    }

    private static func light(_ type: SCNLight.LightType, intensity: CGFloat,
                               color: NSColor, euler: (CGFloat, CGFloat, CGFloat),
                               shadow: Bool) -> SCNNode {
        let l = SCNLight(); l.type = type; l.intensity = intensity; l.color = color
        l.castsShadow = shadow
        if shadow {
            l.shadowMode   = .deferred
            l.shadowRadius = 4
            l.shadowColor  = NSColor(white: 0, alpha: 0.28)
        }
        let n = SCNNode(); n.light = l
        n.eulerAngles = SCNVector3(euler.0, euler.1, euler.2)
        return n
    }

    // MARK: - PDF design sheet

    private static func writeDesignPDF(render: NSImage, sketch: NSImage,
                                       info: SketchInfo, to dest: URL) -> Bool {
        let W: CGFloat = 841, H: CGFloat = 595   // A4 landscape
        var box = CGRect(x: 0, y: 0, width: W, height: H)
        guard let ctx = CGContext(dest as CFURL, mediaBox: &box, nil) else { return false }
        ctx.beginPage(mediaBox: &box)

        // White page.
        ctx.setFillColor(CGColor.white); ctx.fill(box)

        // Header.
        let headerH: CGFloat = 46
        ctx.setFillColor(NSColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: H - headerH, width: W, height: headerH))
        pdfText("DESIGN RENDER", ctFont(14, bold: true), .white,
                at: CGPoint(x: 22, y: H - 30), ctx: ctx)
        pdfTextRight(info.dimensionLabel, ctFont(10, bold: false),
                     NSColor(white: 0.65, alpha: 1).cgColor, maxX: W - 22, y: H - 32, ctx: ctx)

        // Layout: left 58% perspective, right 42% ortho stack.
        let bodyBot: CGFloat = 28
        let bodyTop = H - headerH
        let bodyH   = bodyTop - bodyBot
        let splitX  = W * 0.575

        // Perspective.
        drawImage(render, in: CGRect(x: 8, y: bodyBot, width: splitX - 14, height: bodyH - 6), ctx: ctx)

        // Sketch thumbnail — small, top of right column.
        let thumbH: CGFloat = 72
        let thumbRect = CGRect(x: splitX + 6, y: bodyTop - thumbH,
                               width: W - splitX - 14, height: thumbH - 4)
        ctx.setStrokeColor(NSColor(white: 0.82, alpha: 1).cgColor)
        ctx.setLineWidth(0.4); ctx.stroke(thumbRect)
        drawImage(sketch, in: thumbRect.insetBy(dx: 2, dy: 2), ctx: ctx)
        pdfText("SKETCH", ctFont(7, bold: false), NSColor(white: 0.5, alpha: 1).cgColor,
                at: CGPoint(x: thumbRect.minX + 4, y: thumbRect.minY + 4), ctx: ctx)

        // Three ortho views stacked below the thumbnail.
        let orthoTop  = bodyTop - thumbH
        let orthoH    = (orthoTop - bodyBot - 8) / 3
        let orthoX    = splitX + 6
        let orthoW    = W - orthoX - 8

        let views: [(String, Double, Double, String, String)] = [
            ("FRONT",  info.widthCm,  info.heightCm, "W", "H"),
            ("SIDE",   info.depthCm,  info.heightCm, "D", "H"),
            ("TOP",    info.widthCm,  info.depthCm,  "W", "D"),
        ]
        for (i, (label, hDim, vDim, hL, vL)) in views.enumerated() {
            let y = bodyBot + orthoH * CGFloat(2 - i) + 2 * CGFloat(2 - i)
            drawOrthoView(
                in:     CGRect(x: orthoX, y: y, width: orthoW, height: orthoH - 2),
                hDim:   hDim, vDim: vDim,
                hLabel: "\(hL) \(fmtDim(hDim)) cm",
                vLabel: "\(vL) \(fmtDim(vDim)) cm",
                label:  label, ctx: ctx)
        }

        // Footer.
        let date = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .none)
        pdfText("FileDen · \(date)", ctFont(7, bold: false),
                NSColor(white: 0.58, alpha: 1).cgColor, at: CGPoint(x: 22, y: 10), ctx: ctx)

        ctx.endPage(); ctx.closePDF()
        return FileManager.default.fileExists(atPath: dest.path)
    }

    // MARK: - Orthographic technical view

    private static func drawOrthoView(in rect: CGRect,
                                      hDim: Double, vDim: Double,
                                      hLabel: String, vLabel: String,
                                      label: String, ctx: CGContext) {
        ctx.setFillColor(NSColor(white: 0.975, alpha: 1).cgColor); ctx.fill(rect)
        ctx.setStrokeColor(NSColor(white: 0.86, alpha: 1).cgColor)
        ctx.setLineWidth(0.35); ctx.stroke(rect)

        let dimPad: CGFloat = 26, lblPad: CGFloat = 12
        let avail = rect.insetBy(dx: dimPad + lblPad, dy: dimPad + lblPad)
        guard avail.width > 2, avail.height > 2 else { return }

        let scale  = min(avail.width / CGFloat(hDim), avail.height / CGFloat(vDim))
        let dw     = CGFloat(hDim) * scale, dh = CGFloat(vDim) * scale
        let objR   = CGRect(x: avail.midX - dw / 2, y: avail.midY - dh / 2, width: dw, height: dh)

        ctx.setFillColor(NSColor(white: 0.90, alpha: 1).cgColor); ctx.fill(objR)
        ctx.setStrokeColor(NSColor(white: 0.22, alpha: 1).cgColor)
        ctx.setLineWidth(1.0); ctx.stroke(objR)

        let off: CGFloat = 13, gap: CGFloat = 4

        // Horizontal dim line (below).
        dimLine(ctx, from: CGPoint(x: objR.minX, y: objR.minY - off),
                     to:   CGPoint(x: objR.maxX, y: objR.minY - off),
                extFrom: objR.minY - gap, extTo: objR.minY - off - 3,
                label: hLabel, vertical: false)

        // Vertical dim line (left).
        dimLine(ctx, from: CGPoint(x: objR.minX - off, y: objR.minY),
                     to:   CGPoint(x: objR.minX - off, y: objR.maxY),
                extFrom: objR.minX - gap, extTo: objR.minX - off - 3,
                label: vLabel, vertical: true)

        pdfText(label, ctFont(7, bold: false), NSColor(white: 0.48, alpha: 1).cgColor,
                at: CGPoint(x: rect.minX + 5, y: rect.maxY - 10), ctx: ctx)
    }

    private static func dimLine(_ ctx: CGContext,
                                from: CGPoint, to: CGPoint,
                                extFrom: CGFloat, extTo: CGFloat,
                                label: String, vertical: Bool) {
        ctx.saveGState()
        ctx.setStrokeColor(NSColor(white: 0.28, alpha: 1).cgColor)
        ctx.setFillColor(NSColor(white: 0.28, alpha: 1).cgColor)
        ctx.setLineWidth(0.5)

        if vertical {
            ctx.move(to: from); ctx.addLine(to: to); ctx.strokePath()
            for y in [from.y, to.y] {
                ctx.move(to: CGPoint(x: extFrom, y: y))
                ctx.addLine(to: CGPoint(x: extTo, y: y)); ctx.strokePath()
            }
            arrow(ctx, tip: from, dx: 0, dy: -1)
            arrow(ctx, tip: to,   dx: 0, dy:  1)
            let mid = CGPoint(x: from.x - 9, y: (from.y + to.y) / 2)
            ctx.saveGState()
            ctx.translateBy(x: mid.x, y: mid.y); ctx.rotate(by: .pi / 2)
            pdfTextCentred(label, ctFont(7, bold: false),
                           NSColor(white: 0.22, alpha: 1).cgColor, at: .zero, ctx: ctx)
            ctx.restoreGState()
        } else {
            ctx.move(to: from); ctx.addLine(to: to); ctx.strokePath()
            for x in [from.x, to.x] {
                ctx.move(to: CGPoint(x: x, y: extFrom))
                ctx.addLine(to: CGPoint(x: x, y: extTo)); ctx.strokePath()
            }
            arrow(ctx, tip: from, dx: -1, dy: 0)
            arrow(ctx, tip: to,   dx:  1, dy: 0)
            pdfTextCentred(label, ctFont(7, bold: false),
                           NSColor(white: 0.22, alpha: 1).cgColor,
                           at: CGPoint(x: (from.x + to.x) / 2, y: from.y - 9), ctx: ctx)
        }
        ctx.restoreGState()
    }

    private static func arrow(_ ctx: CGContext, tip: CGPoint, dx: CGFloat, dy: CGFloat) {
        let len: CGFloat = 5, w: CGFloat = 2.2
        let base = CGPoint(x: tip.x - dx * len, y: tip.y - dy * len)
        ctx.beginPath()
        ctx.move(to: tip)
        ctx.addLine(to: CGPoint(x: base.x - dy * w, y: base.y + dx * w))
        ctx.addLine(to: CGPoint(x: base.x + dy * w, y: base.y - dx * w))
        ctx.closePath(); ctx.fillPath()
    }

    // MARK: - PDF drawing helpers

    private static func ctFont(_ size: CGFloat, bold: Bool) -> CTFont {
        CTFontCreateWithName((bold ? "Helvetica Neue Bold" : "Helvetica Neue") as CFString, size, nil)
    }

    private static func pdfText(_ s: String, _ f: CTFont, _ c: CGColor,
                                 at pt: CGPoint, ctx: CGContext) {
        let a = NSAttributedString(string: s, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: f,
            kCTForegroundColorAttributeName as NSAttributedString.Key: c,
        ])
        ctx.saveGState(); ctx.textPosition = pt
        CTLineDraw(CTLineCreateWithAttributedString(a), ctx); ctx.restoreGState()
    }

    private static func pdfTextCentred(_ s: String, _ f: CTFont, _ c: CGColor,
                                        at pt: CGPoint, ctx: CGContext) {
        let a = NSAttributedString(string: s, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: f,
            kCTForegroundColorAttributeName as NSAttributedString.Key: c,
        ])
        let line = CTLineCreateWithAttributedString(a)
        let w = CTLineGetTypographicBounds(line, nil, nil, nil)
        ctx.saveGState(); ctx.textPosition = CGPoint(x: pt.x - w / 2, y: pt.y)
        CTLineDraw(line, ctx); ctx.restoreGState()
    }

    private static func pdfTextRight(_ s: String, _ f: CTFont, _ c: CGColor,
                                      maxX: CGFloat, y: CGFloat, ctx: CGContext) {
        let a = NSAttributedString(string: s, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: f,
            kCTForegroundColorAttributeName as NSAttributedString.Key: c,
        ])
        let line = CTLineCreateWithAttributedString(a)
        let w = CTLineGetTypographicBounds(line, nil, nil, nil)
        ctx.saveGState(); ctx.textPosition = CGPoint(x: maxX - w, y: y)
        CTLineDraw(line, ctx); ctx.restoreGState()
    }

    private static func drawImage(_ image: NSImage, in rect: CGRect, ctx: CGContext) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let iw = CGFloat(cg.width), ih = CGFloat(cg.height)
        let s  = min(rect.width / iw, rect.height / ih)
        ctx.draw(cg, in: CGRect(x: rect.midX - iw*s/2, y: rect.midY - ih*s/2,
                                width: iw*s, height: ih*s))
    }

    private static func fmtDim(_ v: Double) -> String {
        v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", v)
    }
}
