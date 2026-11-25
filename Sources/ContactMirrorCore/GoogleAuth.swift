import Foundation
import Network
import CryptoKit

public enum GoogleAuthError: Error, LocalizedError {
    case notConfigured
    case notSignedIn
    case cancelled
    case timedOut
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Enter your Google OAuth client ID and secret in Settings → Google first."
        case .notSignedIn: return "Not signed in to Google."
        case .cancelled: return "Google sign-in was cancelled."
        case .timedOut: return "Google sign-in timed out."
        case .server(let s): return "Google sign-in failed: \(s)"
        }
    }
}

/// OAuth 2.0 for installed apps (loopback redirect + PKCE). The refresh token lives in the Keychain.
public final class GoogleAuth: @unchecked Sendable {
    public static let scopes = "openid email https://www.googleapis.com/auth/contacts"
    private static let refreshAccount = "google-refresh-token"
    private static let secretAccount = "google-client-secret"

    public var clientID: String {
        get { UserDefaults.standard.string(forKey: "googleClientID") ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "googleClientID") }
    }
    public var clientSecret: String {
        get { Keychain.get(Self.secretAccount) ?? "" }
        set { Keychain.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), for: Self.secretAccount) }
    }
    public private(set) var email: String? {
        get { UserDefaults.standard.string(forKey: "googleEmail") }
        set { UserDefaults.standard.set(newValue, forKey: "googleEmail") }
    }
    public var isConfigured: Bool { !clientID.isEmpty && !clientSecret.isEmpty }
    public var isSignedIn: Bool { Keychain.get(Self.refreshAccount) != nil }

    private var accessToken: String?
    private var accessExpiry = Date.distantPast
    private let lock = NSLock()

    public init() {}

    // MARK: Sign in

    public func signIn(openURL: @escaping (URL) -> Void) async throws {
        guard isConfigured else { throw GoogleAuthError.notConfigured }
        let verifier = Self.randomString(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
        let stateToken = Self.randomString(24)

        let server = LoopbackServer()
        let port = try await server.start()
        let redirect = "http://127.0.0.1:\(port)"

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scopes),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: stateToken),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        openURL(comps.url!)

        let params = try await server.waitForRedirect(timeout: 300)
        server.stop()
        if let err = params["error"] { throw err == "access_denied" ? GoogleAuthError.cancelled : GoogleAuthError.server(err) }
        guard params["state"] == stateToken, let code = params["code"] else { throw GoogleAuthError.server("invalid redirect") }

        let json = try await tokenRequest([
            "code": code,
            "client_id": clientID,
            "client_secret": clientSecret,
            "redirect_uri": redirect,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ])
        guard let refresh = json["refresh_token"] as? String else {
            throw GoogleAuthError.server("no refresh token returned")
        }
        Keychain.set(refresh, for: Self.refreshAccount)
        store(json)
        if let idToken = json["id_token"] as? String { email = Self.emailFromIDToken(idToken) }
    }

    public func signOut() {
        if let token = Keychain.get(Self.refreshAccount) {
            var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Self.form(["token": token])
            URLSession.shared.dataTask(with: req).resume()
        }
        Keychain.set(nil, for: Self.refreshAccount)
        lock.withLock { accessToken = nil; accessExpiry = .distantPast }
        email = nil
    }

    // MARK: Tokens

    public func validAccessToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let t = cachedToken() { return t }
        guard isConfigured else { throw GoogleAuthError.notConfigured }
        guard let refresh = Keychain.get(Self.refreshAccount) else { throw GoogleAuthError.notSignedIn }
        let json = try await tokenRequest([
            "client_id": clientID,
            "client_secret": clientSecret,
            "refresh_token": refresh,
            "grant_type": "refresh_token",
        ])
        store(json)
        guard let t = lock.withLock({ accessToken }) else { throw GoogleAuthError.server("no access token") }
        return t
    }

    private func cachedToken() -> String? {
        lock.withLock {
            guard let t = accessToken, accessExpiry > Date().addingTimeInterval(60) else { return nil }
            return t
        }
    }

    private func store(_ json: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        if let t = json["access_token"] as? String {
            accessToken = t
            let ttl = (json["expires_in"] as? Double) ?? Double(json["expires_in"] as? Int ?? 3600)
            accessExpiry = Date().addingTimeInterval(ttl)
        }
    }

    private func tokenRequest(_ fields: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.form(fields)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let err = (json["error"] as? String) ?? "HTTP \(status)"
            if err == "invalid_grant" {
                // Refresh token revoked or expired (e.g. OAuth app still in "Testing" mode).
                Keychain.set(nil, for: Self.refreshAccount)
                throw GoogleAuthError.server("Google access expired or was revoked – please sign in again.")
            }
            throw GoogleAuthError.server((json["error_description"] as? String) ?? err)
        }
        return json
    }

    // MARK: Helpers

    static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&").data(using: .utf8)!
    }

    static func randomString(_ n: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var g = SystemRandomNumberGenerator()
        return String((0..<n).map { _ in chars[Int(g.next() % UInt64(chars.count))] })
    }

    static func emailFromIDToken(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["email"] as? String
    }
}

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// Minimal one-shot HTTP server on 127.0.0.1 that captures the OAuth redirect.
final class LoopbackServer: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "contactmirror.loopback")
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var finished = false
    private var pending: Result<[String: String], Error>?

    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    cont.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let e):
                    resumed = true
                    cont.resume(throwing: e)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func waitForRedirect(timeout: TimeInterval) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                if let p = self.pending { self.finished = true; cont.resume(with: p); return }
                self.continuation = cont
                self.queue.asyncAfter(deadline: .now() + timeout) { self.finish(.failure(GoogleAuthError.timedOut)) }
            }
        }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
        }
    }

    private func finish(_ result: Result<[String: String], Error>) {
        guard !finished else { return }
        guard let c = continuation else { if pending == nil { pending = result }; return }
        finished = true
        continuation = nil
        c.resume(with: result)
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self else { return }
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let firstLine = text.split(separator: "\r\n").first.map(String.init) ?? ""
            let parts = firstLine.split(separator: " ")
            var params: [String: String] = [:]
            if parts.count >= 2, let comps = URLComponents(string: "http://127.0.0.1" + parts[1]) {
                for item in comps.queryItems ?? [] { params[item.name] = item.value ?? "" }
            }
            let isCallback = params["code"] != nil || params["error"] != nil
            let body = isCallback
                ? "<html><body style='font-family:-apple-system;text-align:center;padding-top:60px'><h2>ContactMirror</h2><p>Signed in. You can close this tab and return to the app.</p></body></html>"
                : "<html><body>Waiting for Google sign-in…</body></html>"
            let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
            if isCallback { self.finish(.success(params)) }
        }
    }
}
