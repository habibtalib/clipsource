import Foundation

/// Supabase Realtime (Phoenix channels, vsn 1.0.0) over URLSessionWebSocketTask. Subscribes to
/// `postgres_changes` on `public.clips`; RLS limits events to the signed-in user's rows. Events carry
/// only ciphertext, so the client just signals and the engine pulls.
public final class RealtimeClient: @unchecked Sendable {
    static let topic = "realtime:clipsource-clips"
    static let heartbeatInterval: UInt64 = 25

    let socketURL: URL
    let tokenProvider: @Sendable () async throws -> String
    let http = URLSession(configuration: .ephemeral)

    private let lock = NSLock()
    private var _onChange: (@Sendable () -> Void)?
    private var _onStateChange: (@Sendable (Bool) -> Void)?
    private var wanted = false
    /// Bumped on every (re)connect and disconnect; callbacks from an older socket are ignored.
    private var generation = 0
    private var socket: URLSessionWebSocketTask?
    private var workers: [Task<Void, Never>] = []
    private var joined = false
    private var attempt = 0
    private var ref = 0
    private var joinRef: String?
    private var pendingHeartbeat: String?
    private var sentToken: String?

    public init(url: URL, anonKey: String, tokenProvider: @escaping @Sendable () async throws -> String) {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path + "/realtime/v1/websocket"
        components.percentEncodedQuery = SupabaseClient.query([("apikey", anonKey), ("vsn", "1.0.0")])
        socketURL = components.url!
        self.tokenProvider = tokenProvider
    }

