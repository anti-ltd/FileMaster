import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Context the chat's tools operate within. Extension point for future,
/// app-affecting tools (e.g. "extract images into a new den") — add the callback
/// or data a tool needs here, then register the tool in ``ChatTools/make(context:)``.
public struct ToolContext: Sendable {
    public let documentURLs: [URL]

    public init(documentURLs: [URL]) {
        self.documentURLs = documentURLs
    }
}

#if canImport(FoundationModels)
/// The registry of tools the on-device model may call during a chat. Today: a
/// calculator (small models read numbers but can't reliably add them). Tomorrow:
/// document actions. Keep new tools small, single-purpose, and described clearly.
@available(macOS 26, *)
public enum ChatTools {
    public static func make(context: ToolContext) -> [any Tool] {
        [CalculatorTool(), MinMaxTool()]
    }
}

/// Exact arithmetic for the model, backed by the crash-free ``ArithmeticEvaluator``.
@available(macOS 26, *)
struct CalculatorTool: Tool {
    let name = "calculate"
    let description = "Evaluate an arithmetic expression and return the exact result. Use for any totals, sums, differences, products, percentages, or counts over numbers found in the documents."

    @Generable
    struct Arguments {
        @Guide(description: "An arithmetic expression over the relevant numbers, joined by + - * / ( ). Pass the numbers exactly as they appear in the documents — currency symbols and thousands commas are fine and will be ignored. E.g. '$42,000 + $68,000 + $97,000 + $124,000'.")
        var expression: String
    }

    func call(arguments: Arguments) async throws -> String {
        guard let value = ArithmeticEvaluator.evaluate(arguments.expression) else {
            return "Could not evaluate \"\(arguments.expression)\"."
        }
        let result = value == value.rounded()
            ? String(Int(value))
            : String(format: "%.4f", value)
        return "\(arguments.expression) = \(result)"
    }
}

/// Exact min/max finder for labeled numeric series. Small models reliably mis-rank
/// close values (e.g. 2625 vs 2617) when scanning by eye; this tool is exact.
@available(macOS 26, *)
struct MinMaxTool: Tool {
    let name = "find_min_max"
    let description = "Find the minimum and maximum values in a labeled dataset. Use whenever the user asks for the highest, lowest, best, worst, peak, or bottom value in a list. Pass every label:value pair from the relevant column so no entries are missed."

    @Generable
    struct Arguments {
        @Guide(description: "Comma-separated list of label:value pairs from the document, e.g. \"January:2863, February:2980, March:3445\". Currency symbols and spaces are fine and will be stripped.")
        var entries: String
    }

    func call(arguments: Arguments) async throws -> String {
        let pairs: [(String, Double)] = arguments.entries
            .components(separatedBy: ",")
            .compactMap { entry -> (String, Double)? in
                let parts = entry.components(separatedBy: ":")
                guard parts.count >= 2 else { return nil }
                let label = parts.dropLast().joined(separator: ":").trimmingCharacters(in: .whitespaces)
                let raw   = parts.last!
                    .trimmingCharacters(in: .whitespaces)
                    .filter { $0.isNumber || $0 == "." || $0 == "-" }
                guard let value = Double(raw) else { return nil }
                return (label, value)
            }

        guard let minPair = pairs.min(by: { $0.1 < $1.1 }),
              let maxPair = pairs.max(by: { $0.1 < $1.1 })
        else { return "No valid entries found." }

        return "Minimum: \(minPair.0) (\(minPair.1)). Maximum: \(maxPair.0) (\(maxPair.1))."
    }
}
#endif
