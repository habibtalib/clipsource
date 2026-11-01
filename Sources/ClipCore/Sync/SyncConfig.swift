import Foundation
import Security

/// Non-secret sync settings, in `sync.json` next to the history database (so `$CLIPSOURCE_DB` gives a
/// separate device for testing). The anon key is public by design; sessions and the key live in `SyncSecretStore`.
public struct SyncConfig: Codable, Equatable, Sendable {
    /// Self-hosted Supabase project; used only when `customServer` is on.
    public var url: String?
    public var anonKey: String?
    /// Use `url`/`anonKey` instead of ClipSource Cloud.
    public var customServer: Bool
    public var enabled: Bool
    public var device: SyncDevice
    /// Copy entries that arrive from other devices onto this Mac's clipboard.
    public var autoCopyRemote: Bool

    public init(url: String? = nil, anonKey: String? = nil, customServer: Bool = false, enabled: Bool = false,
                device: SyncDevice = SyncDevice(id: UUID().uuidString, name: SyncConfig.defaultDeviceName),
                autoCopyRemote: Bool = false) {
        self.url = url
        self.anonKey = anonKey
        self.customServer = customServer
        self.enabled = enabled
        self.device = device
        self.autoCopyRemote = autoCopyRemote
    }

    enum CodingKeys: String, CodingKey {
        case url, anonKey, customServer, enabled, device, autoCopyRemote
    }

    /// Tolerates files from v0.3 builds without `customServer`: a saved URL then means a custom server.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        anonKey = try c.decodeIfPresent(String.self, forKey: .anonKey)
        customServer = try c.decodeIfPresent(Bool.self, forKey: .customServer) ?? (url?.nilIfBlank != nil)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        device = try c.decode(SyncDevice.self, forKey: .device)
        autoCopyRemote = try c.decodeIfPresent(Bool.self, forKey: .autoCopyRemote) ?? false
    }

    public static var defaultDeviceName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    /// Supabase URL and anon key baked into the app's Info.plist (`ClipSourceSupabaseURL`, `ClipSourceSupabaseAnonKey`).
    public static var bundled: (url: String, anonKey: String)? {
        guard let url = Bundle.main.object(forInfoDictionaryKey: "ClipSourceSupabaseURL") as? String, !url.isEmpty,
              let key = Bundle.main.object(forInfoDictionaryKey: "ClipSourceSupabaseAnonKey") as? String, !key.isEmpty
        else { return nil }
        return (url, key)
    }

    /// The server sync talks to: the custom one, or ClipSource Cloud. Nil when that server is not set up.
    public var server: (url: URL, anonKey: String)? {
        if customServer {
            guard let raw = url?.nilIfBlank, let url = URL(string: raw), url.host != nil, let key = anonKey?.nilIfBlank
            else { return nil }
            return (url, key)
        }
        guard ClipSourceCloud.isConfigured, let url = URL(string: ClipSourceCloud.url) else { return nil }
        return (url, ClipSourceCloud.anonKey)
    }

    public var isConfigured: Bool { server != nil }

    public static func fileURL(storeURL: URL) -> URL {
        storeURL.deletingLastPathComponent().appendingPathComponent("sync.json")
    }

    /// Load, or create and save a fresh config with a new device ID.
    public static func load(storeURL: URL) -> SyncConfig {
        let file = fileURL(storeURL: storeURL)
        if let data = try? Data(contentsOf: file), let config = try? JSONDecoder().decode(SyncConfig.self, from: data) {
            return config
        }
        let config = SyncConfig()
        try? config.save(storeURL: storeURL)
        return config
    }

    public func save(storeURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: Self.fileURL(storeURL: storeURL), options: .atomic)
    }
}

/// Signed-in Supabase session.
public struct SyncSession: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var userId: String
    public var email: String?

    public init(accessToken: String, refreshToken: String, expiresAt: Date, userId: String, email: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.userId = userId
        self.email = email
    }
}

/// Where the session and the derived key are kept.
public protocol SyncSecretStore: AnyObject, Sendable {
    func read(_ name: String) -> Data?
    func write(_ name: String, _ data: Data) throws
    func delete(_ name: String)
}

public extension SyncSecretStore {
    static var sessionName: String { "session" }
    static var keyName: String { "key" }

    func session() -> SyncSession? {
        read("session").flatMap { try? JSONDecoder().decode(SyncSession.self, from: $0) }
    }

    func saveSession(_ session: SyncSession?) throws {
        if let session { try write("session", JSONEncoder().encode(session)) } else { delete("session") }
    }

    func syncKey() -> SyncKey? {
        read("key").flatMap { $0.count == 32 ? SyncKey(master: $0) : nil }
    }

    func saveSyncKey(_ key: SyncKey?) throws {
        if let key { try write("key", key.master) } else { delete("key") }
    }
}

public enum SyncSecrets {
    /// Keychain by default. `CLIPSOURCE_SYNC_SECRETS=file` uses `sync-secrets.json` (mode 0600) next to the database,
    /// for tests and for simulating a second device with `$CLIPSOURCE_DB`.
    public static func store(storeURL: URL) -> SyncSecretStore {
        if ProcessInfo.processInfo.environment["CLIPSOURCE_SYNC_SECRETS"] == "file" {
            return FileSecretStore(url: storeURL.deletingLastPathComponent().appendingPathComponent("sync-secrets.json"))
        }
        return KeychainSecretStore()
    }
}

public final class KeychainSecretStore: SyncSecretStore, @unchecked Sendable {
    let service: String

    public init(service: String = "dev.habibtalib.clipsource.sync") {
        self.service = service
    }

    private func base(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: name]
    }

    public func read(_ name: String) -> Data? {
        var query = base(name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    public func write(_ name: String, _ data: Data) throws {
        let status = SecItemUpdate(base(name) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base(name)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw ClipStoreError.sqlite("Keychain write failed (\(addStatus))") }
        } else if status != errSecSuccess {
            throw ClipStoreError.sqlite("Keychain write failed (\(status))")
        }
    }

    public func delete(_ name: String) {
        SecItemDelete(base(name) as CFDictionary)
    }
}

public final class FileSecretStore: SyncSecretStore, @unchecked Sendable {
    let url: URL
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
    }

    private func all() -> [String: String] {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    private func save(_ values: [String: String]) throws {
        try JSONEncoder().encode(values).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func read(_ name: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return all()[name].flatMap { Data(base64Encoded: $0) }
    }

    public func write(_ name: String, _ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        var values = all()
        values[name] = data.base64EncodedString()
        try save(values)
    }

    public func delete(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        var values = all()
        values[name] = nil
        try? save(values)
    }
}
