import Foundation
import AppKit

/// Extracts plain text from RTF using `NSAttributedString`'s RTF importer (which,
/// unlike the HTML importer, doesn't need WebKit/the main thread).
public enum RTFTextExtractor {
    public static func plainText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let attributed = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil)
        else { return nil }
        let text = attributed.string
        return text.isEmpty ? nil : text
    }
}
