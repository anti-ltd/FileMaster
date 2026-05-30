import AppKit
import AVFoundation
import CoreImage
import CoreVideo
import ImageIO

/// Native image format conversion via ImageIO.
///
/// Lossless targets (PNG, TIFF) are bit-exact; lossy targets (JPEG, HEIC, WebP,
/// AVIF) are written at a visually-lossless quality. Orientation and the
/// embedded colour profile ride along so the converted file looks identical to
/// the original. WebP/AVIF only appear when the OS can actually encode them
/// (see ``canEncode``). File-in / file-out, like `PDFTools`.
enum ImageConvert {

    /// Common still-image containers. Keep the menu list (in `ActionsMenu`) in
    /// sync with these cases.
    enum Format: CaseIterable {
        case jpeg, heic, png, tiff, webp, avif

        var label: String {
            switch self {
            case .jpeg: return "JPEG"
            case .heic: return "HEIC"
            case .png:  return "PNG"
            case .tiff: return "TIFF"
            case .webp: return "WebP"
            case .avif: return "AVIF"
            }
        }

        var ext: String {
            switch self {
            case .jpeg: return "jpg"
            case .heic: return "heic"
            case .png:  return "png"
            case .tiff: return "tiff"
            case .webp: return "webp"
            case .avif: return "avif"
            }
        }

        /// System type identifier used as the ImageIO destination type.
        var typeID: String {
            switch self {
            case .jpeg: return "public.jpeg"
            case .heic: return "public.heic"
            case .png:  return "public.png"
            case .tiff: return "public.tiff"
            case .webp: return "org.webmproject.webp"
            case .avif: return "public.avif"
            }
        }

        /// Quality near 1.0 — small enough to compress, high enough to be
        /// indistinguishable from the source. Ignored by the lossless formats.
        var isLossy: Bool {
            switch self {
            case .png, .tiff: return false
            case .jpeg, .heic, .webp, .avif: return true
            }
        }

        /// True if `url` is already this format, so the menu can hide a no-op.
        func matches(_ url: URL) -> Bool {
            let e = url.pathExtension.lowercased()
            switch self {
            case .jpeg: return e == "jpg" || e == "jpeg"
            case .heic: return e == "heic" || e == "heif"
            case .png:  return e == "png"
            case .tiff: return e == "tiff" || e == "tif"
            case .webp: return e == "webp"
            case .avif: return e == "avif"
            }
        }
    }

    static let imageExtensions = ["png", "jpg", "jpeg", "gif", "heic", "heif", "tiff", "tif", "bmp", "webp", "avif"]

    static func isImage(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    /// SVG is a *vector* image: editable in the vector editor, but deliberately
    /// kept out of `isImage`/`imageExtensions` so the raster tools (resize, upscale,
    /// compress, convert) never offer themselves for a file they can't process.
    static func isSVG(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "svg"
    }

    /// Anything the editor can open — a raster image (raster editor) or an SVG
    /// (vector editor). Used to gate "Edit…" and the den's editor tab routing.
    static func isEditable(_ url: URL) -> Bool {
        isImage(url) || isSVG(url)
    }

    /// Type identifiers ImageIO can write on this machine. Used to gate
    /// WebP/AVIF, whose encoders aren't present on every macOS version.
    private static let encodableTypeIDs: Set<String> = {
        let ids = (CGImageDestinationCopyTypeIdentifiers() as NSArray).compactMap { $0 as? String }
        return Set(ids)
    }()

    static func canEncode(_ format: Format) -> Bool {
        encodableTypeIDs.contains(format.typeID)
    }

    static func convert(_ urls: [URL], to format: Format) -> [URL] {
        let dir = Staging.dir("IMG")
        var out: [URL] = []
        for url in urls {
            if let dest = convertOne(url, to: format, in: dir) { out.append(dest) }
        }
        return out
    }

    private static func convertOne(_ url: URL, to format: Format, in dir: URL) -> URL? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        let dest = Staging.uniqueURL(in: dir, name: url.deletingPathExtension().lastPathComponent + "." + format.ext)
        guard let destination = CGImageDestinationCreateWithURL(dest as CFURL, format.typeID as CFString, 1, nil) else { return nil }

        var options: [CFString: Any] = [:]
        if format.isLossy { options[kCGImageDestinationLossyCompressionQuality] = 0.92 }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        if let orientation = props?[kCGImagePropertyOrientation] {
            options[kCGImagePropertyOrientation] = orientation
        }

        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        return CGImageDestinationFinalize(destination) ? dest : nil
    }
}

