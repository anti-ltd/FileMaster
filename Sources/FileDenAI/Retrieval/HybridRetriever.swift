import Foundation

/// Combines semantic (vector) and lexical (FTS5/BM25) retrieval over a corpus and
/// fuses them with RRF. This hybrid is the accuracy lever: embeddings catch
/// paraphrase and meaning, BM25 catches exact names / identifiers / rare terms
/// that vectors smear over.
public enum HybridRetriever {
    public static func retrieve(query: String,
                                queryVector: [Float],
                                corpus: Corpus,
                                store: SQLiteIndexStore,
                                k: Int = 8,
                                candidatePool: Int = 40) -> [Citation] {
        guard !corpus.isEmpty else { return [] }
        let byID = Dictionary(corpus.chunks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Semantic candidates.
        let semantic = VectorSearch.topK(
            query: queryVector, matrix: corpus.matrix,
            count: corpus.chunks.count, dim: corpus.dim, k: candidatePool)
        let semanticIDs = semantic.map { corpus.chunks[$0.index].id }
        let semanticScore = Dictionary(
            semantic.map { (corpus.chunks[$0.index].id, $0.score) }, uniquingKeysWith: { a, _ in a })

        // Lexical candidates, restricted to this corpus's chunks.
        let lexicalIDs = store.ftsSearch(query, limit: candidatePool * 2)
            .filter { corpus.validIDs.contains($0) }
            .prefix(candidatePool)

        let lists = lexicalIDs.isEmpty ? [semanticIDs] : [semanticIDs, Array(lexicalIDs)]
        // Fuse a deeper pool than `k` so we can drop duplicates and still fill `k`.
        let fused = RankFusion.rrf(lists, limit: max(k * 4, candidatePool))

        // Operational reports repeat boilerplate verbatim; without this the "sources"
        // are several copies of one paragraph, crowding out genuinely distinct hits
        // (like the one table the answer needs). Keep the first of each text.
        var seenText = Set<String>()
        var out: [Citation] = []
        for entry in fused {
            guard let chunk = byID[entry.id] else { continue }
            guard seenText.insert(Self.dedupKey(chunk.text)).inserted else { continue }
            // Prefer the cosine score for display when we have it.
            let score = semanticScore[entry.id] ?? Float(entry.score)
            out.append(Citation(id: entry.id, chunk: chunk, score: score))
            if out.count >= k { break }
        }
        return out
    }

    /// Identity for de-duplication: case- and whitespace-normalized full text, so
    /// verbatim repeats collapse while genuinely different passages are kept.
    private static func dedupKey(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
