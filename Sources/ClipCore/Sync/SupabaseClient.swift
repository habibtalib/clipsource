import CryptoKit
import Foundation

public enum SupabaseError: Error, CustomStringConvertible, Equatable {
    case notSignedIn
    /// The refresh token was rejected; the user must sign in again.
    case sessionExpired
    /// Unique-key clash, e.g. another device created the key record first.
    case conflict
    case http(Int, String)
    case network(String)
    case badResponse
    /// `register_device` refused a new Mac: the plan allows this many.
    case deviceLimit(Int)
    /// An RPC answered `{"ok": false, "error": code}`, or the server failed with a known code (`knownError`).
    /// `detail` is the server's human-readable explanation, when it sent one.
    case rejected(String, detail: String? = nil)

    public var description: String {
        switch self {
        case .notSignedIn: return "Not signed in to sync"
        case .sessionExpired: return "Sync session expired, sign in again"
        case .conflict: return "Sync record already exists"
        case let .http(status, message): return message.isEmpty ? "Sync server error (HTTP \(status))" : "Sync server error (HTTP \(status)): \(message)"
        case let .network(message): return "Sync network error: \(message)"
        case .badResponse: return "Unexpected response from sync server"
        case let .deviceLimit(limit):
            return "This account already has \(limit) \(limit == 1 ? "Mac" : "Macs") on the Free plan. Remove one or upgrade to Pro."
        case let .rejected(code, detail):
            if let detail, !detail.isEmpty {
                return code == "row_limit" ? "\(detail) Remove old entries or upgrade to Pro." : detail
            }
            switch code {
            case "device_in_use": return "This device ID is in use by another session; sign out and back in"
            case "web_limit": return "The web viewer limit for this plan is reached. Remove a web session or upgrade to Pro."
            case "already_subscribed": return "This account already has a Pro subscription; manage it from the billing portal"
            case "row_limit": return "Synced history is full on this plan. Remove old entries or upgrade to Pro."
            case "payload_too_large": return "An entry is too large to sync"
            case "invalid_hash": return "The sync server refused a malformed entry"
            default: return "Sync server refused the request (\(code.replacingOccurrences(of: "_", with: " ")))"
            }
        }
    }
}

/// Supabase Auth (GoTrue) and PostgREST over URLSession. The session is persisted in `SyncSecretStore` and
/// refreshed on demand; concurrent callers share one refresh.
public final class SupabaseClient: SyncTransport, @unchecked Sendable {
    let baseURL: String
    let anonKey: String
    let secrets: SyncSecretStore
    let http: URLSession

    private let lock = NSLock()
    private var current: SyncSession?
    private var refreshTask: Task<SyncSession, Error>?

    public init(url: URL, anonKey: String, secrets: SyncSecretStore) {
        var base = url.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        baseURL = base
        self.anonKey = anonKey
        self.secrets = secrets
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.httpCookieStorage = nil
        config.urlCache = nil
        http = URLSession(configuration: config)
        current = secrets.session()
    }