/// Shrink an image, entirely on-device. Built for the "this upload form caps
/// photos at 5 MB" case (passport, ID, visa) and for general "make it smaller"
/// — without handing a sensitive original to some random web compressor.
///
/// Driven by ``Options``, which the compression panel binds its sliders to:
/// pick a target format, scale the pixels, and either dial the quality directly
/// or pin a maximum file size (quality is then binary-searched to fit, keeping
/// as much detail as the budget allows). Source orientation rides along.
/// File-in / file-out, like `ImageConvert`.
enum ImageCompress {

    /// Everything the panel can tweak. `targetBytes == nil` → quality-driven;
    /// otherwise quality is searched to land just under the cap.
    struct Options: Equatable {
        var format: ImageConvert.Format = .jpeg
        /// Fraction of each original dimension, 0…1 (1 = original size).
        var scale: Double = 1.0
        /// Lossy quality 0…1 (ignored for lossless formats and when capping).
        var quality: Double = 0.8
        /// Hard ceiling on the output size in bytes, or nil for quality-driven.
        var targetBytes: Int? = nil
    }

    /// A single image's source pixel size and byte size, for the panel header.
    static func sourceInfo(_ url: URL) -> (pixels: CGSize, bytes: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        let w = (props[kCGImagePropertyPixelWidth] as? Double) ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? Double) ?? 0
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return (CGSize(width: w, height: h), bytes)
    }

    /// Encode `urls` with `options`, staged into a fresh den. File-in / file-out.
    static func process(_ urls: [URL], options: Options) -> [URL] {
        let dir = Staging.dir("IMG")
        var out: [URL] = []
        for url in urls {
            guard let (data, _) = render(url, options: options) else { continue }
            let dest = Staging.uniqueURL(
                in: dir,
                name: url.deletingPathExtension().lastPathComponent + " compressed." + options.format.ext)
            if (try? data.write(to: dest)) != nil { out.append(dest) }
        }
        return out
    }

    /// Quick estimate for the panel's live readout: resulting bytes and output
    /// pixel size for one image, without writing anything to disk.
    static func estimate(_ url: URL, options: Options) -> (bytes: Int, pixels: CGSize)? {
        guard let (data, pixels) = render(url, options: options) else { return nil }
        return (data.count, pixels)
    }

    // MARK: - Core

    /// Load → scale → encode one image to in-memory data. Shared by `process`
    /// (writes the data) and `estimate` (measures it).
    private static func render(_ url: URL, options: Options) -> (data: Data, pixels: CGSize)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let original = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let orientation = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyOrientation]

        let factor = min(max(options.scale, 0.01), 1.0)
        let image = factor < 0.999 ? (scaled(original, by: factor) ?? original) : original
        let pixels = CGSize(width: image.width, height: image.height)

        let data: Data?
        if let cap = options.targetBytes, options.format.isLossy {
            data = bestUnder(cap, image: image, format: options.format, orientation: orientation)
                ?? encode(image, format: options.format, quality: 0.0, orientation: orientation)
        } else {
            data = encode(image, format: options.format, quality: options.quality, orientation: orientation)
        }
        guard let data else { return nil }
        return (data, pixels)
    }

    /// Highest-quality encoding of `image` that fits `maxBytes`, binary-searched.
    /// nil only if encoding itself fails; an over-budget low-quality result is
    /// still returned by the caller as a best effort.
    private static func bestUnder(_ maxBytes: Int, image: CGImage,
                                  format: ImageConvert.Format, orientation: Any?) -> Data? {
        if let high = encode(image, format: format, quality: 0.95, orientation: orientation),
           high.count <= maxBytes { return high }
        var lo = 0.0, hi = 0.95
        var best: Data?
        for _ in 0..<9 {
            let mid = (lo + hi) / 2
            guard let data = encode(image, format: format, quality: mid, orientation: orientation) else { break }
            if data.count <= maxBytes { best = data; lo = mid } else { hi = mid }
        }
        return best
    }

    private static func encode(_ image: CGImage, format: ImageConvert.Format,
                               quality: Double, orientation: Any?) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, format.typeID as CFString, 1, nil) else { return nil }
        var options: [CFString: Any] = [:]
        if format.isLossy { options[kCGImageDestinationLossyCompressionQuality] = quality }
        if let orientation { options[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        return CGImageDestinationFinalize(dest) ? (data as Data) : nil
    }

    private static func scaled(_ image: CGImage, by factor: Double) -> CGImage? {
        let w = Int((Double(image.width) * factor).rounded())
        let h = Int((Double(image.height) * factor).rounded())
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}

/// Resize images on-device, preserving aspect ratio and the original format.
///
/// The panel offers four ways to specify the target, mirroring the standalone
/// "resize" utilities people reach for: pin the **width**, pin the **height**,
/// scale by **percent**, or fit the **longest side** to a box (handy for a batch
/// of mixed portrait/landscape shots). Output keeps the source's format when
/// this OS can encode it, falling back to PNG. File-in / file-out, like the rest.
enum ImageResize {

    /// How the target dimensions are derived; the off-axis follows to keep aspect.
    enum Mode: Hashable {
        case width(Int)       // exact pixel width
        case height(Int)      // exact pixel height
        case percent(Double)  // uniform scale, 0…∞ (100 = original)
        case longest(Int)     // longest side fits this many pixels
    }

    /// Target pixel size for `original` under `mode`, aspect preserved. Used both
    /// to render and to drive the panel's live readout. Never returns < 1px.
    static func target(for original: CGSize, mode: Mode) -> CGSize {
        let ow = max(original.width, 1), oh = max(original.height, 1)
        let factor: CGFloat
        switch mode {
        case .width(let w):   factor = CGFloat(max(w, 1)) / ow
        case .height(let h):  factor = CGFloat(max(h, 1)) / oh
        case .percent(let p): factor = CGFloat(max(p, 0.01)) / 100
        case .longest(let m): factor = CGFloat(max(m, 1)) / max(ow, oh)
        }
        return CGSize(width: max((ow * factor).rounded(), 1),
                      height: max((oh * factor).rounded(), 1))
    }

    static func process(_ urls: [URL], mode: Mode) -> [URL] {
        let dir = Staging.dir("IMG")
        var out: [URL] = []
        for url in urls {
            guard let (data, size, format) = render(url, mode: mode) else { continue }
            let name = "\(url.deletingPathExtension().lastPathComponent) "
                + "\(Int(size.width))×\(Int(size.height)).\(format.ext)"
            let dest = Staging.uniqueURL(in: dir, name: name)
            if (try? data.write(to: dest)) != nil { out.append(dest) }
        }
        return out
    }

    private static func render(_ url: URL, mode: Mode) -> (data: Data, size: CGSize, format: ImageConvert.Format)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let original = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let orientation = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyOrientation]

        let size = target(for: CGSize(width: original.width, height: original.height), mode: mode)
        guard let scaled = resample(original, to: size) else { return nil }
        let format = outputFormat(for: url)

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, format.typeID as CFString, 1, nil) else { return nil }
        var options: [CFString: Any] = [:]
        if format.isLossy { options[kCGImageDestinationLossyCompressionQuality] = 0.92 }
        if let orientation { options[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(dest, scaled, options as CFDictionary)
        return CGImageDestinationFinalize(dest) ? (data as Data, size, format) : nil
    }

    /// Keep the source format if ImageIO can write it; otherwise PNG (lossless,
    /// universal) so odd inputs like BMP/GIF still produce a usable file.
    private static func outputFormat(for url: URL) -> ImageConvert.Format {
        for f in ImageConvert.Format.allCases where f.matches(url) && ImageConvert.canEncode(f) {
            return f
        }
        return .png
    }

    private static func resample(_ image: CGImage, to size: CGSize) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}

