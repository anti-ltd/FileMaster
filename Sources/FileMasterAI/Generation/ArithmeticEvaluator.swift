import Foundation

/// A tiny, crash-free arithmetic evaluator for `+ - * /` and parentheses over
/// decimal numbers (thousands separators and currency symbols tolerated). Backs
/// the LLM's calculator tool so totals/sums are computed exactly instead of
/// guessed by the model. Tolerating "$42,000" matters: it lets the model pass the
/// numbers exactly as they appear in the documents, so it doesn't shy away from a
/// currency-formatted column toward a plainer (wrong) one.
///
/// Implemented as a small recursive-descent parser (not `NSExpression`, which can
/// raise uncatchable Obj-C exceptions on malformed input). Returns nil for
/// anything it can't parse.
public enum ArithmeticEvaluator {
    public static func evaluate(_ input: String) -> Double? {
        var parser = Parser(input)
        guard let value = parser.parseExpression(), parser.atEnd else { return nil }
        return value
    }

    private struct Parser {
        private let s: [Character]
        private var i = 0

        init(_ string: String) { s = Array(string) }

        var atEnd: Bool { mutatingSkipSpacesAtEnd() }

        // `atEnd` needs to skip trailing spaces; do it without mutating `self` semantics issues.
        private func mutatingSkipSpacesAtEnd() -> Bool {
            var j = i
            while j < s.count && s[j] == " " { j += 1 }
            return j >= s.count
        }

        private mutating func peek() -> Character? {
            while i < s.count && s[i] == " " { i += 1 }
            return i < s.count ? s[i] : nil
        }

        // expr = term (('+' | '-') term)*
        mutating func parseExpression() -> Double? {
            guard var value = parseTerm() else { return nil }
            while let c = peek(), c == "+" || c == "-" {
                i += 1
                guard let rhs = parseTerm() else { return nil }
                value = (c == "+") ? value + rhs : value - rhs
            }
            return value
        }

        // term = factor (('*' | '/') factor)*
        private mutating func parseTerm() -> Double? {
            guard var value = parseFactor() else { return nil }
            while let c = peek(), c == "*" || c == "/" {
                i += 1
                guard let rhs = parseFactor() else { return nil }
                if c == "*" {
                    value *= rhs
                } else {
                    guard rhs != 0 else { return nil }
                    value /= rhs
                }
            }
            return value
        }

        // factor = number | '(' expr ')' | ('+' | '-') factor
        private mutating func parseFactor() -> Double? {
            guard let c = peek() else { return nil }
            if c == "(" {
                i += 1
                guard let value = parseExpression(), peek() == ")" else { return nil }
                i += 1
                return value
            }
            if c == "-" { i += 1; return parseFactor().map { -$0 } }
            if c == "+" { i += 1; return parseFactor() }
            return parseNumber()
        }

        /// Currency symbols allowed to prefix (or trail) a number; ignored when present.
        private static let currency: Set<Character> = ["$", "€", "£", "¥", "₹", "₩", "¢", "₪", "₺", "₫"]

        private mutating func parseNumber() -> Double? {
            _ = peek()  // skip leading spaces
            while i < s.count, Self.currency.contains(s[i]) { i += 1 }   // "$42,000" → 42000
            var digits = ""
            while i < s.count, s[i].isNumber || s[i] == "." || s[i] == "," {
                if s[i] != "," { digits.append(s[i]) }   // tolerate thousands separators
                i += 1
            }
            while i < s.count, Self.currency.contains(s[i]) { i += 1 }   // trailing "100€"
            return digits.isEmpty ? nil : Double(digits)
        }
    }
}