    public var session: SyncSession? {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    // MARK: Auth

    /// RFC 7636 verifier (43 base64url chars) and its S256 challenge.
    public static func pkcePair() -> (verifier: String, challenge: String) {
        let verifier = base64URL(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        return (verifier, challenge)
    }

    public func authorizeURL(provider: String, redirectTo: String, challenge: String) -> URL {
        let query = Self.query([("provider", provider), ("redirect_to", redirectTo),
                                ("code_challenge", challenge), ("code_challenge_method", "s256")])
        return URL(string: "\(baseURL)/auth/v1/authorize?\(query)")!
    }

    public func exchangeCode(_ code: String, verifier: String) async throws -> SyncSession {
        try await token(grant: "pkce", body: ["auth_code": code, "code_verifier": verifier])
    }

    public func signIn(email: String, password: String) async throws -> SyncSession {
        try await token(grant: "password", body: ["email": email, "password": password])
    }

    /// Best-effort server logout of this session only, then forget it locally.
    public func signOut() async {
        if let token = session?.accessToken {
            _ = try? await http.data(for: logoutRequest(token: token))
        }
        setSession(nil)
    }

    /// scope=local ends only this session; GoTrue's default (global) would sign out every device.
    func logoutRequest(token: String) -> URLRequest {
        var request = request("POST", "/auth/v1/logout", query: [("scope", "local")], token: token)
        request.timeoutInterval = 10
        return request
    }

    /// The current access token, refreshed first when it expires within 60 s.
    public func validAccessToken() async throws -> String {
        try await accessToken(rejected: nil)
    }

    /// `rejected` is a token the server just answered 401 for: refresh unless another caller already replaced it.
    private func accessToken(rejected: String?) async throws -> String {
        let task: Task<SyncSession, Error>
        switch try tokenOrRefresh(rejected: rejected) {
        case let .ready(token): return token
        case let .refreshing(running): task = running
        }
        defer { lock.withLock { if refreshTask == task { refreshTask = nil } } }
        do {
            return try await task.value.accessToken
        } catch let SupabaseError.http(status, _) where status == 400 || status == 401 {
            setSession(nil)
            throw SupabaseError.sessionExpired
        }
    }

    private enum TokenState {
        case ready(String)
        case refreshing(Task<SyncSession, Error>)
    }

    /// The usable token, or the single in-flight refresh (started here if none is running).
    private func tokenOrRefresh(rejected: String?) throws -> TokenState {
        try lock.withLock {
            guard let session = current else { throw SupabaseError.notSignedIn }
            let fresh = session.expiresAt.timeIntervalSinceNow > 60
            if fresh, rejected == nil || rejected != session.accessToken { return .ready(session.accessToken) }
            if let running = refreshTask { return .refreshing(running) }
            let refreshToken = session.refreshToken
            let task = Task { try await self.token(grant: "refresh_token", body: ["refresh_token": refreshToken]) }
            refreshTask = task
            return .refreshing(task)
        }
    }

    private struct TokenResponse: Decodable {
        struct User: Decodable { let id: String; let email: String? }
        let access_token: String
        let refresh_token: String
        let expires_in: Double?
        let expires_at: Double?
        let user: User
    }

    private func token(grant: String, body: [String: String]) async throws -> SyncSession {
        var request = request("POST", "/auth/v1/token", query: [("grant_type", grant)], token: nil)
        request.httpBody = try JSONEncoder().encode(body)
        let data = try await send(request)
        guard let response = try? JSONDecoder().decode(TokenResponse.self, from: data) else { throw SupabaseError.badResponse }
        let expiresAt = response.expires_at.map { Date(timeIntervalSince1970: $0) }
            ?? Date().addingTimeInterval(response.expires_in ?? 3600)
        let session = SyncSession(accessToken: response.access_token, refreshToken: response.refresh_token,
                                  expiresAt: expiresAt, userId: response.user.id, email: response.user.email)
        setSession(session)
        return session
    }

    private func setSession(_ session: SyncSession?) {
        lock.lock()
        current = session
        lock.unlock()
        try? secrets.saveSession(session)
    }

    // MARK: SyncTransport

    private struct KeyRow: Codable {
        var user_id: String?
        var salt: String
        var check_value: String
        var iterations: Int
    }

    public func fetchKeyRecord() async throws -> SyncKeyRecord? {
        let data = try await rest("GET", "/rest/v1/sync_keys", query: [("select", "salt,check_value,iterations"), ("limit", "1")])
        guard let rows = try? JSONDecoder().decode([KeyRow].self, from: data) else { throw SupabaseError.badResponse }
        return rows.first.map { SyncKeyRecord(salt: $0.salt, check: $0.check_value, iterations: $0.iterations) }
    }

    public func createKeyRecord(_ record: SyncKeyRecord) async throws {
        let row = KeyRow(user_id: try userId(), salt: record.salt, check_value: record.check, iterations: record.iterations)
        _ = try await rest("POST", "/rest/v1/sync_keys", body: try JSONEncoder().encode(row), prefer: "return=minimal")
    }

    /// Wire form of a pushed row. `payload` is always sent (null for tombstones) so a merge clears old ciphertext.
    private struct UpsertRow: Encodable {
        let userId: String
        let clip: RemoteClip

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: RemoteClip.CodingKeys.self)
            try c.encode(clip.hash, forKey: .hash)
            try c.encode(clip.payload, forKey: .payload)
            try c.encode(SupabaseClient.formatTimestamp(clip.createdAt), forKey: .createdAt)
            try c.encode(clip.deleted, forKey: .deleted)
            try c.encodeIfPresent(clip.deviceId, forKey: .deviceId)
            var u = encoder.container(keyedBy: UserKey.self)
            try u.encode(userId, forKey: .user_id)
        }

        enum UserKey: String, CodingKey { case user_id }
    }