/// Enlarge images on-device with Lanczos resampling, preserving aspect ratio.
///
/// This is the inverse of `ImageResize`'s downscale case, but built for *growing*
/// pixels: it uses Core Image's `CILanczosScaleTransform` rather than a Core
/// Graphics redraw, because Lanczos keeps far more edge detail when scaling up
/// (a bicubic `CGContext` blurs noticeably past ~2×). No model, no network —
/// classic resampling, so it can't invent detail, only enlarge cleanly.
///
/// The panel offers three aspect-preserving targets: a **factor** (2×, 4×…), an
/// exact **width**, or fit the **longest** side to a box. Output keeps the
/// source's format by default (PNG fallback) or a chosen one, with a quality
/// dial for lossy targets. File-in / file-out, like the rest.
enum ImageUpscale {

    /// How the (larger) target dimensions are derived; the off-axis follows to
    /// keep aspect. `width`/`longest` below the source still work — they just
    /// downscale — but the panel constrains them to enlargement.
    enum Mode: Hashable {
        case factor(Double)   // multiply both dimensions (1 = original)
        case width(Int)       // exact pixel width
        case longest(Int)     // longest side fits this many pixels
    }

    /// Everything the panel can tweak. `format == nil` keeps the source format.
    struct Options: Equatable {
        var mode: Mode = .factor(2.0)
        /// nil → keep the source format (PNG fallback); else force this format.
        var format: ImageConvert.Format? = nil
        /// Lossy quality 0…1, applied only when the resolved format is lossy.
        var quality: Double = 0.92
    }

