import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Metal
import Vision

// MARK: - Edit state

/// The full, value-typed description of every edit applied to one image. Pure
/// data: the engine renders a `CGImage` deterministically from a source image
/// plus one of these, so the model can snapshot it for undo/redo and the same
/// state drives both the live preview (downscaled) and the full-res export.
///
/// Geometry is applied first (flip → rotate → straighten → crop), then tone, then
/// the preset look, then annotations are baked on top at export time.
struct EditState: Equatable {

    // Geometry
    var rotationQuarters: Int = 0      // 90° steps, clockwise
    var straighten: Double = 0         // fine angle, −45…45°
    var flipH = false
    var flipV = false
    /// Crop rectangle in normalised, top-left-origin coordinates of the
    /// straightened image (0…1). `nil` means no crop (full frame).
    var cropRect: CGRect? = nil

    // Tone — all neutral at their defaults, so an untouched state is a no-op.
    var exposure: Double = 0           // EV, −2…2
    var brightness: Double = 0         // −0.5…0.5
    var contrast: Double = 1           // 0.5…1.5 (1 = none)
    var saturation: Double = 1         // 0…2 (1 = none)
    var vibrance: Double = 0           // −1…1
    var warmth: Double = 0             // −1 (cool) … 1 (warm)
    var highlights: Double = 1         // 0…1 (1 = none)
    var shadows: Double = 0            // −1…1 (0 = none)
    var sharpness: Double = 0          // 0…2

    // Look
    var preset: FilterPreset = .none

    // On-device subject isolation (Vision)
    var removeBackground = false

    // Vector markup, baked at export. Coordinates are normalised to the cropped
    // image (0…1, top-left origin) so they track preview ⇄ export scaling.
    var annotations: [Annotation] = []

    /// True when nothing but (possibly) annotations would change the pixels — used
    /// to skip the whole CI pipeline for an untouched image.
    var hasPixelEdits: Bool {
        rotationQuarters != 0 || straighten != 0 || flipH || flipV || cropRect != nil ||
        exposure != 0 || brightness != 0 || contrast != 1 || saturation != 1 ||
        vibrance != 0 || warmth != 0 || highlights != 1 || shadows != 0 ||
        sharpness != 0 || preset != .none || removeBackground
    }

    /// True when the state is completely untouched (so Export/Reset can disable).
    var isPristine: Bool { self == EditState() }
}

// MARK: - Filter presets

/// One-tap looks layered after the manual tone adjustments. Backed by the cheap,
/// GPU-resident `CIPhotoEffect*`/`CISepiaTone` filters so they stay real-time.
enum FilterPreset: String, CaseIterable, Equatable, Identifiable {
    case none, mono, noir, fade, chrome, instant, process, transfer, sepia

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none:     return "Original"
        case .mono:     return "Mono"
        case .noir:     return "Noir"
        case .fade:     return "Fade"
        case .chrome:   return "Chrome"
        case .instant:  return "Instant"
        case .process:  return "Process"
        case .transfer: return "Transfer"
        case .sepia:    return "Sepia"
        }
    }

    /// The CIFilter name, or nil for `.none`.
    var ciFilterName: String? {
        switch self {
        case .none:     return nil
        case .mono:     return "CIPhotoEffectMono"
        case .noir:     return "CIPhotoEffectNoir"
        case .fade:     return "CIPhotoEffectFade"
        case .chrome:   return "CIPhotoEffectChrome"
        case .instant:  return "CIPhotoEffectInstant"
        case .process:  return "CIPhotoEffectProcess"
        case .transfer: return "CIPhotoEffectTransfer"
        case .sepia:    return "CISepiaTone"
        }
    }

    var params: [String: Any] {
        self == .sepia ? [kCIInputIntensityKey: 1.0] : [:]
    }
}

// MARK: - Annotations

/// An sRGB colour stored as plain components so `Annotation` stays `Equatable`
/// and value-typed (NSColor isn't a clean fit for a snapshot-able state).
struct RGBAColor: Equatable, Hashable {
    var r, g, b, a: Double
    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    static let red    = RGBAColor(0.93, 0.23, 0.21)
    static let yellow = RGBAColor(1.0, 0.80, 0.0)
    static let green  = RGBAColor(0.20, 0.78, 0.35)
    static let blue   = RGBAColor(0.0, 0.48, 1.0)
    static let white  = RGBAColor(1, 1, 1)
    static let black  = RGBAColor(0, 0, 0)
}

/// A single vector markup element. All geometry is normalised (0…1, top-left
/// origin) to the cropped image, so it renders identically in the small preview
/// and at full export resolution.
struct Annotation: Identifiable, Equatable {
    let id: UUID
    var kind: Kind
    var color: RGBAColor
    /// Stroke width as a fraction of the image's longest side (so it scales).
    var width: Double