    public func upsert(_ rows: [RemoteClip]) async throws {
        guard !rows.isEmpty else { return }
        let uid = try userId()
        let body = try JSONEncoder().encode(rows.map { UpsertRow(userId: uid, clip: $0) })
        _ = try await rest("POST", "/rest/v1/clips", query: [("on_conflict", "user_id,hash")], body: body,
                           prefer: "resolution=merge-duplicates,return=minimal")
    }

    public func fetch(after cursor: SyncCursor?, limit: Int) async throws -> [RemoteClip] {
        var query = [("select", "id,hash,payload,created_at,updated_at,deleted")]
        if let cursor {
            // Quoted: timestamps contain `.` and `:`, which are reserved inside PostgREST logic trees.
            let t = "\"\(Self.formatTimestamp(cursor.updatedAt))\""
            if let id = cursor.id {
                query.append(("or", "(updated_at.gt.\(t),and(updated_at.eq.\(t),id.gt.\(id)))"))
            } else {
                query.append(("updated_at", "gte.\(Self.formatTimestamp(cursor.updatedAt))"))
            }
        }
        query += [("order", "updated_at.asc,id.asc"), ("limit", String(limit))]
        let data = try await rest("GET", "/rest/v1/clips", query: query)
        do {
            return try Self.decoder.decode([RemoteClip].self, from: data)
        } catch {
            throw SupabaseError.badResponse
        }
    }

    public func deleteOlder(than date: Date) async throws {
        _ = try await rest("DELETE", "/rest/v1/clips",
                           query: [("user_id", "eq.\(try userId())"), ("created_at", "lt.\(Self.formatTimestamp(date))")],
                           prefer: "return=minimal")
    }

    public func deleteAll() async throws {
        let uid = try userId()
        _ = try await rest("DELETE", "/rest/v1/clips", query: [("user_id", "eq.\(uid)")], prefer: "return=minimal")
        _ = try await rest("DELETE", "/rest/v1/sync_keys", query: [("user_id", "eq.\(uid)")], prefer: "return=minimal")
    }

    // MARK: ClipSource Cloud

    /// Register this device, or refresh its name and last-seen time. Throws `deviceLimit` when the plan is full.
    public func registerDevice(id: String, name: String, kind: String = "mac") async throws -> CloudAccount {
        try await rpc("register_device", ["p_device_id": id, "p_name": name, "p_kind": kind])
    }

    public func accountStatus() async throws -> CloudAccount {
        try await rpc("account_status", [:])
    }

    public func removeDevice(id: String) async throws {
        try checked(try await rest("POST", "/rest/v1/rpc/remove_device", body: JSONEncoder().encode(["p_device_id": id])))
    }

    public func renameDevice(id: String, name: String) async throws {
        try checked(try await rest("POST", "/rest/v1/rpc/rename_device",
                                        body: JSONEncoder().encode(["p_device_id": id, "p_name": name])))
    }