    /// Largest output we'll attempt per side — the Core Image / Metal texture
    /// ceiling. Targets beyond this are clamped down, aspect preserved.
    static let maxSide = 16_384

    /// Target pixel size for `original` under `mode`, aspect preserved and capped
    /// at ``maxSide``. Drives both the render and the panel's live readout.
    static func target(for original: CGSize, mode: Mode) -> CGSize {
        let ow = max(original.width, 1), oh = max(original.height, 1)
        let factor: CGFloat
        switch mode {
        case .factor(let f):  factor = CGFloat(max(f, 0.01))
        case .width(let w):   factor = CGFloat(max(w, 1)) / ow
        case .longest(let l): factor = CGFloat(max(l, 1)) / max(ow, oh)
        }
        var w = (ow * factor).rounded(), h = (oh * factor).rounded()
        let over = max(w, h) / CGFloat(maxSide)
        if over > 1 { w = (w / over).rounded(); h = (h / over).rounded() }
        return CGSize(width: max(w, 1), height: max(h, 1))
    }

    /// The format the output will use: an encodable override, else the source
    /// format if this OS can write it, else PNG. Public so the panel can decide
    /// whether to show the quality dial.
    static func outputFormat(for url: URL, override: ImageConvert.Format?) -> ImageConvert.Format {
        if let override, ImageConvert.canEncode(override) { return override }
        for f in ImageConvert.Format.allCases where f.matches(url) && ImageConvert.canEncode(f) {
            return f
        }
        return .png
    }

    static func process(_ urls: [URL], options: Options) -> [URL] {
        let dir = Staging.dir("IMG")
        var out: [URL] = []
        for url in urls {
            guard let (data, size, format) = render(url, options: options) else { continue }
            let name = "\(url.deletingPathExtension().lastPathComponent) "
                + "\(Int(size.width))×\(Int(size.height)).\(format.ext)"
            let dest = Staging.uniqueURL(in: dir, name: name)
            if (try? data.write(to: dest)) != nil { out.append(dest) }
        }
        return out
    }

    // MARK: - Core

    /// Reused across the batch; `CIContext` is expensive to build and safe to
    /// share for rendering on a background queue.
    private static let ciContext = CIContext()

    private static func render(_ url: URL, options: Options) -> (data: Data, size: CGSize, format: ImageConvert.Format)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let original = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let orientation = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyOrientation]

        let size = target(for: CGSize(width: original.width, height: original.height), mode: options.mode)
        guard let scaled = upscale(original, to: size) else { return nil }
        let format = outputFormat(for: url, override: options.format)

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, format.typeID as CFString, 1, nil) else { return nil }
        var props: [CFString: Any] = [:]
        if format.isLossy { props[kCGImageDestinationLossyCompressionQuality] = options.quality }
        if let orientation { props[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(dest, scaled, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? (data as Data, size, format) : nil
    }

    /// Lanczos-scale `image` to exactly `size`. The filter takes a uniform scale
    /// plus an aspect ratio, so we derive both from the (already aspect-correct)
    /// target and crop the output to the integer pixel rect.
    private static func upscale(_ image: CGImage, to size: CGSize) -> CGImage? {
        let input = CIImage(cgImage: image)
        let scale = size.height / CGFloat(max(image.height, 1))
        let aspect = (size.width / CGFloat(max(image.width, 1))) / scale
        guard let filter = CIFilter(name: "CILanczosScaleTransform") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        filter.setValue(aspect, forKey: kCIInputAspectRatioKey)
        guard let output = filter.outputImage else { return nil }
        let rect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)
        return ciContext.createCGImage(output, from: rect, format: .RGBA8, colorSpace: colorSpace)
    }
}

/// Native video conversion via AVFoundation.
///
/// Each function takes one source and reports 0…1 progress as it works (the
/// caller blends this across a batch and into a HUD). Codec changes (→ HEVC)
/// re-encode at the highest-quality preset — visually lossless, ~half the size.
/// Container changes (→ MP4 / MOV) try a stream-copy passthrough first
/// (bit-exact, instant) and only re-encode if the source codec isn't compatible.
/// Also covers GIF↔video and a poster-frame grab. Runs synchronously on a
/// background queue (the caller is already off the main thread).
enum VideoConvert {