    /// Any change to the user's clips (engine then pulls).
    public var onChange: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onChange }
        set { lock.lock(); _onChange = newValue; lock.unlock() }
    }

    /// True once the channel is joined, false when the connection drops.
    public var onStateChange: (@Sendable (Bool) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onStateChange }
        set { lock.lock(); _onStateChange = newValue; lock.unlock() }
    }

    public func connect() {
        lock.lock()
        guard !wanted else { lock.unlock(); return }
        wanted = true
        attempt = 0
        lock.unlock()
        open(after: 0)
    }

    public func disconnect() {
        lock.lock()
        wanted = false
        lock.unlock()
        teardown(generation: nil)
    }

    // MARK: Connection

    private func open(after delay: Double) {
        lock.lock()
        generation += 1
        let gen = generation
        lock.unlock()
        let worker = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard let self, self.isCurrent(gen) else { return }
            let token: String
            do {
                token = try await self.tokenProvider()
            } catch {
                self.fail(gen)
                return
            }
            guard self.isCurrent(gen) else { return }
            let socket = self.http.webSocketTask(with: self.socketURL)
            self.lock.withLock {
                self.socket = socket
                self.sentToken = token
                self.pendingHeartbeat = nil
            }
            socket.resume()
            self.receive(gen, socket)
            self.startHeartbeat(gen)
            let ref = self.nextRef()
            self.lock.withLock { self.joinRef = ref }
            self.send(gen, event: "phx_join", ref: ref, joinRef: ref, payload: [
                "config": [
                    "broadcast": ["self": false],
                    "presence": ["key": ""],
                    "postgres_changes": [["event": "INSERT", "schema": "public", "table": "clips"],
                                         ["event": "UPDATE", "schema": "public", "table": "clips"]],
                ],
                "access_token": token,
            ])
        }
        lock.lock(); workers.append(worker); lock.unlock()
    }

    private func isCurrent(_ gen: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return wanted && gen == generation
    }

    private func nextRef() -> String {
        lock.lock(); defer { lock.unlock() }
        ref += 1
        return String(ref)
    }

    /// Drop the socket of `generation` (any when nil) and report disconnected if it was joined.
    private func teardown(generation gen: Int?) {
        lock.lock()
        if let gen, gen != generation { lock.unlock(); return }
        generation += 1
        let wasJoined = joined
        joined = false
        let oldSocket = socket
        socket = nil
        let oldWorkers = workers
        workers = []
        let callback = _onStateChange
        lock.unlock()
        oldSocket?.cancel(with: .goingAway, reason: nil)
        oldWorkers.forEach { $0.cancel() }
        if wasJoined { callback?(false) }
    }

    /// Connection `gen` failed: drop it and retry with exponential backoff (1 s .. 60 s, jittered).
    private func fail(_ gen: Int) {
        lock.lock()
        guard gen == generation else { lock.unlock(); return }
        let retry = wanted
        let delay = min(60, pow(2, Double(attempt))) * Double.random(in: 0.8...1.2)
        attempt = min(attempt + 1, 6)
        lock.unlock()
        teardown(generation: gen)
        if retry { open(after: delay) }
    }

    // MARK: Messages

    private func receive(_ gen: Int, _ socket: URLSessionWebSocketTask) {
        let worker = Task { [weak self] in
            while !Task.isCancelled {
                let message: URLSessionWebSocketTask.Message
                do {
                    message = try await socket.receive()
                } catch {
                    self?.fail(gen)
                    return
                }
                guard let self else { return }
                let data: Data?
                switch message {
                case let .string(text): data = Data(text.utf8)
                case let .data(bytes): data = bytes
                @unknown default: data = nil
                }
                if let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    self.handle(gen, object)
                }
            }
        }
        lock.lock(); workers.append(worker); lock.unlock()
    }

    private func handle(_ gen: Int, _ message: [String: Any]) {
        let event = message["event"] as? String
        let ref = message["ref"] as? String
        let payload = message["payload"] as? [String: Any]
        switch event {
        case "phx_reply":
            lock.lock()
            guard gen == generation else { lock.unlock(); return }
            if ref != nil, ref == pendingHeartbeat { pendingHeartbeat = nil }
            let isJoin = ref != nil && ref == joinRef
            let ok = payload?["status"] as? String == "ok"
            var callback: (@Sendable (Bool) -> Void)?
            if isJoin && ok && !joined {
                joined = true
                attempt = 0
                callback = _onStateChange
            }
            lock.unlock()
            callback?(true)
            if isJoin && !ok { fail(gen) }
        case "postgres_changes":
            guard message["topic"] as? String == Self.topic, isCurrent(gen) else { return }
            onChange?()
        case "phx_error", "phx_close":
            if message["topic"] as? String == Self.topic { fail(gen) }
        case "system":
            // Token expiry and subscription errors arrive as {status: "error"}; rejoin with a fresh token.
            if message["topic"] as? String == Self.topic, payload?["status"] as? String == "error" { fail(gen) }
        default:
            break
        }
    }

    private func startHeartbeat(_ gen: Int) {
        let worker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.heartbeatInterval * 1_000_000_000)
                guard let self, !Task.isCancelled, self.isCurrent(gen) else { return }
                let missed = self.lock.withLock { self.pendingHeartbeat != nil }
                if missed { self.fail(gen); return }
                let ref = self.nextRef()
                self.lock.withLock { self.pendingHeartbeat = ref }
                self.send(gen, topic: "phoenix", event: "heartbeat", ref: ref, payload: [:])
                await self.refreshToken(gen)
            }
        }
        lock.lock(); workers.append(worker); lock.unlock()
    }

    /// Push a refreshed JWT to the channel before the old one expires.
    private func refreshToken(_ gen: Int) async {
        guard let token = try? await tokenProvider(), isCurrent(gen) else { return }
        let (changed, joinRef) = lock.withLock {
            let changed = joined && token != sentToken
            if changed { sentToken = token }
            return (changed, self.joinRef)
        }
        if changed { send(gen, event: "access_token", ref: nextRef(), joinRef: joinRef, payload: ["access_token": token]) }
    }

    private func send(_ gen: Int, topic: String = RealtimeClient.topic, event: String, ref: String, joinRef: String? = nil,
                      payload: [String: Any]) {
        lock.lock()
        let socket = gen == generation ? self.socket : nil
        lock.unlock()
        guard let socket else { return }
        var message: [String: Any] = ["topic": topic, "event": event, "payload": payload, "ref": ref]
        if let joinRef { message["join_ref"] = joinRef }
        guard let data = try? JSONSerialization.data(withJSONObject: message), let text = String(data: data, encoding: .utf8)
        else { return }
        socket.send(.string(text)) { [weak self] error in
            if error != nil { self?.fail(gen) }
        }
    }
}