    /// Stripe Checkout for Pro. `interval` is "month" or "year".
    public func checkoutURL(interval: String) async throws -> URL {
        try await functionURL("billing-checkout", body: ["interval": interval])
    }

    /// Stripe Customer Portal for managing the subscription.
    public func portalURL() async throws -> URL {
        try await functionURL("billing-portal", body: [:])
    }

    private func rpc(_ name: String, _ params: [String: String]) async throws -> CloudAccount {
        let data = try await rest("POST", "/rest/v1/rpc/\(name)", body: JSONEncoder().encode(params))
        try checked(data)
        do {
            return try JSONDecoder().decode(CloudAccount.self, from: data)
        } catch {
            throw SupabaseError.badResponse
        }
    }

    /// `checkOK`, signing out locally when the server revoked this device's session.
    private func checked(_ data: Data) throws {
        do {
            try Self.checkOK(data)
        } catch SupabaseError.sessionExpired {
            setSession(nil)
            throw SupabaseError.sessionExpired
        }
    }

    /// Maps an `{"ok": false}` RPC answer to an error; anything else passes.
    static func checkOK(_ data: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["ok"] as? Bool) == false else { return }
        let code = object["error"] as? String ?? "unknown"
        // The device was removed from the account: its session is gone, so sign out like an expired session.
        if code == "session_revoked" { throw SupabaseError.sessionExpired }
        if code == "device_limit" {
            throw SupabaseError.deviceLimit(object["device_limit"] as? Int ?? ClipSourceCloud.freeDeviceLimit)
        }
        throw SupabaseError.rejected(code)
    }

    private func functionURL(_ name: String, body: [String: String]) async throws -> URL {
        let data = try await rest("POST", "/functions/v1/\(name)", body: JSONEncoder().encode(body))
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["url"] as? String, let url = URL(string: raw), url.scheme == "https" else {
            throw SupabaseError.badResponse
        }
        return url
    }

    private func userId() throws -> String {
        guard let id = session?.userId else { throw SupabaseError.notSignedIn }
        return id
    }

    // MARK: HTTP

    /// Authenticated PostgREST call; on 401 refreshes the token once and retries.
    private func rest(_ method: String, _ path: String, query: [(String, String)] = [], body: Data? = nil,
                      prefer: String? = nil) async throws -> Data {
        var token = try await validAccessToken()
        for attempt in 0..<2 {
            var request = request(method, path, query: query, token: token)
            request.httpBody = body
            if let prefer { request.setValue(prefer, forHTTPHeaderField: "Prefer") }
            do {
                return try await send(request)
            } catch SupabaseError.http(401, _) where attempt == 0 {
                token = try await accessToken(rejected: token)
            }
        }
        throw SupabaseError.sessionExpired
    }

    private func request(_ method: String, _ path: String, query: [(String, String)] = [], token: String?) -> URLRequest {
        let suffix = query.isEmpty ? "" : "?" + Self.query(query)
        var request = URLRequest(url: URL(string: baseURL + path + suffix)!)
        request.httpMethod = method
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token ?? anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await http.data(for: request)
        } catch {
            // URLError's localized text names the failure, not the URL or headers.
            throw SupabaseError.network((error as? URLError)?.localizedDescription ?? "request failed")
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw SupabaseError.badResponse }
        guard (200..<300).contains(status) else {
            if let error = Self.knownError(data) {
                if error == .sessionExpired { setSession(nil) }
                throw error
            }
            if status == 409 { throw SupabaseError.conflict }
            throw SupabaseError.http(status, Self.errorMessage(data))
        }
        return data
    }

    /// Error codes the server raises on purpose (RPC exceptions, triggers, edge functions). They map to
    /// `rejected(code)` whatever the HTTP status.
    static let knownCodes: Set<String> = ["device_in_use", "web_limit", "already_subscribed", "row_limit"]

    /// A deliberate server error in an error body: edge functions send `{"error": code}`, PostgREST
    /// `{"code": "P0001", "message": code, "details": text}` for raised exceptions and `{"code": "23514"}`
    /// for CHECK violations on `clips`.
    static func knownError(_ data: Data) -> SupabaseError? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let detail = (object["details"] as? String).map { String($0.prefix(200)) }
        for key in ["error", "message"] where object[key] as? String == "session_revoked" {
            return .sessionExpired
        }
        for key in ["error", "message"] {
            if let text = object[key] as? String, knownCodes.contains(text) { return .rejected(text, detail: detail) }
        }
        if object["code"] as? String == "23514" {
            let message = object["message"] as? String ?? ""
            if message.contains("clips_payload_size") { return .rejected("payload_too_large") }
            if message.contains("clips_hash_format") { return .rejected("invalid_hash") }
            return .rejected("check_violation", detail: String(message.prefix(200)))
        }
        return nil
    }

    /// Server error text from GoTrue (`msg`, `error_description`) or PostgREST (`message`); never echoes the request.
    static func errorMessage(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        for key in ["message", "msg", "error_description", "error"] {
            if let text = object[key] as? String, !text.isEmpty { return String(text.prefix(200)) }
        }
        return ""
    }

    // MARK: Encoding

    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Strict form encoding: `+` and `:` in timestamps must reach PostgREST literally.
    static func query(_ items: [(String, String)]) -> String {
        items.map { "\($0.0.addingPercentEncoding(withAllowedCharacters: unreserved)!)=\($0.1.addingPercentEncoding(withAllowedCharacters: unreserved)!)" }
            .joined(separator: "&")
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let text = try c.decode(String.self)
            guard let date = SupabaseClient.parseTimestamp(text) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad timestamp \(text)")
            }
            return date
        }
        return d
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// UTC ISO 8601 with microseconds, e.g. `2026-11-01T10:00:00.123456Z` (Postgres precision).
    public static func formatTimestamp(_ date: Date) -> String {
        var whole = date.timeIntervalSince1970.rounded(.down)
        var micros = Int(((date.timeIntervalSince1970 - whole) * 1_000_000).rounded())
        if micros >= 1_000_000 { whole += 1; micros -= 1_000_000 }
        let base = isoFormatter.string(from: Date(timeIntervalSince1970: whole))  // ...:SSZ
        return String(base.dropLast()) + String(format: ".%06dZ", micros)
    }

    /// Parses Postgres/PostgREST timestamps: any fraction length, `Z`, `+00:00`, `+0530` or `+05`, `T` or space.
    public static func parseTimestamp(_ text: String) -> Date? {
        var s = text.trimmingCharacters(in: .whitespaces)
        guard s.count >= 19 else { return nil }
        if s[s.index(s.startIndex, offsetBy: 10)] == " " {
            s.replaceSubrange(s.index(s.startIndex, offsetBy: 10)...s.index(s.startIndex, offsetBy: 10), with: "T")
        }
        var fraction = 0.0
        let secondsEnd = s.index(s.startIndex, offsetBy: 19)
        var rest = String(s[secondsEnd...])
        if rest.hasPrefix(".") {
            let digits = rest.dropFirst().prefix { $0.isNumber }
            fraction = Double("0." + digits) ?? 0
            rest = String(rest.dropFirst(1 + digits.count))
        }
        if rest.isEmpty { rest = "Z" }
        if rest != "Z", rest.count == 3 { rest += ":00" }  // +05
        if rest != "Z", rest.count == 5, !rest.contains(":") {  // +0530
            rest.insert(":", at: rest.index(rest.startIndex, offsetBy: 3))
        }
        guard let date = isoFormatter.date(from: String(s[..<secondsEnd]) + rest) else { return nil }
        return date.addingTimeInterval(fraction)
    }
}
