import Foundation

/// Scans retrieved text chunks for labelled numeric tables (e.g. month → currency
/// or plain number) and prepends a compact computed-facts block to the context
/// string passed to the LLM. This prevents the model from having to rank raw
/// numbers itself — a source of off-by-one errors when values are close together.
enum TableDataAnnotator {

    // MARK: - Public

    /// Return `context` with a "Computed facts" header prepended whenever a
    /// labelled numeric table is detected inside it.
    static func annotate(_ context: String) -> String {
        guard let facts = computedFacts(from: context), !facts.isEmpty else { return context }
        return "Computed facts derived from the data below:\n\(facts)\n\n\(context)"
    }

    // MARK: - Detection & extraction

    private static func computedFacts(from text: String) -> String? {
        let rows = extractLabelledRows(from: text)
        guard rows.count >= 3 else { return nil }

        let values = rows.map(\.value)
        guard let minVal = values.min(), let maxVal = values.max() else { return nil }

        let minRows = rows.filter { $0.value == minVal }
        let maxRows = rows.filter { $0.value == maxVal }

        var lines: [String] = []
        lines.append("- Lowest value: \(minRows.map(\.label).joined(separator: ", ")) (\(format(minVal, currency: rows.first?.currency)))")
        lines.append("- Highest value: \(maxRows.map(\.label).joined(separator: ", ")) (\(format(maxVal, currency: rows.first?.currency)))")

        let avg = values.reduce(0, +) / Double(values.count)
        lines.append("- Average: \(format(avg, currency: rows.first?.currency))")

        return lines.joined(separator: "\n")
    }

    // MARK: - Row parsing

    private struct LabelledRow {
        let label: String
        let value: Double
        let currency: String?
    }

    /// Extract (label, numeric value) pairs from lines like:
    ///   "January  £2,863.00"   "Q1  1,234.5"   "Total revenue  $9,000"
    /// A table is considered valid only when ≥3 non-header rows are found.
    private static func extractLabelledRows(from text: String) -> [LabelledRow] {
        // Matches: <label text>  <optional currency symbol> <digits with optional commas/dots>
        let pattern = #"^([A-Za-z][A-Za-z0-9 \-]*)[\t ]{2,}([£$€¥₹]?)[\t ]*([0-9]{1,3}(?:,[0-9]{3})*(?:\.[0-9]+)?|[0-9]+(?:\.[0-9]+)?)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else { return [] }

        var rows: [LabelledRow] = []
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        for match in matches {
            guard match.numberOfRanges == 4 else { continue }
            let label    = nsText.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let currency = nsText.substring(with: match.range(at: 2))
            let numStr   = nsText.substring(with: match.range(at: 3)).replacingOccurrences(of: ",", with: "")
            guard let value = Double(numStr), value > 0 else { continue }
            // Skip header-like rows (all caps labels like "MONTH", "TOTAL")
            guard label != label.uppercased() else { continue }
            rows.append(LabelledRow(label: label, value: value, currency: currency.isEmpty ? nil : currency))
        }
        return rows
    }

    // MARK: - Formatting

    private static func format(_ value: Double, currency: String?) -> String {
        let prefix = currency ?? ""
        if value == value.rounded() {
            return "\(prefix)\(Int(value))"
        }
        return String(format: "\(prefix)%.2f", value)
    }
}
