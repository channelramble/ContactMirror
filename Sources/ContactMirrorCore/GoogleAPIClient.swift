import Foundation

public struct GoogleAPIError: Error, LocalizedError {
    public var status: Int
    public var message: String
    public var errorDescription: String? { "Google API error \(status): \(message)" }
}

/// Authenticated JSON client for Google APIs with retries, backoff and write pacing.
public final class GoogleAPIClient: @unchecked Sendable {
    let auth: GoogleAuth
    private let session: URLSession
    private var lastMutation = Date.distantPast
    /// Minimum spacing between writes (Google asks for sequential, paced mutations per user).
    var mutationSpacing: TimeInterval = 0.35

    public init(auth: GoogleAuth) {
        self.auth = auth
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        session = URLSession(configuration: cfg)
    }

    /// - Parameter idempotent: false for creates, which must not be retried after a network
    ///   or server error (the item may already exist).
    public func request(_ method: String, _ url: String, query: [String: String] = [:],
                 body: [String: Any]? = nil, mutation: Bool = false,
                 idempotent: Bool = true) async throws -> [String: Any] {
        var comps = URLComponents(string: url)!
        if !query.isEmpty {
            comps.queryItems = (comps.queryItems ?? []) + query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        // '+' in query values must be escaped (e.g. time zone offsets in RFC 3339 times).
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var attempt = 0
        var forcedRefresh = false
        while true {
            if mutation {
                let wait = mutationSpacing - Date().timeIntervalSince(lastMutation)
                if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
                lastMutation = Date()
            }
            var req = URLRequest(url: comps.url!)
            req.httpMethod = method
            let token = try await auth.validAccessToken(forceRefresh: forcedRefresh)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let body {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            let (data, resp): (Data, URLResponse)
            do {
                (data, resp) = try await session.data(for: req)
            } catch {
                attempt += 1
                if attempt > 4 || !idempotent { throw error }
                try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt)) * 1e9))
                continue
            }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if (200..<300).contains(status) { return json }
            if status == 401 && !forcedRefresh { forcedRefresh = true; continue }
            let reason = (((json["error"] as? [String: Any])?["errors"] as? [[String: Any]])?.first?["reason"] as? String) ?? ""
            let rateLimited = status == 429 || (status == 403 && reason.lowercased().contains("ratelimit"))
            if (rateLimited || (idempotent && [500, 502, 503, 504].contains(status))) && attempt < 6 {
                attempt += 1
                var delay = pow(2.0, Double(attempt))
                if let ra = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After"), let s = Double(ra) { delay = max(delay, s) }
                try await Task.sleep(nanoseconds: UInt64(min(delay, 90) * 1e9))
                continue
            }
            let msg = ((json["error"] as? [String: Any])?["message"] as? String) ?? String(data: data, encoding: .utf8) ?? ""
            throw GoogleAPIError(status: status, message: msg)
        }
    }
}
