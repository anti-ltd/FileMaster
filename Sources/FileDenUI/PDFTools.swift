import AppKit
import CoreGraphics
import PDFKit

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