    /// Containers AVFoundation can reliably read. Formats it can't open
    /// (mkv, webm) are deliberately excluded so the menu never offers a no-op.
    static let videoExtensions = ["mov", "mp4", "m4v", "avi", "mpg", "mpeg", "m2v", "3gp", "ts", "mts"]

    static func isVideo(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - Codec / container

    static func toHEVC(_ url: URL, progress: @escaping (Double) -> Void) -> [URL] {
        let dir = Staging.dir("VID")
        let out = export(AVURLAsset(url: url),
                         preset: AVAssetExportPresetHEVCHighestQuality,
                         fileType: .mov, ext: "mov",
                         stem: url.deletingPathExtension().lastPathComponent, in: dir, progress: progress)
        return out.map { [$0] } ?? []
    }

    static func toMP4(_ url: URL, progress: @escaping (Double) -> Void) -> [URL] {
        toContainer(url, fileType: .mp4, ext: "mp4", progress: progress)
    }

    static func toMOV(_ url: URL, progress: @escaping (Double) -> Void) -> [URL] {
        toContainer(url, fileType: .mov, ext: "mov", progress: progress)
    }

    static func extractAudio(_ url: URL, progress: @escaping (Double) -> Void) -> [URL] {
        let dir = Staging.dir("VID")
        let out = export(AVURLAsset(url: url),
                         preset: AVAssetExportPresetAppleM4A,
                         fileType: .m4a, ext: "m4a",
                         stem: url.deletingPathExtension().lastPathComponent, in: dir, progress: progress)
        return out.map { [$0] } ?? []
    }

    /// Rewrap into a new container without re-encoding when the codec allows it;
    /// fall back to a highest-quality re-encode otherwise.
    private static func toContainer(_ url: URL, fileType: AVFileType, ext: String,
                                    progress: @escaping (Double) -> Void) -> [URL] {
        let dir = Staging.dir("VID")
        let asset = AVURLAsset(url: url)
        let stem = url.deletingPathExtension().lastPathComponent
        let out = export(asset, preset: AVAssetExportPresetPassthrough, fileType: fileType, ext: ext, stem: stem, in: dir, progress: progress)
            ?? export(asset, preset: AVAssetExportPresetHighestQuality, fileType: fileType, ext: ext, stem: stem, in: dir, progress: progress)
        return out.map { [$0] } ?? []
    }

    /// Run one export session to completion, polling its progress. Returns nil
    /// if the preset can't produce `fileType` for this asset, or if it fails.
    private static func export(_ asset: AVAsset, preset: String,
                               fileType: AVFileType, ext: String,
                               stem: String, in dir: URL,
                               progress: @escaping (Double) -> Void) -> URL? {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset),
              compatibleFileTypes(session).contains(fileType) else { return nil }

        let dest = Staging.uniqueURL(in: dir, name: "\(stem).\(ext)")
        session.outputURL = dest
        session.outputFileType = fileType

        let done = DispatchSemaphore(value: 0)
        session.exportAsynchronously { done.signal() }
        while done.wait(timeout: .now() + 0.1) == .timedOut {
            progress(Double(session.progress))
        }
        progress(1.0)
        return session.status == .completed ? dest : nil
    }

    private static func compatibleFileTypes(_ session: AVAssetExportSession) -> [AVFileType] {
        var types: [AVFileType] = []
        let done = DispatchSemaphore(value: 0)
        session.determineCompatibleFileTypes { types = $0; done.signal() }
        done.wait()
        return types
    }

    // MARK: - GIF ↔ video

