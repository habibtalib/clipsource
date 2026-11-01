import Foundation

/// Plaintext of one synced entry, encrypted into `RemoteClip.payload`. Field names are shared with the web viewer.
public struct SyncPayload: Codable, Equatable, Sendable {
    public var v: Int
    public var text: String
    public var origin: ClipOrigin
    public var source: ClipSourceInfo
    /// Seconds since 1970.
    public var createdAt: Double
    public var deviceId: String
    public var deviceName: String

    public init(v: Int = 1, text: String, origin: ClipOrigin, source: ClipSourceInfo, createdAt: Double,
                deviceId: String, deviceName: String) {
        self.v = v
        self.text = text
        self.origin = origin
        self.source = source
        self.createdAt = createdAt
        self.deviceId = deviceId
        self.deviceName = deviceName
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
    static let decoder = JSONDecoder()
}

/// A row of the `clips` table (supabase/migrations). Only `hash` (an HMAC), timestamps and the opaque
/// `deviceId` are readable by the server.
public struct RemoteClip: Codable, Equatable, Sendable {
    /// Server row id (uuid); the keyset tiebreak for rows with the same `updatedAt`. Set by the server, never pushed.
    public var id: String?
    public var hash: String
    /// Base64 AES-GCM `SyncPayload`; nil for a tombstone.
    public var payload: String?
    public var createdAt: Date
    /// Set by the server; nil when pushing.
    public var updatedAt: Date?
    public var deleted: Bool
    /// Random id of the registered device that wrote the row. The server only accepts writes from registered devices.
    public var deviceId: String?

    public init(hash: String, payload: String?, createdAt: Date, updatedAt: Date? = nil, deleted: Bool = false,
                deviceId: String? = nil, id: String? = nil) {
        self.id = id
        self.hash = hash
        self.payload = payload
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deleted = deleted
        self.deviceId = deviceId
    }

    enum CodingKeys: String, CodingKey {
        case id, hash, payload, deleted
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deviceId = "device_id"
    }
}

/// Keyset position in the `clips` feed: (updated_at, id). A push of many rows shares one `updated_at`, so the
/// id breaks ties. Stored as JSON in meta `sync.cursor`; a bare ISO 8601 string is the pre-keyset format.
public struct SyncCursor: Codable, Equatable, Comparable, Sendable {
    public var updatedAt: Date
    /// nil means "from `updatedAt` inclusive" (the overlap page).
    public var id: String?

    public init(updatedAt: Date, id: String?) {
        self.updatedAt = updatedAt
        self.id = id
    }

    public static func < (a: SyncCursor, b: SyncCursor) -> Bool {
        a.updatedAt != b.updatedAt ? a.updatedAt < b.updatedAt : (a.id ?? "") < (b.id ?? "")
    }

    enum CodingKeys: String, CodingKey { case updatedAt, id }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let text = try c.decode(String.self, forKey: .updatedAt)
        guard let date = SupabaseClient.parseTimestamp(text) else {
            throw DecodingError.dataCorruptedError(forKey: .updatedAt, in: c, debugDescription: "Bad timestamp \(text)")
        }
        updatedAt = date
        id = try c.decodeIfPresent(String.self, forKey: .id)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(SupabaseClient.formatTimestamp(updatedAt), forKey: .updatedAt)
        try c.encodeIfPresent(id, forKey: .id)
    }

    /// JSON, or the legacy ISO 8601 string (no id).
    public init?(stored: String) {
        if stored.hasPrefix("{") {
            guard let cursor = try? JSONDecoder().decode(SyncCursor.self, from: Data(stored.utf8)) else { return nil }
            self = cursor
        } else {
            guard let date = SupabaseClient.parseTimestamp(stored) else { return nil }
            self.init(updatedAt: date, id: nil)
        }
    }

    public var stored: String {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return String(decoding: (try? e.encode(self)) ?? Data(), as: UTF8.self)
    }
}

/// A row of `sync_keys`: the per-user PBKDF2 salt and an encrypted check value.
public struct SyncKeyRecord: Codable, Equatable, Sendable {
    /// Base64.
    public var salt: String
    public var check: String
    public var iterations: Int

    public init(salt: String, check: String, iterations: Int) {
        self.salt = salt
        self.check = check
        self.iterations = iterations
    }
}

/// The server side of sync. `SupabaseClient` implements it; tests use an in-memory fake.
public protocol SyncTransport: AnyObject, Sendable {
    func fetchKeyRecord() async throws -> SyncKeyRecord?
    func createKeyRecord(_ record: SyncKeyRecord) async throws
    /// Insert or replace rows by (user, hash).
    func upsert(_ rows: [RemoteClip]) async throws
    /// Rows after `cursor` ordered by (updated_at, id), at most `limit`. nil fetches from the start; a cursor
    /// without `id` fetches `updated_at >= cursor.updatedAt`.
    func fetch(after cursor: SyncCursor?, limit: Int) async throws -> [RemoteClip]
    /// Hard-delete rows created before `date` (retention).
    func deleteOlder(than date: Date) async throws
    /// Hard-delete every row and the key record of the signed-in user.
    func deleteAll() async throws
}

/// This device as other devices see it.
public struct SyncDevice: Codable, Equatable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public enum SyncStatus: Equatable, Sendable {
    case off
    /// Signed in but the passphrase has not been entered on this device.
    case locked
    case syncing
    case synced(Date)
    case error(String)
}
