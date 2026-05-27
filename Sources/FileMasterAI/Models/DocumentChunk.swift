import Foundation

/// Where a chunk of text physically lives in its source document, so a citation
/// can jump straight to it.
///
/// Offsets are **UTF-16** (NSRange semantics): that's what `PDFPage.selection(for:)`
/// and `NSTextView` highlighting both use, so one convention drives both viewers.
public enum ChunkLocator: Codable, Sendable, Hashable {
    /// A PDF page (0-based). `charRange` is the chunk's span within that page's
    /// text layer, used to build a `PDFSelection` highlight when present.
    case pdfPage(index: Int, charRange: Range<Int>?)
    /// A span of a plain-text / Markdown / HTML file. `charRange` is the absolute
    /// span; `lineRange` (1-based, inclusive) drives a friendly "lines 40–48" label.
    case textRange(charRange: Range<Int>, lineRange: ClosedRange<Int>?)
}

/// A unit of text extracted from a source file: the smallest thing we embed,
/// retrieve, and cite. Produced by ``Chunker``, persisted by ``SQLiteIndexStore``.
public struct Chunk: Sendable, Hashable {
    public let sourceURL: URL
    /// Position within its source file, 0-based, in extraction order.
    public let ordinal: Int
    public let text: String
    public let locator: ChunkLocator

    public init(sourceURL: URL, ordinal: Int, text: String, locator: ChunkLocator) {
        self.sourceURL = sourceURL
        self.ordinal = ordinal
        self.text = text
        self.locator = locator
    }
}

/// A chunk that has been stored and assigned a stable id (its SQLite rowid). The
/// id is the citation key the UI resolves back to a ``ChunkLocator`` (and, in M2,
/// the block number the LLM cites).
public struct StoredChunk: Identifiable, Sendable, Hashable {
    public let id: Int64
    public let chunk: Chunk

    public init(id: Int64, chunk: Chunk) {
        self.id = id
        self.chunk = chunk
    }

    public var sourceURL: URL { chunk.sourceURL }
    public var text: String { chunk.text }
    public var locator: ChunkLocator { chunk.locator }
}

/// A retrieved chunk presented to the user as a source for an answer.
public struct Citation: Identifiable, Sendable, Hashable {
    public let id: Int64            // == StoredChunk.id
    public let chunk: StoredChunk
    public let score: Float         // relevance, for ordering / display

    public init(id: Int64, chunk: StoredChunk, score: Float) {
        self.id = id
        self.chunk = chunk
        self.score = score
    }

    public var sourceURL: URL { chunk.sourceURL }

    /// A short single-line excerpt for the citation row.
    public var snippet: String {
        let collapsed = chunk.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return collapsed.count > 180 ? String(collapsed.prefix(180)) + "…" : collapsed
    }

    /// Human-readable location, e.g. "p. 12" or "lines 40–48".
    public var locationLabel: String {
        switch chunk.locator {
        case .pdfPage(let index, _):
            return "p. \(index + 1)"
        case .textRange(_, let lineRange):
            guard let lr = lineRange else { return chunk.sourceURL.lastPathComponent }
            return lr.lowerBound == lr.upperBound
                ? "line \(lr.lowerBound)"
                : "lines \(lr.lowerBound)–\(lr.upperBound)"
        }
    }
}
