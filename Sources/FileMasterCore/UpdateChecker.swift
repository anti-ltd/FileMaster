import Foundation

// Manual update checker — ported from Clonk to keep the anti.ltd apps
// behaviourally identical here.
//
// Fires only when the user taps "Check for updates" in the About tab; there is
// no background polling, no telemetry, no identifiers in the request. The
// endpoint (anti-ltd's release index) returns metadata for the latest public
// build; we compare its `version` against the running bundle and surface the
// result inline.

public struct VersionInfo: Codable, Equatable, Sendable {
    public let app: String
    public let version: String
    public let releasedAt: String?
    public let notes: String?
    public let minOS: String?
    public let sha256: String?
    public let size: Int?
    public let downloadUrl: String?
}

public enum UpdateCheckError: Error, LocalizedError, Sendable {
    case badStatus(Int)
    case decodeFailed

    public var errorDescription: String? {
        switch self {
        case .badStatus(let code): return "Server returned \(code)."
        case .decodeFailed:        return "Couldn't read the server's response."
        }
    }
}

public enum UpdateChecker {

    // Anti Limited's release index — see anti-ltd/src/worker/versions.js.
    public static let endpoint = URL(string: "https://anti.ltd/api/version")!

    /// Hit the version endpoint and return the parsed payload.
    /// Throws on transport, HTTP, or decode failure.
    public static func fetch(appID: String = "filemaster",
                             endpoint: URL = UpdateChecker.endpoint,
                             session: URLSession = .shared) async throws -> VersionInfo {
        var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "app", value: appID)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 10

        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateCheckError.badStatus(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(VersionInfo.self, from: data)
        } catch {
            throw UpdateCheckError.decodeFailed
        }
    }

    /// True when `remote` is strictly newer than `local`, per dotted-int
    /// semver compare (e.g. "1.2.10" > "1.2.9"). Non-numeric tails are
    /// treated as 0, so "1.2" and "1.2.0" compare equal.
    public static func isNewer(_ remote: String, than local: String) -> Bool {
        compare(remote, local) == .orderedDescending
    }

    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let lhs = parts(a), rhs = parts(b)
        let n = max(lhs.count, rhs.count)
        for i in 0..<n {
            let l = i < lhs.count ? lhs[i] : 0
            let r = i < rhs.count ? rhs[i] : 0
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func parts(_ s: String) -> [Int] {
        s.split(separator: ".").map { Int($0) ?? 0 }
    }
}

// Convenience: resolve a possibly-relative downloadUrl against the endpoint
// base so a server response of "/api/download?app=filemaster" still opens to a
// real https:// URL.
public extension VersionInfo {
    func resolvedDownloadURL(relativeTo base: URL = UpdateChecker.endpoint) -> URL? {
        guard let raw = downloadUrl else { return nil }
        if let abs = URL(string: raw), abs.scheme != nil { return abs }
        // Drop the path off the endpoint so "/api/download" resolves at the
        // host root, not at "/api/version/api/download".
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
        comps?.path = ""
        comps?.query = nil
        guard let host = comps?.url else { return nil }
        return URL(string: raw, relativeTo: host)?.absoluteURL
    }
}
