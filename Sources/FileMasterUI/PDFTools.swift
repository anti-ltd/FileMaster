import AppKit
import CoreGraphics
import CoreImage
import CoreText
import PDFKit
import Vision

/// Native PDF operations backing the den's "PDF Tools" menu.
///
/// Everything here is pure file-in / file-out: each function takes the URLs the
/// user selected and returns the URLs it produced. Output lands in a fresh
/// per-call staging directory under `tmp`, so callers can drop the results into
/// a new den without touching the originals. Nothing here touches the UI — the
/// caller (`ActionBridge`) is responsible for opening a den with the results.
///
/// All work is best-effort: a file that can't be read, an unsupported encoding,
/// or a failed write is skipped rather than aborting the batch.
enum PDFTools {

    static func isPDF(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "pdf"
    }

    // MARK: - Operations

    /// Concatenate every selected PDF, in selection order, into one document.
    static func merge(_ urls: [URL]) -> [URL] {
        let out = PDFDocument()
        var index = 0
        for url in urls {
            guard let doc = PDFDocument(url: url) else { continue }
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
                out.insert(page, at: index)
                index += 1
            }
        }
        guard index > 0 else { return [] }
        let dest = Staging.uniqueURL(in: Staging.dir("PDF"), name: "Merged.pdf")
        return out.write(to: dest) ? [dest] : []
    }

    /// Explode each PDF into one single-page PDF per page, gathered in a folder
    /// per source document.
    static func splitPages(_ urls: [URL]) -> [URL] {
        let base = Staging.dir("PDF")
        var out: [URL] = []
        for url in urls {
            guard let doc = PDFDocument(url: url), doc.pageCount > 0 else { continue }
            let stem = url.deletingPathExtension().lastPathComponent
            let folder = Staging.uniqueURL(in: base, name: "\(stem) pages")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let width = max(2, String(doc.pageCount).count)
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
                let single = PDFDocument()
                single.insert(page, at: 0)
                let num = String(format: "%0\(width)d", i + 1)
                single.write(to: folder.appendingPathComponent("\(stem) \(num).pdf"))
            }
            out.append(folder)
        }
        return out
    }

    /// Rasterize each page to a 2x PNG, gathered in a folder per source document.
    static func exportPageImages(_ urls: [URL]) -> [URL] {
        let base = Staging.dir("PDF")
        var out: [URL] = []
        for url in urls {
            guard let doc = PDFDocument(url: url), doc.pageCount > 0 else { continue }
            let stem = url.deletingPathExtension().lastPathComponent
            let folder = Staging.uniqueURL(in: base, name: "\(stem) images")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let width = max(2, String(doc.pageCount).count)
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i), let png = renderPNG(page: page, scale: 2) else { continue }
                let num = String(format: "%0\(width)d", i + 1)
                try? png.write(to: folder.appendingPathComponent("\(stem) \(num).png"))
            }
            out.append(folder)
        }
        return out
    }

    /// Pull the embedded image objects out of each PDF, gathered in a folder per
    /// source document. JPEG and JPEG2000 streams are written verbatim; other
    /// streams are reconstructed from their decoded samples. Encodings we can't
    /// faithfully rebuild (indexed, CCITT/JBIG2 fax, etc.) are skipped.
    static func extractImages(_ urls: [URL]) -> [URL] {
        let base = Staging.dir("PDF")
        var out: [URL] = []
        for url in urls {
            guard let doc = CGPDFDocument(url as CFURL), doc.numberOfPages > 0 else { continue }
            let stem = url.deletingPathExtension().lastPathComponent
            let folder = Staging.uniqueURL(in: base, name: "\(stem) extracted")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let collector = ImageCollector(stem: stem, destDir: folder)
            for p in 1...doc.numberOfPages {
                guard let page = doc.page(at: p), let dict = page.dictionary else { continue }
                collector.pageIndex = p
                extractImages(fromPage: dict, into: collector)
            }
            if collector.written.isEmpty {
                try? FileManager.default.removeItem(at: folder)
            } else {
                out.append(folder)
            }
        }
        return out
    }

    /// Lift the text layer out of each PDF into a `.txt` file. PDFs with no
    /// extractable text (e.g. pure scans) are skipped.
    static func extractText(_ urls: [URL]) -> [URL] {
        let dir = Staging.dir("PDF")
        var out: [URL] = []
        for url in urls {
            guard let doc = PDFDocument(url: url),
                  let text = doc.string, !text.isEmpty,
                  let data = text.data(using: .utf8) else { continue }
            let dest = Staging.uniqueURL(in: dir, name: url.deletingPathExtension().lastPathComponent + ".txt")
            if (try? data.write(to: dest)) != nil { out.append(dest) }
        }
        return out
    }

    /// Combine the selected images into a single PDF, one image per page.
    static func combineToPDF(_ urls: [URL]) -> [URL] {
        let pdf = PDFDocument()
        var index = 0
        for url in urls {
            guard let image = NSImage(contentsOf: url), let page = PDFPage(image: image) else { continue }
            pdf.insert(page, at: index)
            index += 1
        }
        guard index > 0 else { return [] }
        let name = urls.count == 1
            ? urls[0].deletingPathExtension().lastPathComponent + ".pdf"
            : "Combined.pdf"
        let dest = Staging.uniqueURL(in: Staging.dir("PDF"), name: name)
        return pdf.write(to: dest) ? [dest] : []
    }

    static func canDigitize(_ url: URL) -> Bool {
        isPDF(url) || FileActions.isImage(url)
    }

    /// OCR a scanned PDF or image and reflow the extracted text into a clean,
    /// paginated US-Letter document — no image, no positional layout, just
    /// readable body text with source-page separators.
    static func digitizeFormatted(_ urls: [URL], progress: @escaping (Double) -> Void) -> [URL] {
        let base = Staging.dir("PDF")
        var out: [URL] = []

        for (fileIdx, url) in urls.enumerated() {
            var images: [CGImage] = []
            if isPDF(url) {
                guard let doc = PDFDocument(url: url), doc.pageCount > 0 else { continue }
                for i in 0..<doc.pageCount {
                    guard let page = doc.page(at: i) else { continue }
                    let bounds = page.bounds(for: .mediaBox)
                    guard bounds.width > 0, bounds.height > 0 else { continue }
                    let size = NSSize(width: bounds.width * 2, height: bounds.height * 2)
                    var r = CGRect(origin: .zero, size: size)
                    if let cg = page.thumbnail(of: size, for: .mediaBox)
                        .cgImage(forProposedRect: &r, context: nil, hints: nil) { images.append(cg) }
                }
            } else {
                guard let ns = NSImage(contentsOf: url) else { continue }
                var r = CGRect(origin: .zero, size: ns.size)
                if let cg = ns.cgImage(forProposedRect: &r, context: nil, hints: nil) { images.append(cg) }
            }
            guard !images.isEmpty else { continue }

            var pageTexts: [String] = []
            for (imgIdx, cgImage) in images.enumerated() {
                let req = VNRecognizeTextRequest()
                req.recognitionLevel = .accurate
                req.usesLanguageCorrection = true
                req.automaticallyDetectsLanguage = true
                try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([req])
                let text = (req.results ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                pageTexts.append(text)
                progress((Double(fileIdx) + Double(imgIdx + 1) / Double(images.count) * 0.95)
                    / Double(urls.count))
            }

            let stem = url.deletingPathExtension().lastPathComponent
            let dest = Staging.uniqueURL(in: base, name: "\(stem).pdf")
            if makeFormattedPDF(pages: pageTexts, dest: dest) { out.append(dest) }
            progress(Double(fileIdx + 1) / Double(urls.count))
        }

        return out
    }

    private static func makeFormattedPDF(pages: [String], dest: URL) -> Bool {
        let pageW: CGFloat = 612, pageH: CGFloat = 792, margin: CGFloat = 72
        var box = CGRect(x: 0, y: 0, width: pageW, height: pageH)
        guard let ctx = CGContext(dest as CFURL, mediaBox: &box, nil) else { return false }

        let bodyFont  = CTFontCreateWithName("Georgia" as CFString, 12, nil)
        let rulerFont = CTFontCreateWithName("Helvetica Neue" as CFString, 9, nil)
        let gray      = CGColor(gray: 0.55, alpha: 1)

        let full = NSMutableAttributedString()
        for (i, text) in pages.enumerated() {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if i > 0 {
                full.append(NSAttributedString(
                    string: "\n\n\u{2015}\u{2015}\u{2015}\u{2015}\u{2015}\n\n",
                    attributes: [kCTFontAttributeName as NSAttributedString.Key: rulerFont,
                                 kCTForegroundColorAttributeName as NSAttributedString.Key: gray]))
            }
            if !trimmed.isEmpty {
                full.append(NSAttributedString(string: trimmed,
                    attributes: [kCTFontAttributeName as NSAttributedString.Key: bodyFont]))
            }
        }
        guard full.length > 0 else { ctx.closePDF(); return false }

        let setter  = CTFramesetterCreateWithAttributedString(full)
        let textBox = CGRect(x: margin, y: margin, width: pageW - 2*margin, height: pageH - 2*margin)
        var charOffset = 0
        while charOffset < full.length {
            ctx.beginPage(mediaBox: &box)
            let frame = CTFramesetterCreateFrame(setter,
                                                 CFRange(location: charOffset, length: 0),
                                                 CGPath(rect: textBox, transform: nil), nil)
            CTFrameDraw(frame, ctx)
            let visible = CTFrameGetVisibleStringRange(frame)
            ctx.endPage()
            if visible.length == 0 { break }
            charOffset += visible.length
        }

        ctx.closePDF()
        return FileManager.default.fileExists(atPath: dest.path)
    }

    /// One recognized text block with its four corner points in normalized
    /// Vision coordinates (0–1, bottom-left origin — same as PDF space).
    private struct TextElement {
        let text: String
        let bottomLeft: CGPoint
        let bottomRight: CGPoint
        let topLeft: CGPoint
    }

    /// OCR a scanned PDF or image and produce a layout-accurate text PDF.
    /// Each text block is drawn at the position and rotation it occupies in
    /// the original, sized to match its detected bounding-box height. The page
    /// dimensions match the source's aspect ratio (fitted to US Letter).
    static func digitize(_ urls: [URL], progress: @escaping (Double) -> Void) -> [URL] {
        let base = Staging.dir("PDF")
        var out: [URL] = []

        for (fileIdx, url) in urls.enumerated() {
            // Collect (CGImage, natural-size) pairs: render PDF pages or load images.
            var sources: [(CGImage, CGSize)] = []
            if isPDF(url) {
                guard let doc = PDFDocument(url: url), doc.pageCount > 0 else { continue }
                for i in 0..<doc.pageCount {
                    guard let page = doc.page(at: i) else { continue }
                    let bounds = page.bounds(for: .mediaBox)
                    guard bounds.width > 0, bounds.height > 0 else { continue }
                    let size = NSSize(width: bounds.width * 2, height: bounds.height * 2)
                    var r = CGRect(origin: .zero, size: size)
                    if let cg = page.thumbnail(of: size, for: .mediaBox)
                        .cgImage(forProposedRect: &r, context: nil, hints: nil) {
                        sources.append((cg, bounds.size))
                    }
                }
            } else {
                guard let ns = NSImage(contentsOf: url) else { continue }
                var r = CGRect(origin: .zero, size: ns.size)
                if let cg = ns.cgImage(forProposedRect: &r, context: nil, hints: nil) {
                    sources.append((cg, ns.size))
                }
            }
            guard !sources.isEmpty else { continue }

            // OCR each image, preserving corner-point layout per observation.
            var pageElements: [([TextElement], CGSize)] = []
            for (imgIdx, (cgImage, naturalSize)) in sources.enumerated() {
                let req = VNRecognizeTextRequest()
                req.recognitionLevel = .accurate
                req.usesLanguageCorrection = true
                req.automaticallyDetectsLanguage = true
                try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([req])
                let elements = (req.results ?? []).compactMap { obs -> TextElement? in
                    guard let s = obs.topCandidates(1).first?.string, !s.isEmpty else { return nil }
                    return TextElement(text: s,
                                       bottomLeft:  obs.bottomLeft,
                                       bottomRight: obs.bottomRight,
                                       topLeft:     obs.topLeft)
                }
                pageElements.append((elements, naturalSize))
                progress((Double(fileIdx) + Double(imgIdx + 1) / Double(sources.count) * 0.95)
                    / Double(urls.count))
            }

            let stem = url.deletingPathExtension().lastPathComponent
            let dest = Staging.uniqueURL(in: base, name: "\(stem).pdf")
            if makeLayoutPDF(pages: pageElements, dest: dest) { out.append(dest) }
            progress(Double(fileIdx + 1) / Double(urls.count))
        }

        return out
    }

    /// Render a layout-accurate PDF where every text block is placed at its
    /// detected position and rotation. Page dimensions preserve the source's
    /// aspect ratio, fitted within US Letter.
    private static func makeLayoutPDF(pages: [([TextElement], CGSize)], dest: URL) -> Bool {
        var zeroBox = CGRect.zero
        guard let ctx = CGContext(dest as CFURL, mediaBox: &zeroBox, nil) else { return false }

        for (elements, naturalSize) in pages {
            // Fit the source aspect ratio inside 612×792 (US Letter).
            let maxW: CGFloat = 612, maxH: CGFloat = 792
            let aspect = naturalSize.width / naturalSize.height
            let pageW = aspect >= maxW / maxH ? maxW : maxH * aspect
            let pageH = aspect >= maxW / maxH ? maxW / aspect : maxH
            var box = CGRect(x: 0, y: 0, width: pageW, height: pageH)

            ctx.beginPage(mediaBox: &box)
            ctx.setFillColor(CGColor.white)
            ctx.fill(box)

            for element in elements {
                // Convert normalized Vision coords → page coords.
                // Vision origin is bottom-left, matching PDF space — no flip needed.
                let blX = element.bottomLeft.x  * pageW
                let blY = element.bottomLeft.y  * pageH
                let brX = element.bottomRight.x * pageW
                let brY = element.bottomRight.y * pageH
                let tlX = element.topLeft.x * pageW
                let tlY = element.topLeft.y * pageH

                // Rotation: angle of the baseline vector
                let angle = atan2(brY - blY, brX - blX)

                // Font size from the perpendicular height of the text block
                let blockH = hypot(tlX - blX, tlY - blY)
                let fontSize = max(blockH * 0.8, 6)
                let font = CTFontCreateWithName("Helvetica Neue" as CFString, fontSize, nil)

                let attrStr = NSAttributedString(string: element.text, attributes: [
                    kCTFontAttributeName as NSAttributedString.Key: font,
                    kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor.black
                ])
                let line = CTLineCreateWithAttributedString(attrStr)

                // Horizontal scale so the text fills its detected width exactly.
                let lineW = CTLineGetTypographicBounds(line, nil, nil, nil)
                let targetW = hypot(brX - blX, brY - blY)
                let scaleX: CGFloat = lineW > 0 ? min(targetW / lineW, 2.5) : 1.0

                // The text matrix is not saved by gstate — set it around each draw.
                ctx.saveGState()
                ctx.translateBy(x: blX, y: blY)
                ctx.rotate(by: angle)
                ctx.textMatrix = CGAffineTransform(scaleX: scaleX, y: 1)
                ctx.textPosition = .zero
                CTLineDraw(line, ctx)
                ctx.restoreGState()
                ctx.textMatrix = .identity
            }

            ctx.endPage()
        }

        ctx.closePDF()
        return FileManager.default.fileExists(atPath: dest.path)
    }

    // MARK: - Searchable PDF

    /// How a scanned page is rendered into the searchable PDF.
    enum ScanCleanup {
        /// Keep the page pixel-for-pixel — looks exactly like the scan.
        case none
        /// Deskew, whiten the background, and sharpen for a crisp digital look.
        case enhance
    }

    /// OCR a scanned PDF (or image) into a *searchable* PDF: the page is drawn as
    /// an opaque background and an invisible text layer is laid over it, so the
    /// document is fully selectable and searchable. Recognized text is never
    /// painted, so OCR mistakes are never visible. With `cleanup == .enhance` the
    /// page is deskewed, whitened, and sharpened first; with `.none` it is kept
    /// pixel-for-pixel identical to the scan.
    static func digitizeSearchable(_ urls: [URL], cleanup: ScanCleanup = .none,
                                   progress: @escaping (Double) -> Void) -> [URL] {
        let base = Staging.dir("PDF")
        var out: [URL] = []
        for (fileIdx, url) in urls.enumerated() {
            let stem = url.deletingPathExtension().lastPathComponent
            let dest = Staging.uniqueURL(in: base, name: "\(stem).pdf")
            if writeSearchablePDF(from: url, to: dest, cleanup: cleanup,
                                  progress: { p in progress((Double(fileIdx) + p) / Double(urls.count)) }) {
                out.append(dest)
            }
            progress(Double(fileIdx + 1) / Double(urls.count))
        }
        return out
    }

    /// Build one searchable PDF from a single source. Each page draws its visible
    /// background, then an invisible CoreText layer positioned to track the
    /// recognized glyphs (so selection rectangles line up). Returns false if the
    /// source can't be opened or nothing was written.
    private static func writeSearchablePDF(from url: URL, to dest: URL, cleanup: ScanCleanup,
                                           progress: (Double) -> Void) -> Bool {
        // A page's visible background and the bitmap to recognize text from.
        struct Page { let box: CGRect; let draw: (CGContext) -> Void; let ocr: CGImage }

        var pages: [Page] = []
        var keepAlive: CGPDFDocument?   // retain the source doc while we draw it

        if isPDF(url) {
            guard let doc = CGPDFDocument(url as CFURL), doc.numberOfPages > 0,
                  let render = PDFDocument(url: url) else { return false }
            keepAlive = doc
            for i in 0..<doc.numberOfPages {
                guard let cgPage = doc.page(at: i + 1), let rPage = render.page(at: i) else { continue }
                let box = cgPage.getBoxRect(.mediaBox)
                guard box.width > 0, box.height > 0 else { continue }
                let size = NSSize(width: box.width * 2, height: box.height * 2)
                var r = CGRect(origin: .zero, size: size)
                guard let raw = rPage.thumbnail(of: size, for: .mediaBox)
                    .cgImage(forProposedRect: &r, context: nil, hints: nil) else { continue }
                switch cleanup {
                case .none:
                    pages.append(Page(box: box, draw: { ctx in
                        ctx.saveGState()
                        ctx.translateBy(x: -box.origin.x, y: -box.origin.y)
                        ctx.drawPDFPage(cgPage)
                        ctx.restoreGState()
                    }, ocr: raw))
                case .enhance:
                    let cleaned = enhance(raw)
                    pages.append(Page(box: box, draw: { ctx in ctx.draw(cleaned, in: CGRect(origin: .zero, size: box.size)) },
                                      ocr: cleaned))
                }
            }
        } else {
            guard let ns = NSImage(contentsOf: url) else { return false }
            var r = CGRect(origin: .zero, size: ns.size)
            guard let cg = ns.cgImage(forProposedRect: &r, context: nil, hints: nil) else { return false }
            let bg = cleanup == .enhance ? enhance(cg) : cg
            let box = CGRect(origin: .zero, size: ns.size)
            pages.append(Page(box: box, draw: { ctx in ctx.draw(bg, in: box) }, ocr: bg))
        }
        guard !pages.isEmpty else { return false }

        var firstBox = pages[0].box
        guard let ctx = CGContext(dest as CFURL, mediaBox: &firstBox, nil) else { return false }

        for (idx, page) in pages.enumerated() {
            var box = page.box
            ctx.beginPage(mediaBox: &box)
            page.draw(ctx)                              // visible: the page background
            drawInvisibleText(recognize(page.ocr), in: box.size, into: ctx)
            ctx.endPage()
            progress(Double(idx + 1) / Double(pages.count))
        }
        ctx.closePDF()
        keepAlive = nil
        _ = keepAlive
        return FileManager.default.fileExists(atPath: dest.path)
    }

    /// Shared Core Image context for the cleanup pass.
    private static let ciContext = CIContext(options: nil)

    /// Deskew, whiten, and sharpen a scanned page bitmap for a crisp digital
    /// look. Deskew is driven by the median text-baseline angle and only applied
    /// for small, plausible tilts (≈0.2°–6°) so it can never wildly rotate a page.
    private static func enhance(_ image: CGImage) -> CGImage {
        let w = image.width, h = image.height

        // 1. Deskew, painting onto white so the rotated corners stay clean.
        let angle = medianSkew(recognize(image))
        var base = image
        if abs(angle) > 0.003, abs(angle) < 0.105,
           let g = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
            g.setFillColor(.white)
            g.fill(CGRect(x: 0, y: 0, width: w, height: h))
            g.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
            g.rotate(by: -angle)
            g.translateBy(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2)
            g.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            base = g.makeImage() ?? image
        }

        // 2. Whiten the background, lift contrast, and sharpen.
        let ci = CIImage(cgImage: base)
        let processed = ci
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.0, kCIInputContrastKey: 1.2, kCIInputBrightnessKey: 0.05])
            .applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.5])
        return ciContext.createCGImage(processed, from: ci.extent) ?? base
    }

    /// Median baseline tilt of the recognized text, in radians (positive =
    /// counter-clockwise). Nearly-vertical or rotated blocks are ignored so a
    /// rotated sidebar can't skew the estimate. Returns 0 when there's no signal.
    private static func medianSkew(_ elements: [TextElement]) -> CGFloat {
        let angles = elements.compactMap { el -> CGFloat? in
            let dx = el.bottomRight.x - el.bottomLeft.x
            let dy = el.bottomRight.y - el.bottomLeft.y
            guard hypot(dx, dy) > 0.05 else { return nil }      // ignore tiny blocks
            let a = atan2(dy, dx)
            return abs(a) < 0.17 ? a : nil                       // ignore vertical/rotated text
        }.sorted()
        guard !angles.isEmpty else { return 0 }
        return angles[angles.count / 2]
    }

    /// Run Vision text recognition over one image, returning each block with its
    /// corner points in normalized (0–1, bottom-left) coordinates.
    private static func recognize(_ image: CGImage) -> [TextElement] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        req.automaticallyDetectsLanguage = true
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([req])
        return (req.results ?? []).compactMap { obs in
            guard let s = obs.topCandidates(1).first?.string, !s.isEmpty else { return nil }
            return TextElement(text: s, bottomLeft: obs.bottomLeft,
                               bottomRight: obs.bottomRight, topLeft: obs.topLeft)
        }
    }

    /// Paint `elements` as an invisible, selectable text layer sized to `pageSize`
    /// (points). Each block is placed, rotated, and horizontally scaled to span
    /// its detected box; nothing is rendered visibly because the text drawing
    /// mode is `.invisible`.
    private static func drawInvisibleText(_ elements: [TextElement], in pageSize: CGSize, into ctx: CGContext) {
        ctx.setTextDrawingMode(.invisible)
        for el in elements {
            let blX = el.bottomLeft.x  * pageSize.width, blY = el.bottomLeft.y  * pageSize.height
            let brX = el.bottomRight.x * pageSize.width, brY = el.bottomRight.y * pageSize.height
            let tlX = el.topLeft.x     * pageSize.width, tlY = el.topLeft.y     * pageSize.height

            let angle = atan2(brY - blY, brX - blX)
            let blockH = hypot(tlX - blX, tlY - blY)
            let font = CTFontCreateWithName("Helvetica" as CFString, max(blockH * 0.8, 6), nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: el.text, attributes: [kCTFontAttributeName as NSAttributedString.Key: font]))

            let lineW = CTLineGetTypographicBounds(line, nil, nil, nil)
            let targetW = hypot(brX - blX, brY - blY)
            let scaleX: CGFloat = lineW > 0 ? targetW / lineW : 1

            ctx.saveGState()
            ctx.translateBy(x: blX, y: blY)
            ctx.rotate(by: angle)
            ctx.textMatrix = CGAffineTransform(scaleX: scaleX, y: 1)
            ctx.textPosition = .zero
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
        ctx.textMatrix = .identity
    }

    // MARK: - Rendering

    /// Render a page (its crop box, honouring rotation) into PNG data at `scale`.
    private static func renderPNG(page: PDFPage, scale: CGFloat) -> Data? {
        let box = PDFDisplayBox.cropBox
        let bounds = page.bounds(for: box)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let rotated = page.rotation % 180 != 0
        let displayW = rotated ? bounds.height : bounds.width
        let displayH = rotated ? bounds.width : bounds.height
        let size = NSSize(width: displayW * scale, height: displayH * scale)
        guard size.width >= 1, size.height >= 1 else { return nil }
        let image = page.thumbnail(of: size, for: box)
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Embedded-image extraction

    /// Accumulates images pulled from a single source PDF.
    final class ImageCollector {
        let stem: String
        let destDir: URL
        var pageIndex = 0
        private var counter = 0
        private(set) var written: [URL] = []

        init(stem: String, destDir: URL) {
            self.stem = stem
            self.destDir = destDir
        }

        /// Decode one image XObject stream and write it out in the most faithful
        /// available format. No-op if the stream can't be reconstructed.
        func extract(stream: CGPDFStreamRef, dict: CGPDFDictionaryRef) {
            var format = CGPDFDataFormat.raw
            guard let cfData = CGPDFStreamCopyData(stream, &format) else { return }
            let data = cfData as Data
            let nameBase = "\(stem) p\(pageIndex) img\(counter + 1)"
            switch format {
            case .jpegEncoded:
                write(data, name: nameBase + ".jpg")
            case .JPEG2000:
                write(data, name: nameBase + ".jp2")
            case .raw:
                guard let cg = makeCGImage(rawData: data, dict: dict), let png = pngData(from: cg) else { return }
                write(png, name: nameBase + ".png")
            @unknown default:
                return
            }
        }

        private func write(_ data: Data, name: String) {
            let dest = Staging.uniqueURL(in: destDir, name: name)
            if (try? data.write(to: dest)) != nil {
                counter += 1
                written.append(dest)
            }
        }
    }

    /// Walk a page's `/Resources /XObject` table, handing each image stream to
    /// the collector. Form XObjects are not recursed into.
    private static func extractImages(fromPage pageDict: CGPDFDictionaryRef, into collector: ImageCollector) {
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(pageDict, "Resources", &resources), let resources else { return }
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else { return }
        let info = Unmanaged.passUnretained(collector).toOpaque()
        CGPDFDictionaryApplyFunction(xobjects, xobjectApplier, info)
    }

    /// C-callback shim: resolves the collector from `info`, filters to image
    /// streams, and forwards each one. Must capture nothing (`@convention(c)`).
    private static let xobjectApplier: CGPDFDictionaryApplierFunction = { _, object, info in
        guard let info else { return }
        let collector = Unmanaged<ImageCollector>.fromOpaque(info).takeUnretainedValue()
        var stream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
              let dict = CGPDFStreamGetDictionary(stream) else { return }
        var subtype: UnsafePointer<Int8>?
        guard CGPDFDictionaryGetName(dict, "Subtype", &subtype), let subtype,
              String(cString: subtype) == "Image" else { return }
        collector.extract(stream: stream, dict: dict)
    }

    /// Rebuild a `CGImage` from a decoded image stream's raw samples. Returns
    /// nil for color spaces we don't reconstruct or when the sample buffer is
    /// too small for the declared geometry.
    private static func makeCGImage(rawData: Data, dict: CGPDFDictionaryRef) -> CGImage? {
        var width = 0, height = 0, bpc = 8
        guard CGPDFDictionaryGetInteger(dict, "Width", &width),
              CGPDFDictionaryGetInteger(dict, "Height", &height),
              width > 0, height > 0 else { return nil }
        if !CGPDFDictionaryGetInteger(dict, "BitsPerComponent", &bpc) { bpc = 8 }
        guard let (space, components) = resolveColorSpace(dict) else { return nil }
        let bytesPerRow = (width * components * bpc + 7) / 8
        guard rawData.count >= bytesPerRow * height,
              let provider = CGDataProvider(data: rawData as CFData) else { return nil }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: bpc, bitsPerPixel: bpc * components, bytesPerRow: bytesPerRow,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    /// Resolve an image's `/ColorSpace` to a CG color space and its component
    /// count. Handles the device and ICC/Cal families; returns nil for indexed,
    /// separation, and other spaces we don't rebuild from raw samples.
    private static func resolveColorSpace(_ dict: CGPDFDictionaryRef) -> (CGColorSpace, Int)? {
        var object: CGPDFObjectRef?
        guard CGPDFDictionaryGetObject(dict, "ColorSpace", &object), let object else { return nil }
        switch CGPDFObjectGetType(object) {
        case .name:
            var name: UnsafePointer<Int8>?
            guard CGPDFObjectGetValue(object, .name, &name), let name else { return nil }
            return colorSpace(named: String(cString: name))
        case .array:
            var array: CGPDFArrayRef?
            guard CGPDFObjectGetValue(object, .array, &array), let array, CGPDFArrayGetCount(array) > 0 else { return nil }
            var first: UnsafePointer<Int8>?
            guard CGPDFArrayGetName(array, 0, &first), let first else { return nil }
            switch String(cString: first) {
            case "ICCBased":
                var stream: CGPDFStreamRef?
                guard CGPDFArrayGetStream(array, 1, &stream), let stream,
                      let sdict = CGPDFStreamGetDictionary(stream) else { return nil }
                var n = 0
                guard CGPDFDictionaryGetInteger(sdict, "N", &n) else { return nil }
                return colorSpace(forComponents: n)
            case "CalRGB":  return (CGColorSpaceCreateDeviceRGB(), 3)
            case "CalGray": return (CGColorSpaceCreateDeviceGray(), 1)
            default:        return nil
            }
        default:
            return nil
        }
    }

    private static func colorSpace(named name: String) -> (CGColorSpace, Int)? {
        switch name {
        case "DeviceRGB", "RGB":   return (CGColorSpaceCreateDeviceRGB(), 3)
        case "DeviceGray", "G":    return (CGColorSpaceCreateDeviceGray(), 1)
        case "DeviceCMYK", "CMYK": return (CGColorSpaceCreateDeviceCMYK(), 4)
        default:                   return nil
        }
    }

    private static func colorSpace(forComponents n: Int) -> (CGColorSpace, Int)? {
        switch n {
        case 1: return (CGColorSpaceCreateDeviceGray(), 1)
        case 3: return (CGColorSpaceCreateDeviceRGB(), 3)
        case 4: return (CGColorSpaceCreateDeviceCMYK(), 4)
        default: return nil
        }
    }

    private static func pngData(from image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