    /// Sample the video into an animated GIF (12 fps, capped at 480 px and 900
    /// frames). GIF is inherently 256-colour, so this is not lossless — but it's
    /// the inverse of `gifToVideo` and the most-asked-for clip export.
    static func toGIF(_ url: URL, progress: @escaping (Double) -> Void) -> [URL] {
        let asset = AVURLAsset(url: url)
        let duration = durationSeconds(asset)
        guard duration > 0 else { return [] }

        let fps = 12.0
        let frameCount = max(1, min(Int(duration * fps), 900))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        let tolerance = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let times = (0..<frameCount).map { NSValue(time: CMTime(seconds: Double($0) / fps, preferredTimescale: 600)) }

        let dir = Staging.dir("VID")
        let dest = Staging.uniqueURL(in: dir, name: url.deletingPathExtension().lastPathComponent + ".gif")
        guard let destination = CGImageDestinationCreateWithURL(dest as CFURL, "com.compuserve.gif" as CFString, frameCount, nil) else { return [] }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: 1.0 / fps]] as CFDictionary

        var frames = [CGImage?](repeating: nil, count: frameCount)
        let lock = NSLock()
        var processed = 0
        let done = DispatchSemaphore(value: 0)
        generator.generateCGImagesAsynchronously(forTimes: times) { requested, image, _, result, _ in
            let idx = max(0, min(frameCount - 1, Int((CMTimeGetSeconds(requested) * fps).rounded())))
            lock.lock()
            if result == .succeeded, let image { frames[idx] = image }
            processed += 1
            let count = processed
            lock.unlock()
            progress(Double(count) / Double(frameCount))
            if count == frameCount { done.signal() }
        }
        done.wait()

        var added = 0
        for frame in frames {
            guard let frame else { continue }
            CGImageDestinationAddImage(destination, frame, frameProps)
            added += 1
        }
        guard added > 0, CGImageDestinationFinalize(destination) else { return [] }
        return [dest]
    }

    /// Encode an animated GIF's frames into an H.264 MP4, honouring per-frame
    /// delays. Dimensions are rounded down to even numbers (H.264 requirement).
    static func gifToVideo(_ url: URL, progress: @escaping (Double) -> Void) -> [URL] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
        let count = CGImageSourceGetCount(source)
        guard count > 0, let first = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return [] }
        let width = first.width - first.width % 2
        let height = first.height - first.height % 2
        guard width > 0, height > 0 else { return [] }

        let dir = Staging.dir("VID")
        let dest = Staging.uniqueURL(in: dir, name: url.deletingPathExtension().lastPathComponent + ".mp4")
        guard let writer = try? AVAssetWriter(outputURL: dest, fileType: .mp4) else { return [] }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { return [] }
        writer.add(input)
        guard writer.startWriting() else { return [] }
        writer.startSession(atSourceTime: .zero)

        var elapsed = 0.0
        for i in 0..<count {
            guard let frame = CGImageSourceCreateImageAtIndex(source, i, nil),
                  let buffer = pixelBuffer(from: frame, width: width, height: height) else { continue }
            while !input.isReadyForMoreMediaData { usleep(2000) }
            adaptor.append(buffer, withPresentationTime: CMTime(seconds: elapsed, preferredTimescale: 1000))
            elapsed += gifDelay(source, i)
            progress(Double(i + 1) / Double(count))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        return writer.status == .completed ? [dest] : []
    }

    // MARK: - Poster frame

    /// Grab a representative still (the midpoint, falling back to the first
    /// frame) as a PNG.
    static func posterFrame(_ url: URL, progress: @escaping (Double) -> Void) -> [URL] {
        let asset = AVURLAsset(url: url)
        let duration = durationSeconds(asset)
        progress(0.1)
        let mid = CMTime(seconds: duration > 0 ? duration / 2 : 0, preferredTimescale: 600)
        guard let image = frame(from: asset, at: mid) ?? frame(from: asset, at: .zero) else { return [] }
        progress(0.8)
        let dir = Staging.dir("VID")
        let dest = Staging.uniqueURL(in: dir, name: url.deletingPathExtension().lastPathComponent + " poster.png")
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
              (try? data.write(to: dest)) != nil else { return [] }
        progress(1.0)
        return [dest]
    }

    // MARK: - Helpers

    private static func durationSeconds(_ asset: AVAsset) -> Double {
        var seconds = 0.0
        let done = DispatchSemaphore(value: 0)
        Task {
            seconds = (try? await CMTimeGetSeconds(asset.load(.duration))) ?? 0
            done.signal()
        }
        done.wait()
        return seconds
    }

    private static func frame(from asset: AVAsset, at time: CMTime) -> CGImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        var result: CGImage?
        let done = DispatchSemaphore(value: 0)
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, status, _ in
            if status == .succeeded { result = image }
            done.signal()
        }
        done.wait()
        return result
    }

    private static func pixelBuffer(from image: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        // BGRA + premultiplied-first + little-endian is the canonical, supported
        // combo for drawing a CGImage into a CVPixelBuffer.
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    private static func gifDelay(_ source: CGImageSource, _ index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] else { return 0.1 }
        let delay = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
            ?? (gif[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
        return delay < 0.011 ? 0.1 : delay
    }
}
