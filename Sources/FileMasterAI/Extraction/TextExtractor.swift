import Foundation
import PDFKit

/// A contiguous run of text pulled from a source file, tagged with where it came
/// from so chunks cut from it can carry precise citation locators.
public struct ExtractedSegment: Sendable {
    public enum Origin: Sendable {
        case pdfPage(index: Int)   // text is one PDF page's text layer (or its OCR)
        case wholeText             // text is the whole file
    }
    public let text: String
    public let origin: Origin

    public init(text: String, origin: Origin) {
        self.text = text
        self.origin = origin
    }
}

/// Pulls plain text out of every format the Ask feature understands — not just
/// PDFs: rich text and Office docs, web/markup, data files, and source code.
/// Best-effort, mirroring `PDFTools`: an unreadable or empty file yields `[]`.
/// PDFs reuse PDFKit and are read **per page** (with Vision OCR for pages that
/// have no text layer) so citations can point at a page.
public enum TextExtractor {
    /// File extensions we can extract text from.
    public static let supportedExtensions: Set<String> = [
        "pdf",
        // rich text & office documents
        "rtf", "docx",
        // web & markup
        "html", "htm", "xml", "md", "markdown",
        // plain text & data
        "txt", "text", "log", "csv", "tsv", "json", "yaml", "yml", "toml", "ini", "conf", "cfg",
        // source code
        "swift", "py", "js", "mjs", "ts", "jsx", "tsx", "java", "kt", "c", "h", "cpp", "hpp",
        "cc", "cs", "go", "rb", "rs", "php", "sh", "bash", "zsh", "sql", "css", "scss", "less",
        "m", "mm", "pl", "lua", "r", "dart", "scala", "groovy",
    ]

    public static func canExtract(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    public static func extract(_ url: URL) -> [ExtractedSegment] {
        switch url.pathExtension.lowercased() {
        case "pdf":
            return extractPDF(url)
        case "html", "htm":
            return wholeText(HTMLTextExtractor.plainText(url))
        case "rtf":
            return wholeText(RTFTextExtractor.plainText(url))
        case "docx":
            return wholeText(DocxTextExtractor.plainText(url))
        default:
            return wholeText(readText(url))
        }
    }

    private static func wholeText(_ text: String?) -> [ExtractedSegment] {
        guard let text, !text.isEmpty else { return [] }
        return [ExtractedSegment(text: text, origin: .wholeText)]
    }

    private static func extractPDF(_ url: URL) -> [ExtractedSegment] {
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else { return [] }
        var segments: [ExtractedSegment] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            if let text = page.string, !text.isEmpty {
                segments.append(ExtractedSegment(text: text, origin: .pdfPage(index: i)))
            } else if let ocr = OCRTextExtractor.recognizeText(in: page), !ocr.isEmpty {
                // No text layer (a scan/image page) → recognize it on-device.
                segments.append(ExtractedSegment(text: ocr, origin: .pdfPage(index: i)))
            }
        }
        return segments
    }

    private static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }
}
