import Foundation

/// The single entry point the UI talks to: indexes a set of files into a search
/// corpus, then answers questions against it.
///
/// Everything here is blocking and meant to run on a background queue (matching
/// the app's existing `DispatchQueue.global` tool pattern). The UI layer owns the
/// threading and the `ProgressHUD`.
public final class AskEngine: @unchecked Sendable {
    private let store: SQLiteIndexStore
    private var provider: EmbeddingProvider?
    private var corpus: Corpus?
    private let backend: AnswerBackend

    public init(backend: AnswerBackend = .retrievalOnly) throws {
        self.store = try SQLiteIndexStore(url: AIPaths.indexDB)
        self.backend = backend
    }

    /// True once a question can be answered (corpus loaded, non-empty).
    public var isReady: Bool { (corpus?.isEmpty == false) }

    /// Index `urls` (skipping unchanged files) and load them as the active corpus.
    /// `progress` is called 0…1. Call off the main thread.
    public func prepare(urls: [URL], progress: (Double) -> Void) throws {
        let supported = urls.filter { TextExtractor.canExtract($0) }
        guard !supported.isEmpty else { throw AskError.noSupportedFiles }

        if provider == nil {
            let sample = sampleText(from: supported)
            provider = EmbeddingProviderFactory.make(sampleText: sample)
        }
        guard let provider else { throw AskError.embeddingsUnavailable }

        let total = Double(supported.count)
        for (i, url) in supported.enumerated() {
            indexIfNeeded(url, provider: provider)
            progress(Double(i + 1) / total)
        }
        corpus = store.loadCorpus(urls: supported, dim: provider.dimension)
    }

    /// Retrieve the passages most relevant to `question` from the prepared
    /// corpus (hybrid semantic + lexical). This is the grounding for an answer,
    /// and is also the complete result in retrieval-only mode. Call off-main.
    public func retrieve(_ question: String, topK: Int = 8) -> [Citation] {
        guard let provider, let corpus, !corpus.isEmpty else { return [] }
        let queryVector = provider.embed([question]).first ?? []
        return HybridRetriever.retrieve(
            query: question, queryVector: queryVector,
            corpus: corpus, store: store, k: topK)
    }

    // MARK: - Indexing

    private func indexIfNeeded(_ url: URL, provider: EmbeddingProvider) {
        let (mtime, size) = fingerprint(url)
        if let existing = store.fingerprint(path: url.path),
           existing.mtime == mtime, existing.size == size, existing.provider == provider.identifier {
            return   // up to date
        }
        let segments = TextExtractor.extract(url)
        let chunks = Chunker.chunk(segments, sourceURL: url)
        guard !chunks.isEmpty else { return }
        let vectors = provider.embed(chunks.map(\.text))
        try? store.replaceFile(
            path: url.path, mtime: mtime, size: size,
            provider: provider.identifier, dim: provider.dimension,
            chunks: chunks, vectors: vectors)
    }

    private func fingerprint(_ url: URL) -> (mtime: Double, size: Int) {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return (values?.contentModificationDate?.timeIntervalSince1970 ?? 0, values?.fileSize ?? 0)
    }

    /// A short sample for language detection: first text-bearing file's head.
    private func sampleText(from urls: [URL]) -> String {
        for url in urls {
            let segments = TextExtractor.extract(url)
            if let first = segments.first(where: { !$0.text.isEmpty }) {
                return String(first.text.prefix(2000))
            }
        }
        return ""
    }
}
