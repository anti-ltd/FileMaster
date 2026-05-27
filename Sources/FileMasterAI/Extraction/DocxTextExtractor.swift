import Foundation

/// Extracts the body text from a `.docx` (a zip of XML). Reads `word/document.xml`
/// via `unzip -p` (offline, already used elsewhere in the app for archives), then
/// converts the WordprocessingML to plain text: paragraph/break tags become line
/// breaks, all other tags are stripped, entities decoded.
public enum DocxTextExtractor {
    public static func plainText(_ url: URL) -> String? {
        guard let xml = unzipEntry(archive: url, entry: "word/document.xml") else { return nil }
        let text = stripWordML(xml)
        return text.isEmpty ? nil : text
    }

    private static func unzipEntry(archive: URL, entry: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        task.arguments = ["-p", archive.path, entry]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()
        do { try task.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func stripWordML(_ xml: String) -> String {
        var s = xml
        let ci: NSString.CompareOptions = [.regularExpression, .caseInsensitive]
        s = s.replacingOccurrences(of: "</w:p>", with: "\n", options: ci)
        s = s.replacingOccurrences(of: "<w:br[^>]*>", with: "\n", options: ci)
        s = s.replacingOccurrences(of: "<w:tab[^>]*>", with: "\t", options: ci)
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
        let lines = s.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var out: [String] = []
        for line in lines {
            if line.isEmpty, out.last?.isEmpty == true { continue }
            out.append(line)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
