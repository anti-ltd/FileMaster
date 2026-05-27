import Foundation
import AppKit
import PDFKit
import Vision

/// On-device OCR (Apple's Vision framework — offline, independent of Apple
/// Intelligence) for PDF pages that have no text layer, i.e. scans and image-only
/// pages. Lets the Ask feature search documents that aren't "real" text PDFs.
public enum OCRTextExtractor {
    /// Recognize text on a PDF page that lacks a text layer. Nil if nothing found.
    public static func recognizeText(in page: PDFPage) -> String? {
        guard let cgImage = render(page: page, scale: 2) else { return nil }
        return recognize(cgImage)
    }

    /// Recognize text in an image. Exposed for testing.
    public static func recognize(_ cgImage: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let text = lines.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    private static func render(page: PDFPage, scale: CGFloat) -> CGImage? {
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
        let image = page.thumbnail(of: size, for: .cropBox)
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
