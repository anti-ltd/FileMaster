import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - HTTP tool (provider-agnostic)

/// A tool callable from any OpenAI-compatible HTTP endpoint.
/// The handler receives the raw arguments JSON string and returns a result string.
struct HTTPTool: Sendable {
    let name: String
    let description: String
    /// property-name → description (all properties are typed `string`).
    let properties: [String: String]
    let required: [String]
    let handler: @Sendable (String) async -> String

    /// OpenAI-format tool definition suitable for `JSONSerialization`.
    var openAIDefinition: [String: Any] {
        var propsDict: [String: Any] = [:]
        for (propName, propDesc) in properties {
            propsDict[propName] = ["type": "string", "description": propDesc] as [String: Any]
        }
        return [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": [
                    "type": "object",
                    "properties": propsDict,
                    "required": required,
                ] as [String: Any],
            ] as [String: Any],
        ]
    }
}

// MARK: - ToolContext

/// Context the chat's tools operate within. Add callbacks here when a tool needs
/// to trigger an app-level action (e.g. opening a new den with results).
public struct ToolContext: Sendable {
    public let documentURLs: [URL]
    /// Called by PDF tools to run an operation and open results. Returns a
    /// human-readable status string the model echoes back to the user.
    public let pdfAction: (@Sendable (PDFAction) async -> String)?

    public enum PDFAction: Sendable {
        case splitPages([URL])
        case exportPageImages([URL])
        case extractImages([URL])
        case extractText([URL])
    }

    public init(documentURLs: [URL],
                pdfAction: (@Sendable (PDFAction) async -> String)? = nil) {
        self.documentURLs = documentURLs
        self.pdfAction = pdfAction
    }
}

// MARK: - HTTP tool registry

enum ChatTools {
    /// Build the set of HTTP tools for an OpenAI-compatible turn.
    static func makeHTTP(context: ToolContext, arithmetic: Bool, pdfTools: Bool) -> [HTTPTool] {
        var tools: [HTTPTool] = []

        if arithmetic {
            tools.append(HTTPTool(
                name: "calculate",
                description: "Evaluate an arithmetic expression and return the exact result. Use for totals, sums, differences, products, percentages, or counts.",
                properties: [
                    "expression": "An arithmetic expression over the relevant numbers, e.g. '$42,000 + $68,000'. Currency symbols and thousands commas are fine.",
                ],
                required: ["expression"],
                handler: { args in
                    guard
                        let data  = args.data(using: .utf8),
                        let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                        let expr  = json["expression"] as? String,
                        let value = ArithmeticEvaluator.evaluate(expr)
                    else { return "Could not evaluate the expression." }
                    let result = value == value.rounded()
                        ? String(Int(value))
                        : String(format: "%.4f", value)
                    return "\(expr) = \(result)"
                }
            ))

            tools.append(HTTPTool(
                name: "find_min_max",
                description: "Find the minimum and maximum in a labeled dataset. Use for highest, lowest, best, worst, peak, or bottom queries.",
                properties: [
                    "entries": "Comma-separated label:value pairs, e.g. \"January:2863, February:2980\". Currency symbols are fine.",
                ],
                required: ["entries"],
                handler: { args in
                    guard
                        let data    = args.data(using: .utf8),
                        let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                        let entries = json["entries"] as? String
                    else { return "Invalid arguments." }
                    let pairs: [(String, Double)] = entries
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
                    guard
                        let minPair = pairs.min(by: { $0.1 < $1.1 }),
                        let maxPair = pairs.max(by: { $0.1 < $1.1 })
                    else { return "No valid entries found." }
                    return "Minimum: \(minPair.0) (\(minPair.1)). Maximum: \(maxPair.0) (\(maxPair.1))."
                }
            ))
        }

        if pdfTools, let action = context.pdfAction {
            let pdfs = context.documentURLs.filter { $0.pathExtension.lowercased() == "pdf" }
            if !pdfs.isEmpty {
                tools.append(HTTPTool(
                    name: "pdf_split_pages",
                    description: "Split each PDF into individual single-page PDFs and open the results in a new den.",
                    properties: [:], required: [],
                    handler: { _ in await action(.splitPages(pdfs)) }
                ))
                tools.append(HTTPTool(
                    name: "pdf_export_page_images",
                    description: "Rasterize every page of the PDF to PNG images and open the results in a new den.",
                    properties: [:], required: [],
                    handler: { _ in await action(.exportPageImages(pdfs)) }
                ))
                tools.append(HTTPTool(
                    name: "pdf_extract_images",
                    description: "Extract embedded image objects from the PDF and open them in a new den.",
                    properties: [:], required: [],
                    handler: { _ in await action(.extractImages(pdfs)) }
                ))
                tools.append(HTTPTool(
                    name: "pdf_extract_text",
                    description: "Extract the text layer from the PDF into .txt files and open them in a new den.",
                    properties: [:], required: [],
                    handler: { _ in await action(.extractText(pdfs)) }
                ))
            }
        }

        return tools
    }
}

