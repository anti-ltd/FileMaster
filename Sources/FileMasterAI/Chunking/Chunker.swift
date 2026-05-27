import Foundation

/// Cuts extracted text into overlapping, sentence-aware chunks while preserving
/// each chunk's exact source location for citations.
///
/// Why these defaults: the on-device LLM's context window is ~4k tokens total, so
/// retrieved context must be small. ~900 chars ≈ ~220 tokens, so a handful of
/// chunks leaves room for the question, instructions, and the answer. Overlap
/// keeps a fact that straddles a boundary retrievable from either side.
///
/// All offsets are **UTF-16** (NSRange) so they line up with
/// `PDFPage.selection(for:)` and `NSTextView` highlighting.
public enum Chunker {
    public struct Config: Sendable {
        public var targetChars: Int
        public var maxChars: Int
        public var overlapChars: Int
        public init(targetChars: Int = 900, maxChars: Int = 1200, overlapChars: Int = 150) {
            self.targetChars = targetChars
            self.maxChars = maxChars
            self.overlapChars = overlapChars
        }
    }

    public static func chunk(_ segments: [ExtractedSegment],
                             sourceURL: URL,
                             config: Config = Config()) -> [Chunk] {
        var chunks: [Chunk] = []
        var ordinal = 0
        for segment in segments {
            let ns = segment.text as NSString
            let sentences = sentenceRanges(in: segment.text, maxChars: config.maxChars)
            for span in pack(sentences: sentences, config: config) {
                let text = ns.substring(with: span)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let charRange = span.location..<(span.location + span.length)
                let locator = locator(for: segment.origin, ns: ns, charRange: charRange)
                chunks.append(Chunk(sourceURL: sourceURL, ordinal: ordinal, text: text, locator: locator))
                ordinal += 1
            }
        }
        return chunks
    }

    // MARK: - Sentence segmentation

    /// Sentence ranges over the whole string (UTF-16). Any single "sentence"
    /// longer than `maxChars` (e.g. text with no sentence breaks) is hard-split
    /// into `maxChars` windows so a chunk can never blow the token budget.
    static func sentenceRanges(in text: String, maxChars: Int) -> [NSRange] {
        var ranges: [NSRange] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { _, range, _, _ in
            ranges.append(NSRange(range, in: text))
        }
        if ranges.isEmpty, !text.isEmpty {
            ranges = [NSRange(location: 0, length: (text as NSString).length)]
        }
        var out: [NSRange] = []
        for r in ranges {
            if r.length <= maxChars {
                out.append(r)
            } else {
                var loc = r.location
                let end = r.location + r.length
                while loc < end {
                    let len = min(maxChars, end - loc)
                    out.append(NSRange(location: loc, length: len))
                    loc += len
                }
            }
        }
        return out
    }

    /// Greedily pack sentences into chunk spans of ~`targetChars`, stepping back
    /// ~`overlapChars` worth of trailing sentences before starting the next chunk.
    static func pack(sentences: [NSRange], config: Config) -> [NSRange] {
        guard !sentences.isEmpty else { return [] }
        var spans: [NSRange] = []
        var i = 0
        while i < sentences.count {
            let start = sentences[i].location
            var j = i
            var end = sentences[i].location + sentences[i].length
            while j + 1 < sentences.count {
                let next = sentences[j + 1]
                let prospective = (next.location + next.length) - start
                if prospective > config.targetChars { break }
                j += 1
                end = next.location + next.length
                if (end - start) >= config.maxChars { break }
            }
            spans.append(NSRange(location: start, length: end - start))
            if j + 1 >= sentences.count { break }

            // Back up so the next chunk overlaps the tail of this one.
            var back = j
            var overlap = 0
            while back > i + 1 {
                overlap += sentences[back].length
                if overlap >= config.overlapChars { break }
                back -= 1
            }
            i = max(back, i + 1)   // always make progress
        }
        return spans
    }

    // MARK: - Locators

    private static func locator(for origin: ExtractedSegment.Origin,
                                ns: NSString,
                                charRange: Range<Int>) -> ChunkLocator {
        switch origin {
        case .pdfPage(let index):
            return .pdfPage(index: index, charRange: charRange)
        case .wholeText:
            let lines = lineRange(in: ns, charRange: charRange)
            return .textRange(charRange: charRange, lineRange: lines)
        }
    }

    /// 1-based inclusive line range spanned by `charRange`.
    private static func lineRange(in ns: NSString, charRange: Range<Int>) -> ClosedRange<Int> {
        let startLine = lineNumber(in: ns, atUTF16: charRange.lowerBound)
        let endIdx = max(charRange.lowerBound, charRange.upperBound - 1)
        let endLine = lineNumber(in: ns, atUTF16: min(endIdx, ns.length))
        return startLine...max(startLine, endLine)
    }

    private static func lineNumber(in ns: NSString, atUTF16 offset: Int) -> Int {
        guard ns.length > 0 else { return 1 }
        let clamped = min(max(offset, 0), ns.length)
        var line = 1
        ns.enumerateSubstrings(in: NSRange(location: 0, length: clamped),
                               options: [.byLines, .substringNotRequired]) { _, _, enclosing, _ in
            // Count line terminators preceding `offset`.
            if enclosing.location + enclosing.length <= clamped { line += 1 }
        }
        return line
    }
}
