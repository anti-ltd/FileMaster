import Foundation

/// Converts HTML to readable plain text **without WebKit**, so it can run on a
/// background thread during batch indexing. (`NSAttributedString`'s HTML importer
/// must run on the main thread and is slow — unworkable for bulk ingest.) This
/// drops `<script>`/`<style>` blocks, turns block-level tags into line breaks,
/// strips remaining tags, decodes the common entities, and collapses whitespace.
/// It is not a full HTML parser, but it produces clean retrieval text.
public enum HTMLTextExtractor {
    public static func plainText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { return nil }
        return strip(html)
    }

    public static func strip(_ html: String) -> String {
        var s = html
        let ci: NSString.CompareOptions = [.regularExpression, .caseInsensitive]
        // Drop script/style blocks including their contents.
        s = s.replacingOccurrences(of: "<(script|style|head)[^>]*>[\\s\\S]*?</\\1\\s*>", with: " ", options: ci)
        // Comments.
        s = s.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: " ", options: ci)
        // Block-level boundaries become newlines so structure survives a little.
        s = s.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: ci)
        s = s.replacingOccurrences(of: "</(p|div|li|ul|ol|h[1-6]|tr|table|section|article|header|footer|blockquote|pre)\\s*>", with: "\n", options: ci)
        // Remove all remaining tags.
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        s = decodeEntities(s)
        return collapseWhitespace(s)
    }

    private static func decodeEntities(_ input: String) -> String {
        var s = input
        let named: [String: String] = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&apos;": "'", "&#39;": "'", "&nbsp;": " ", "&mdash;": "—",
            "&ndash;": "–", "&hellip;": "…", "&copy;": "©", "&reg;": "®",
        ]
        for (k, v) in named { s = s.replacingOccurrences(of: k, with: v, options: .caseInsensitive) }
        // Numeric entities: &#123; and &#x1F;
        s = replaceMatches(in: s, pattern: "&#x([0-9A-Fa-f]+);") { UInt32($0, radix: 16) }
        s = replaceMatches(in: s, pattern: "&#([0-9]+);") { UInt32($0, radix: 10) }
        return s
    }

    private static func replaceMatches(in input: String, pattern: String, scalar: (String) -> UInt32?) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        let ns = input as NSString
        var result = ""
        var last = 0
        regex.enumerateMatches(in: input, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, match.numberOfRanges == 2 else { return }
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let digits = ns.substring(with: match.range(at: 1))
            if let value = scalar(digits), let unicode = Unicode.Scalar(value) {
                result += String(unicode)
            }
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    private static func collapseWhitespace(_ input: String) -> String {
        let lines = input
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // Drop runs of blank lines.
        var out: [String] = []
        for line in lines {
            if line.isEmpty, out.last?.isEmpty == true { continue }
            out.append(line)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