#if canImport(FoundationModels)
/// FoundationModels tool registry for the on-device Apple Intelligence path.
@available(macOS 26, *)
extension ChatTools {
    static func make(context: ToolContext, arithmetic: Bool, pdfTools: Bool) -> [any Tool] {
        var tools: [any Tool] = []
        if arithmetic {
            tools += [CalculatorTool(), MinMaxTool()]
        }
        if pdfTools, context.pdfAction != nil {
            let pdfs = context.documentURLs.filter { $0.pathExtension.lowercased() == "pdf" }
            if !pdfs.isEmpty {
                tools += [
                    PDFSplitTool(context: context),
                    PDFExportImagesTool(context: context),
                    PDFExtractImagesTool(context: context),
                    PDFExtractTextTool(context: context),
                ]
            }
        }
        return tools
    }
}

// MARK: - Arithmetic tools

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

// MARK: - PDF tools

@available(macOS 26, *)
struct PDFSplitTool: Tool {
    let name = "pdf_split_pages"
    let description = "Split each PDF into individual single-page PDFs and open the results in a new den. Use when the user asks to split a PDF, separate its pages, or get individual page files."

    @Generable struct Arguments {}

    let context: ToolContext

    func call(arguments: Arguments) async throws -> String {
        let pdfs = context.documentURLs.filter { $0.pathExtension.lowercased() == "pdf" }
        guard !pdfs.isEmpty, let action = context.pdfAction else {
            return "No PDF documents available."
        }
        return await action(.splitPages(pdfs))
    }
}

@available(macOS 26, *)
struct PDFExportImagesTool: Tool {
    let name = "pdf_export_page_images"
    let description = "Rasterize every page of the PDF to PNG images and open the results in a new den. Use when the user asks to export pages as images, convert pages to PNG, or save PDF pages as pictures."

    @Generable struct Arguments {}

    let context: ToolContext

    func call(arguments: Arguments) async throws -> String {
        let pdfs = context.documentURLs.filter { $0.pathExtension.lowercased() == "pdf" }
        guard !pdfs.isEmpty, let action = context.pdfAction else {
            return "No PDF documents available."
        }
        return await action(.exportPageImages(pdfs))
    }
}

@available(macOS 26, *)
struct PDFExtractImagesTool: Tool {
    let name = "pdf_extract_images"
    let description = "Extract the embedded image objects from the PDF and open them in a new den. Use when the user asks to extract images, pull out pictures, or get the embedded graphics from a PDF."

    @Generable struct Arguments {}

    let context: ToolContext

    func call(arguments: Arguments) async throws -> String {
        let pdfs = context.documentURLs.filter { $0.pathExtension.lowercased() == "pdf" }
        guard !pdfs.isEmpty, let action = context.pdfAction else {
            return "No PDF documents available."
        }
        return await action(.extractImages(pdfs))
    }
}

@available(macOS 26, *)
struct PDFExtractTextTool: Tool {
    let name = "pdf_extract_text"
    let description = "Extract the text layer from the PDF into .txt files and open them in a new den. Use when the user asks to extract text, get the text content, or convert a PDF to plain text."

    @Generable struct Arguments {}

    let context: ToolContext

    func call(arguments: Arguments) async throws -> String {
        let pdfs = context.documentURLs.filter { $0.pathExtension.lowercased() == "pdf" }
        guard !pdfs.isEmpty, let action = context.pdfAction else {
            return "No PDF documents available."
        }
        return await action(.extractText(pdfs))
    }
}
#endif
