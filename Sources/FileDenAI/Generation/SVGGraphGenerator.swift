import Foundation

/// Parses `<graph>` tags from LLM output and produces self-contained SVG strings.
/// The model outputs only a compact JSON spec; we generate the SVG so the markup
/// is always valid and consistently styled regardless of model quality.
public enum SVGGraphGenerator {

    public enum ChartType: String {
        case bar, pie, line
    }

    public struct Spec {
        public let type: ChartType
        public let title: String
        public let labels: [String]
        public let values: [Double]
        /// Optional explicit Y-axis minimum. When set, the axis floor is this value
        /// instead of 0, making small differences between large values visible.
        public let yMin: Double?
    }

    // MARK: - Parsing

    /// Extract a graph spec from model output. Tries `<graph>{...}</graph>` first,
    /// then falls back to a fenced code block containing graph-shaped JSON (models
    /// sometimes ignore the "no markdown fences" instruction).
    public static func parse(_ text: String) -> Spec? {
        if let spec = parseTag(text)      { return spec }
        if let spec = parseCodeBlock(text) { return spec }
        return nil
    }

    private static func parseTag(_ text: String) -> Spec? {
        guard let tagStart = text.range(of: "<graph>"),
              let tagEnd   = text.range(of: "</graph>"),
              tagStart.upperBound <= tagEnd.lowerBound
        else { return nil }
        let inner = String(text[tagStart.upperBound..<tagEnd.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Try JSON first, then XML child-tag format
        return parseJSON(inner) ?? parseXML(inner)
    }

    /// Fallback for XML-style inner content:
    ///   <type>bar</type><title>…</title><labels>A, B, C</labels><values>1, 2, 3</values>
    private static func parseXML(_ text: String) -> Spec? {
        func inner(_ tag: String) -> String? {
            guard let s = text.range(of: "<\(tag)>"),
                  let e = text.range(of: "</\(tag)>"),
                  s.upperBound <= e.lowerBound
            else { return nil }
            return String(text[s.upperBound..<e.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let typeRaw = inner("type"),
              let type    = ChartType(rawValue: typeRaw),
              let rawLabels = inner("labels"),
              let rawValues = inner("values")
        else { return nil }

        let labels = rawLabels.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let values = rawValues.components(separatedBy: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard labels.count == values.count, !labels.isEmpty else { return nil }
        let yMin = inner("yMin").flatMap { Double($0) }
        return Spec(type: type, title: inner("title") ?? "", labels: labels, values: values, yMin: yMin)
    }

    /// Fallback: detect a ```json ... ``` or ``` ... ``` fence whose content looks
    /// like a graph spec (has "type", "labels", "values" keys).
    private static func parseCodeBlock(_ text: String) -> Spec? {
        // Match opening fence (```json or ```) and closing ```
        let open  = "```"
        guard let fenceStart = text.range(of: open) else { return nil }
        let afterFence = text[fenceStart.upperBound...]
        // Skip optional language tag on the same line
        let jsonStart: String.Index
        if let nl = afterFence.firstIndex(of: "\n") {
            jsonStart = afterFence.index(after: nl)
        } else {
            return nil
        }
        guard let fenceEnd = text.range(of: open, range: jsonStart..<text.endIndex) else { return nil }
        let json = String(text[jsonStart..<fenceEnd.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return parseJSON(json)
    }

    private static func parseJSON(_ json: String) -> Spec? {
        guard let data    = json.data(using: .utf8),
              let obj     = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let typeRaw = obj["type"]   as? String,
              let type    = ChartType(rawValue: typeRaw),
              let labels  = obj["labels"] as? [String],
              let rawVals = obj["values"] as? [Any]
        else { return nil }

        let values = rawVals.compactMap { v -> Double? in
            if let d = v as? Double { return d }
            if let i = v as? Int    { return Double(i) }
            if let s = v as? String { return Double(s) }
            return nil
        }
        guard labels.count == values.count, !labels.isEmpty else { return nil }
        let yMin = obj["yMin"] as? Double ?? (obj["yMin"] as? Int).map { Double($0) }
        return Spec(type: type, title: obj["title"] as? String ?? "", labels: labels, values: values, yMin: yMin)
    }

    /// Remove the graph spec (tag or code block) from model text, leaving only prose.
    public static func stripTag(_ text: String) -> String {
        // Try <graph> tag first
        if let start = text.range(of: "<graph>"),
           let end   = text.range(of: "</graph>") {
            let before = String(text[..<start.lowerBound])
            let after  = String(text[end.upperBound...])
            return (before + after).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Fall back to stripping the code block
        let open = "```"
        if let fenceStart = text.range(of: open),
           let fenceEnd   = text.range(of: open, range: fenceStart.upperBound..<text.endIndex) {
            let before = String(text[..<fenceStart.lowerBound])
            let after  = String(text[fenceEnd.upperBound...])
            return (before + after).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Generation

    public static func generate(_ spec: Spec) -> String {
        switch spec.type {
        case .bar:  return barChart(spec)
        case .pie:  return pieChart(spec)
        case .line: return lineChart(spec)
        }
    }

    // MARK: - Bar chart

    private static func barChart(_ spec: Spec) -> String {
        let w = 540.0, h = 270.0
        let mL = 48.0, mR = 16.0, mT = 38.0, mB = 58.0
        let cW = w - mL - mR, cH = h - mT - mB
        let maxVal = spec.values.max() ?? 1
        let minVal = spec.yMin ?? 0
        let rng    = maxVal - minVal == 0 ? 1 : maxVal - minVal
        let n = spec.values.count
        let gap = cW / Double(n)
        let bW  = gap * 0.58
        let colors = palette(n)
        var bars = ""

        for i in 0..<n {
            let v     = spec.values[i]
            let bH    = ((v - minVal) / rng) * cH
            let x     = mL + Double(i) * gap + (gap - bW) / 2
            let y     = mT + cH - bH
            let color = colors[i % colors.count]
            bars += "<rect x=\"\(f(x))\" y=\"\(f(y))\" width=\"\(f(bW))\" height=\"\(f(bH))\" fill=\"\(color)\" rx=\"3\"/>"
            bars += "<text x=\"\(f(x+bW/2))\" y=\"\(f(y-5))\" text-anchor=\"middle\" font-size=\"11\" fill=\"#555\">\(fv(v))</text>"
            bars += "<text x=\"\(f(x+bW/2))\" y=\"\(f(mT+cH+15))\" text-anchor=\"middle\" font-size=\"11\" fill=\"#666\">\(esc(spec.labels[i]))</text>"
        }

        let step = niceStep(rng, steps: 4)
        var grid = ""
        var tick = (minVal / step).rounded(.up) * step
        while tick <= maxVal * 1.05 {
            let y = mT + cH - ((tick - minVal) / rng) * cH
            grid += "<line x1=\"\(f(mL))\" y1=\"\(f(y))\" x2=\"\(f(mL+cW))\" y2=\"\(f(y))\" stroke=\"#e5e5e5\" stroke-width=\"1\"/>"
            grid += "<text x=\"\(f(mL-6))\" y=\"\(f(y+4))\" text-anchor=\"end\" font-size=\"10\" fill=\"#999\">\(fv(tick))</text>"
            tick += step
        }

        return svg(w, h, """
            <text x="\(f(w/2))" y="24" text-anchor="middle" font-size="13" font-weight="600" fill="#222">\(esc(spec.title))</text>
            \(grid)
            <line x1="\(f(mL))" y1="\(f(mT))" x2="\(f(mL))" y2="\(f(mT+cH))" stroke="#ccc" stroke-width="1"/>
            <line x1="\(f(mL))" y1="\(f(mT+cH))" x2="\(f(mL+cW))" y2="\(f(mT+cH))" stroke="#ccc" stroke-width="1"/>
            \(bars)
            """)
    }

    // MARK: - Pie chart

    private static func pieChart(_ spec: Spec) -> String {
        let w = 500.0, h = 260.0
        let cx = 130.0, cy = h / 2, r = 100.0
        let total = spec.values.reduce(0, +)
        guard total > 0 else { return "" }
        let colors = palette(spec.values.count)
        var slices = "", legend = ""
        var angle = -Double.pi / 2

        for i in 0..<spec.values.count {
            let sweep  = (spec.values[i] / total) * 2 * .pi
            let end    = angle + sweep
            let large  = sweep > .pi ? 1 : 0
            let x1 = cx + r * cos(angle), y1 = cy + r * sin(angle)
            let x2 = cx + r * cos(end),   y2 = cy + r * sin(end)
            let c  = colors[i % colors.count]
            slices += "<path d=\"M\(f(cx)),\(f(cy)) L\(f(x1)),\(f(y1)) A\(f(r)),\(f(r)) 0 \(large),1 \(f(x2)),\(f(y2)) Z\" fill=\"\(c)\" stroke=\"white\" stroke-width=\"1.5\"/>"
            let pct = Int(round((spec.values[i] / total) * 100))
            let ly  = 38.0 + Double(i) * 22.0
            legend += "<rect x=\"270\" y=\"\(f(ly))\" width=\"11\" height=\"11\" fill=\"\(c)\" rx=\"2\"/>"
            legend += "<text x=\"287\" y=\"\(f(ly+9))\" font-size=\"12\" fill=\"#333\">\(esc(spec.labels[i])) (\(pct)%)</text>"
            angle = end
        }

        return svg(w, h, """
            <text x="\(f(w/2))" y="22" text-anchor="middle" font-size="13" font-weight="600" fill="#222">\(esc(spec.title))</text>
            \(slices)
            \(legend)
            """)
    }

    // MARK: - Line chart

    private static func lineChart(_ spec: Spec) -> String {
        let w = 540.0, h = 270.0
        let mL = 48.0, mR = 16.0, mT = 38.0, mB = 58.0
        let cW = w - mL - mR, cH = h - mT - mB
        let maxVal = spec.values.max() ?? 1
        let minVal = spec.yMin ?? min(0, spec.values.min() ?? 0)
        let rng    = maxVal - minVal == 0 ? 1 : maxVal - minVal
        let n      = spec.values.count
        let color  = palette(1)[0]

        func px(_ i: Int)    -> Double { mL + (n == 1 ? cW/2 : Double(i)/Double(n-1) * cW) }
        func py(_ v: Double) -> Double { mT + cH - ((v - minVal) / rng) * cH }

        let pts = (0..<n).map { "\(f(px($0))),\(f(py(spec.values[$0])))" }.joined(separator: " ")
        var dots = "", labels = ""

        for i in 0..<n {
            let v = spec.values[i]
            dots   += "<circle cx=\"\(f(px(i)))\" cy=\"\(f(py(v)))\" r=\"4\" fill=\"\(color)\" stroke=\"white\" stroke-width=\"2\"/>"
            dots   += "<text x=\"\(f(px(i)))\" y=\"\(f(py(v)-10))\" text-anchor=\"middle\" font-size=\"10\" fill=\"#555\">\(fv(v))</text>"
            labels += "<text x=\"\(f(px(i)))\" y=\"\(f(mT+cH+15))\" text-anchor=\"middle\" font-size=\"11\" fill=\"#666\">\(esc(spec.labels[i]))</text>"
        }

        let step = niceStep(rng, steps: 4)
        var grid = ""
        var tick = (minVal / step).rounded(.up) * step
        while tick <= maxVal * 1.05 {
            let y = py(tick)
            grid += "<line x1=\"\(f(mL))\" y1=\"\(f(y))\" x2=\"\(f(mL+cW))\" y2=\"\(f(y))\" stroke=\"#e5e5e5\" stroke-width=\"1\"/>"
            grid += "<text x=\"\(f(mL-6))\" y=\"\(f(y+4))\" text-anchor=\"end\" font-size=\"10\" fill=\"#999\">\(fv(tick))</text>"
            tick += step
        }

        return svg(w, h, """
            <text x="\(f(w/2))" y="24" text-anchor="middle" font-size="13" font-weight="600" fill="#222">\(esc(spec.title))</text>
            \(grid)
            <line x1="\(f(mL))" y1="\(f(mT))" x2="\(f(mL))" y2="\(f(mT+cH))" stroke="#ccc" stroke-width="1"/>
            <line x1="\(f(mL))" y1="\(f(mT+cH))" x2="\(f(mL+cW))" y2="\(f(mT+cH))" stroke="#ccc" stroke-width="1"/>
            <polyline points="\(pts)" fill="none" stroke="\(color)" stroke-width="2.5" stroke-linejoin="round" stroke-linecap="round"/>
            \(dots)
            \(labels)
            """)
    }

    // MARK: - Helpers

    private static func svg(_ w: Double, _ h: Double, _ body: String) -> String {
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(Int(w))\" height=\"\(Int(h))\" viewBox=\"0 0 \(Int(w)) \(Int(h))\">"
        + "<rect width=\"\(Int(w))\" height=\"\(Int(h))\" fill=\"white\" rx=\"6\"/>"
        + body
        + "</svg>"
    }

    private static func palette(_ n: Int) -> [String] {
        let base = ["#4C9BE8", "#F5A623", "#5CB85C", "#BD10E0", "#FF6B6B", "#4ECDC4", "#E67E22", "#9B59B6"]
        return (0..<max(n, 1)).map { base[$0 % base.count] }
    }

    private static func f(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v)
    }

    private static func fv(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    private static func niceStep(_ range: Double, steps: Int) -> Double {
        guard range > 0 else { return 1 }
        let rough = range / Double(steps)
        let mag   = pow(10, floor(log10(rough)))
        for n in [1.0, 2.0, 2.5, 5.0, 10.0] where n * mag >= rough { return n * mag }
        return mag
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