    init(id: UUID = UUID(), kind: Kind, color: RGBAColor, width: Double = 0.006) {
        self.id = id; self.kind = kind; self.color = color; self.width = width
    }

    enum Kind: Equatable {
        case freehand([CGPoint])
        case line(CGPoint, CGPoint)
        case arrow(CGPoint, CGPoint)
        case rect(CGRect)
        case ellipse(CGRect)
        case highlight(CGRect)       // translucent fill
        case text(String, CGPoint, Double)   // string, top-left, fontFraction
        case redactBlackout(CGRect)
        case redactPixelate(CGRect)
    }

    /// Redactions are baked into the pixels (not just drawn), so they're handled
    /// in the CI pipeline rather than the vector overlay pass.
    var isRedaction: Bool {
        switch kind {
        case .redactBlackout, .redactPixelate: return true
        default: return false
        }
    }
}

// MARK: - Engine

/// Stateless renderer: turns a source `CIImage` + an `EditState` into pixels,
/// entirely on the GPU via a Metal-backed `CIContext`. Shared and thread-safe —
/// the model renders previews from a background task and exports full-res off the
/// main actor through the same instance.
final class ImageEditEngine {
    static let shared = ImageEditEngine()

    let context: CIContext
    private let workingColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private init() {
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: [
                .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                .cacheIntermediates: false,
            ])
        } else {
            context = CIContext(options: [.useSoftwareRenderer: false])
        }
    }

    // MARK: Loading

    /// Load a file as a CIImage with its EXIF orientation already applied, so the
    /// rest of the pipeline works in upright pixel space.
    static func loadOriented(_ url: URL) -> CIImage? {
        CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
            ?? CIImage(contentsOf: url)
    }

    // MARK: Pipeline

    /// The composed pixel image for `state` (geometry → tone → look → baked
    /// redactions), excluding vector annotations. `bgRemoved` is the cached
    /// subject-isolated source, passed in when `state.removeBackground` is on.
    func composed(source: CIImage, bgRemoved: CIImage?, state: EditState) -> CIImage {
        var img = (state.removeBackground ? (bgRemoved ?? source) : source)
        img = geometry(img, state)
        img = tone(img, state)
        if let name = state.preset.ciFilterName {
            img = img.applyingFilter(name, parameters: state.preset.params)
        }
        img = bakeRedactions(img, state.annotations)
        return img
    }

    /// Render `image` to a CGImage, optionally fitting the longest side to
    /// `maxDimension` pixels (nil = native resolution, used for export).
    func cgImage(_ image: CIImage, maxDimension: CGFloat? = nil) -> CGImage? {
        var img = image
        let extent = img.extent
        guard extent.width >= 1, extent.height >= 1, extent.isInfinite == false else { return nil }
        if let maxDim = maxDimension, max(extent.width, extent.height) > maxDim {
            let scale = maxDim / max(extent.width, extent.height)
            img = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let target = img.extent.integral
        return context.createCGImage(img, from: target, format: .RGBA8, colorSpace: workingColorSpace)
    }

    // MARK: Geometry

    private func geometry(_ image: CIImage, _ s: EditState) -> CIImage {
        var img = image
        if s.flipH { img = reorigin(img.transformed(by: CGAffineTransform(scaleX: -1, y: 1))) }
        if s.flipV { img = reorigin(img.transformed(by: CGAffineTransform(scaleX: 1, y: -1))) }
        if s.rotationQuarters % 4 != 0 {
            let angle = -CGFloat(s.rotationQuarters) * .pi / 2
            img = reorigin(img.transformed(by: CGAffineTransform(rotationAngle: angle)))
        }
        if abs(s.straighten) > 0.001 {
            let angle = CGFloat(s.straighten) * .pi / 180
            let pre = img.extent
            img = reorigin(img.transformed(by: CGAffineTransform(rotationAngle: angle)))
            // Trim the transparent wedges by cropping to the largest upright rect
            // that fits inside the rotated frame, centred.
            let inset = Self.largestInscribedRect(width: pre.width, height: pre.height, angle: angle)
            let e = img.extent
            let rect = CGRect(x: e.midX - inset.width / 2, y: e.midY - inset.height / 2,
                              width: inset.width, height: inset.height)
            img = reorigin(img.cropped(to: rect))
        }
        if let r = s.cropRect {
            let e = img.extent
            // Normalised top-left → CI bottom-left rect.
            let rect = CGRect(x: e.minX + r.minX * e.width,
                              y: e.minY + (1 - r.maxY) * e.height,
                              width: r.width * e.width,
                              height: r.height * e.height).integral
            img = reorigin(img.cropped(to: rect))
        }
        return img
    }

    /// Largest axis-aligned rectangle that fits inside a `width`×`height` box
    /// rotated by `angle` (radians). Used to auto-trim straighten artefacts.
    static func largestInscribedRect(width w: CGFloat, height h: CGFloat, angle: CGFloat) -> CGSize {
        let a = abs(angle)
        guard a > 0.0001 else { return CGSize(width: w, height: h) }
        let sinA = abs(sin(a)), cosA = abs(cos(a))
        let (longSide, shortSide) = w >= h ? (w, h) : (h, w)
        if shortSide <= 2 * sinA * cosA * longSide || abs(sinA - cosA) < 1e-6 {
            let x = 0.5 * shortSide
            let (wr, hr) = w >= h ? (x / sinA, x / cosA) : (x / cosA, x / sinA)
            return CGSize(width: wr, height: hr)
        }
        let cos2 = cosA * cosA - sinA * sinA
        let wr = (w * cosA - h * sinA) / cos2
        let hr = (h * cosA - w * sinA) / cos2
        return CGSize(width: max(wr, 1), height: max(hr, 1))
    }

    private func reorigin(_ img: CIImage) -> CIImage {
        let e = img.extent
        guard e.origin != .zero else { return img }
        return img.transformed(by: CGAffineTransform(translationX: -e.origin.x, y: -e.origin.y))
    }

    // MARK: Tone

    private func tone(_ image: CIImage, _ s: EditState) -> CIImage {
        var img = image
        if s.exposure != 0 {
            img = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: s.exposure])
        }
        if s.brightness != 0 || s.contrast != 1 || s.saturation != 1 {
            img = img.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: s.brightness,
                kCIInputContrastKey: s.contrast,
                kCIInputSaturationKey: s.saturation,
            ])
        }
        if s.vibrance != 0 {
            img = img.applyingFilter("CIVibrance", parameters: ["inputAmount": s.vibrance])
        }
        if s.warmth != 0 {
            img = img.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 6500 + s.warmth * 2800, y: 0),
            ])
        }
        if s.highlights != 1 || s.shadows != 0 {
            img = img.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": s.highlights,
                "inputShadowAmount": s.shadows,
            ])
        }
        if s.sharpness != 0 {
            img = img.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: s.sharpness])
                .cropped(to: img.extent)
        }
        return img
    }

    // MARK: Redactions (baked into pixels)

    /// Blackout/pixelate redactions must alter the actual pixels, so they're part
    /// of the CI pipeline rather than the removable vector overlay.
    private func bakeRedactions(_ image: CIImage, _ annotations: [Annotation]) -> CIImage {
        var img = image
        let e = img.extent
        for a in annotations where a.isRedaction {
            switch a.kind {
            case .redactBlackout(let r):
                let rect = ciRect(r, in: e)
                let black = CIImage(color: .black).cropped(to: rect)
                img = black.composited(over: img)
            case .redactPixelate(let r):
                let rect = ciRect(r, in: e)
                let scale = max(min(rect.width, rect.height) / 12, 6)
                let pixelated = img
                    .applyingFilter("CIPixellate", parameters: [
                        kCIInputScaleKey: scale,
                        kCIInputCenterKey: CIVector(x: rect.midX, y: rect.midY),
                    ])
                    .cropped(to: rect)
                img = pixelated.composited(over: img)
            default: break
            }
        }
        return img
    }

    private func ciRect(_ norm: CGRect, in extent: CGRect) -> CGRect {
        CGRect(x: extent.minX + norm.minX * extent.width,
               y: extent.minY + (1 - norm.maxY) * extent.height,
               width: norm.width * extent.width,
               height: norm.height * extent.height)
    }

    // MARK: Background removal (Vision, on-device)

    /// Isolate the foreground subject onto a transparent background. Heavier than
    /// the rest of the pipeline, so the model computes it once and caches it.
    /// Returns nil if no subject was found or the OS lacks the API.
    func removeBackground(from source: CIImage) -> CIImage? {
        guard #available(macOS 14.0, *) else { return nil }
        let handler = VNImageRequestHandler(ciImage: source, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        do {
            try handler.perform([request])
            guard let result = request.results?.first else { return nil }
            let maskBuffer = try result.generateScaledMaskForImage(
                forInstances: result.allInstances, from: handler)
            let mask = CIImage(cvPixelBuffer: maskBuffer)
            let scaled = mask.transformed(by: CGAffineTransform(
                scaleX: source.extent.width / mask.extent.width,
                y: source.extent.height / mask.extent.height))
            return source.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputMaskImageKey: scaled,
                kCIInputBackgroundImageKey: CIImage.empty(),
            ]).cropped(to: source.extent)
        } catch {
            return nil
        }
    }
}
