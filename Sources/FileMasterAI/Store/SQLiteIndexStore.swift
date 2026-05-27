import Foundation
import SQLite3

// SQLite hands back a sentinel destructor as a macro that isn't imported into
// Swift; this is the canonical reconstruction. Tells SQLite to copy bound bytes.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum IndexError: Error {
    case open(String)
    case sql(String)
}

/// Durable on-disk index for the Ask feature, backed by the system `libsqlite3`.
///
/// One database holds every indexed file's chunks: their text (mirrored into an
/// **FTS5** table for fast BM25 lexical search), their embedding vectors (packed
/// `Float32` BLOBs, for semantic search), and their citation locators. Files are
/// keyed by path + fingerprint (mtime, size, embedding-provider id), so an
/// unchanged file is never re-indexed and the same file reused across dens shares
/// one index.
///
/// All access is serialized on an internal queue; call from a background thread.
public final class SQLiteIndexStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "ltd.anti.filemaster.index")

    public init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw IndexError.open(message)
        }
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA foreign_keys=ON;")
        try createSchema()
    }

    deinit { if let db { sqlite3_close(db) } }

    // MARK: - Schema

    private func createSchema() throws {
        try exec("""
            CREATE TABLE IF NOT EXISTS files(
              id INTEGER PRIMARY KEY,
              path TEXT UNIQUE NOT NULL,
              mtime REAL NOT NULL,
              size INTEGER NOT NULL,
              provider TEXT NOT NULL,
              dim INTEGER NOT NULL
            );
            """)
        try exec("""
            CREATE TABLE IF NOT EXISTS chunks(
              id INTEGER PRIMARY KEY,
              file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
              ordinal INTEGER NOT NULL,
              text TEXT NOT NULL,
              loc_kind INTEGER NOT NULL,
              page INTEGER NOT NULL DEFAULT -1,
              has_range INTEGER NOT NULL DEFAULT 0,
              range_loc INTEGER NOT NULL DEFAULT 0,
              range_len INTEGER NOT NULL DEFAULT 0,
              line_start INTEGER NOT NULL DEFAULT 0,
              line_end INTEGER NOT NULL DEFAULT 0,
              vector BLOB NOT NULL
            );
            """)
        try exec("CREATE INDEX IF NOT EXISTS idx_chunks_file ON chunks(file_id);")
        try exec("CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(text);")
    }

    // MARK: - Fingerprints

    public struct Fingerprint: Equatable, Sendable {
        public let mtime: Double
        public let size: Int
        public let provider: String
    }

    /// The stored fingerprint for `path`, or nil if the file isn't indexed.
    public func fingerprint(path: String) -> Fingerprint? {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT mtime,size,provider FROM files WHERE path=?;", -1, &stmt, nil) == SQLITE_OK
            else { return nil }
            bindText(stmt, 1, path)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return Fingerprint(
                mtime: sqlite3_column_double(stmt, 0),
                size: Int(sqlite3_column_int64(stmt, 1)),
                provider: columnText(stmt, 2))
        }
    }

    // MARK: - Writing

    /// Replace all rows for `path` with the given chunks + vectors, in one
    /// transaction. `vectors[i]` is the embedding for `chunks[i]` (length `dim`).
    public func replaceFile(path: String,
                            mtime: Double,
                            size: Int,
                            provider: String,
                            dim: Int,
                            chunks: [Chunk],
                            vectors: [[Float]]) throws {
        try queue.sync {
            try exec("BEGIN;")
            do {
                // Drop FTS rows for the file's old chunks, then the file (cascades chunks).
                try run("DELETE FROM chunks_fts WHERE rowid IN (SELECT id FROM chunks WHERE file_id=(SELECT id FROM files WHERE path=?));") {
                    bindText($0, 1, path)
                }
                try run("DELETE FROM files WHERE path=?;") { bindText($0, 1, path) }

                try run("INSERT INTO files(path,mtime,size,provider,dim) VALUES(?,?,?,?,?);") {
                    bindText($0, 1, path)
                    sqlite3_bind_double($0, 2, mtime)
                    sqlite3_bind_int64($0, 3, sqlite3_int64(size))
                    bindText($0, 4, provider)
                    sqlite3_bind_int64($0, 5, sqlite3_int64(dim))
                }
                let fileID = sqlite3_last_insert_rowid(db)

                for (chunk, vector) in zip(chunks, vectors) {
                    let (kind, page, hasRange, loc, len, lineStart, lineEnd) = decompose(chunk.locator)
                    try run("""
                        INSERT INTO chunks(file_id,ordinal,text,loc_kind,page,has_range,range_loc,range_len,line_start,line_end,vector)
                        VALUES(?,?,?,?,?,?,?,?,?,?,?);
                        """) { stmt in
                        sqlite3_bind_int64(stmt, 1, fileID)
                        sqlite3_bind_int64(stmt, 2, sqlite3_int64(chunk.ordinal))
                        bindText(stmt, 3, chunk.text)
                        sqlite3_bind_int64(stmt, 4, sqlite3_int64(kind))
                        sqlite3_bind_int64(stmt, 5, sqlite3_int64(page))
                        sqlite3_bind_int64(stmt, 6, sqlite3_int64(hasRange ? 1 : 0))
                        sqlite3_bind_int64(stmt, 7, sqlite3_int64(loc))
                        sqlite3_bind_int64(stmt, 8, sqlite3_int64(len))
                        sqlite3_bind_int64(stmt, 9, sqlite3_int64(lineStart))
                        sqlite3_bind_int64(stmt, 10, sqlite3_int64(lineEnd))
                        bindBlob(stmt, 11, pack(vector))
                    }
                    let chunkID = sqlite3_last_insert_rowid(db)
                    try run("INSERT INTO chunks_fts(rowid,text) VALUES(?,?);") {
                        sqlite3_bind_int64($0, 1, chunkID)
                        bindText($0, 2, chunk.text)
                    }
                }
                try exec("COMMIT;")
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
        }
    }

    // MARK: - Reading

    /// Load the given files' chunks into a search-ready ``Corpus``. Chunks whose
    /// stored vector length doesn't match `dim` are skipped (stale provider).
    public func loadCorpus(urls: [URL], dim: Int) -> Corpus {
        queue.sync {
            var stored: [StoredChunk] = []
            var matrix: [Float] = []
            var valid: Set<Int64> = []
            let sql = """
                SELECT id,ordinal,text,loc_kind,page,has_range,range_loc,range_len,line_start,line_end,vector
                FROM chunks WHERE file_id=(SELECT id FROM files WHERE path=?) ORDER BY ordinal;
                """
            for url in urls {
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
                bindText(stmt, 1, url.path)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let vector = unpack(blob(stmt, 10))
                    guard vector.count == dim else { continue }
                    let id = sqlite3_column_int64(stmt, 0)
                    let chunk = Chunk(
                        sourceURL: url,
                        ordinal: Int(sqlite3_column_int64(stmt, 1)),
                        text: columnText(stmt, 2),
                        locator: composeLocator(
                            kind: Int(sqlite3_column_int64(stmt, 3)),
                            page: Int(sqlite3_column_int64(stmt, 4)),
                            hasRange: sqlite3_column_int64(stmt, 5) == 1,
                            loc: Int(sqlite3_column_int64(stmt, 6)),
                            len: Int(sqlite3_column_int64(stmt, 7)),
                            lineStart: Int(sqlite3_column_int64(stmt, 8)),
                            lineEnd: Int(sqlite3_column_int64(stmt, 9))))
                    stored.append(StoredChunk(id: id, chunk: chunk))
                    matrix.append(contentsOf: vector)
                    valid.insert(id)
                }
                sqlite3_finalize(stmt)
            }
            return Corpus(chunks: stored, matrix: matrix, dim: dim, validIDs: valid)
        }
    }

    /// FTS5 lexical (BM25) search. `query` is sanitized into a safe MATCH
    /// expression; returns chunk ids best-first. Empty for a query with no
    /// usable terms.
    public func ftsSearch(_ query: String, limit: Int) -> [Int64] {
        guard let match = Self.ftsExpression(from: query) else { return [] }
        return queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db,
                "SELECT rowid FROM chunks_fts WHERE chunks_fts MATCH ? ORDER BY rank LIMIT ?;",
                -1, &stmt, nil) == SQLITE_OK else { return [] }
            bindText(stmt, 1, match)
            sqlite3_bind_int64(stmt, 2, sqlite3_int64(limit))
            var ids: [Int64] = []
            while sqlite3_step(stmt) == SQLITE_ROW { ids.append(sqlite3_column_int64(stmt, 0)) }
            return ids
        }
    }

    /// Build a safe FTS5 MATCH from arbitrary user text: keep alphanumeric tokens
    /// (≥2 chars), quote each (so punctuation/operators can't break the parse),
    /// OR them together for recall (BM25 still ranks term coverage).
    static func ftsExpression(from query: String) -> String? {
        let tokens = query.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 2 }
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0)\"" }.joined(separator: " OR ")
    }

    // MARK: - Locator (de)composition

    private func decompose(_ locator: ChunkLocator)
        -> (kind: Int, page: Int, hasRange: Bool, loc: Int, len: Int, lineStart: Int, lineEnd: Int) {
        switch locator {
        case .pdfPage(let index, let range):
            return (0, index, range != nil, range?.lowerBound ?? 0, range?.count ?? 0, 0, 0)
        case .textRange(let range, let lines):
            return (1, -1, true, range.lowerBound, range.count, lines?.lowerBound ?? 0, lines?.upperBound ?? 0)
        }
    }

    private func composeLocator(kind: Int, page: Int, hasRange: Bool, loc: Int, len: Int,
                                lineStart: Int, lineEnd: Int) -> ChunkLocator {
        if kind == 0 {
            return .pdfPage(index: page, charRange: hasRange ? loc..<(loc + len) : nil)
        }
        let lines = lineStart > 0 ? lineStart...max(lineStart, lineEnd) : nil
        return .textRange(charRange: loc..<(loc + len), lineRange: lines)
    }

    // MARK: - BLOB packing

    private func pack(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private func unpack(_ data: Data) -> [Float] {
        guard !data.isEmpty else { return [] }
        let count = data.count / MemoryLayout<Float>.stride
        var out = [Float](repeating: 0, count: count)
        _ = out.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return out
    }

    // MARK: - SQLite helpers

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw IndexError.sql(message)
        }
    }

    /// Prepare, bind, step-to-done, finalize — for INSERT/DELETE.
    private func run(_ sql: String, bind: (OpaquePointer?) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw IndexError.sql(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw IndexError.sql(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
    }

    private func bindBlob(_ stmt: OpaquePointer?, _ index: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            _ = sqlite3_bind_blob(stmt, index, raw.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
        }
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: c)
    }

    private func blob(_ stmt: OpaquePointer?, _ index: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(stmt, index) else { return Data() }
        let count = Int(sqlite3_column_bytes(stmt, index))
        return Data(bytes: bytes, count: count)
    }
}
