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
        [CalculatorTool()]
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
#endif
