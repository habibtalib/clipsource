import Foundation

/// Moves entries between the local store and a `SyncTransport`. Everything that leaves the Mac is sealed with
/// `key`; the server only sees HMAC hashes, ciphertext, timestamps and this device's opaque id.
@MainActor public final class SyncEngine {
    public struct Result: Sendable {
        public var pushed: Int
        /// Entries inserted or moved to the top by remote rows, newest first.
        public var applied: [ClipEntry]
        public var deleted: Int
    }

    static let cursorKey = "sync.cursor"
    static let pageSize = 500
    /// Re-fetch this far behind the cursor so rows committed out of order are not missed. Pull is idempotent.
    static let cursorOverlap: TimeInterval = 2
    /// Server limit on `clips.payload` (clips_payload_size). Larger entries stay local instead of failing the batch.
    static let maxPayloadLength = 1_572_864
    /// PBKDF2 iteration counts `unlock` accepts from a server key record. Tests lower it.
    static var acceptedIterations = 100_000...10_000_000

    public let store: ClipStore
    public let transport: SyncTransport
    public let key: SyncKey
    public let device: SyncDevice
    /// Rows the last pull could not decrypt (another key, or corrupt). They are skipped, never fatal.
    public private(set) var lastSkipped = 0
    /// Remote tombstones (hash -> deleted at) the last pull found no local row for. The next push drops local
    /// copies no newer than the delete instead of uploading them: the server would keep its tombstone anyway.
    /// Entries the last push kept local because their sealed payload exceeds `maxPayloadLength`.
    public private(set) var lastOversized = 0
    private var unmatchedTombstones: [String: Date] = [:]

    public init(store: ClipStore, transport: SyncTransport, key: SyncKey, device: SyncDevice) {
        self.store = store
        self.transport = transport
        self.key = key
        self.device = device
    }

    /// Upload dirty entries and tombstones. Returns the number of rows sent.
    /// A server refusal (`SupabaseError.rejected`, e.g. `row_limit`) stops the push and is thrown; the rows stay
    /// pending for a later sync.
    public func push() async throws -> Int {
        var pushed = 0
        var oversized = 0
        defer { lastOversized = oversized }
        while true {
            var batch = try store.pendingSync(limit: Self.pageSize)
            guard !batch.isEmpty else { break }
            let fullPage = batch.count == Self.pageSize
            batch = try batch.filter { entry in
                guard let deletedAt = unmatchedTombstones[key.hash(entry.text)], entry.createdAt <= deletedAt else { return true }
                try store.delete(id: entry.id)
                return false
            }
            var rows: [RemoteClip] = []
            var sent: [ClipEntry] = []
            for entry in batch {
                let row = RemoteClip(hash: key.hash(entry.text), payload: try key.sealPayload(payload(for: entry)),
                                     createdAt: entry.createdAt, deviceId: device.id)
                if (row.payload?.utf8.count ?? 0) > Self.maxPayloadLength {
                    // Never accepted by the server: mark it clean so it does not block every later batch.
                    try store.markSynced(id: entry.id, createdAt: entry.createdAt, remoteHash: row.hash)
                    oversized += 1
                    continue
                }
                rows.append(row)
                sent.append(entry)
            }
            if !rows.isEmpty { try await transport.upsert(rows) }
            for (entry, row) in zip(sent, rows) {
                try store.markSynced(id: entry.id, createdAt: entry.createdAt, remoteHash: row.hash)
            }
            pushed += rows.count
            if !fullPage { break }
        }
        unmatchedTombstones = [:]
        let tombstones = try store.pendingTombstones()
        if !tombstones.isEmpty {
            try await transport.upsert(tombstones.map {
                RemoteClip(hash: $0.remoteHash, payload: nil, createdAt: $0.deletedAt, deleted: true, deviceId: device.id)
            })
            try store.removeTombstones(tombstones.map(\.remoteHash))
            pushed += tombstones.count
        }
        return pushed
    }

    /// Apply remote changes since the saved cursor. The first page re-reads `cursorOverlap` behind it; later
    /// pages follow the (updated_at, id) keyset strictly, so a push that shares one `updated_at` cannot stall it.
    public func pull() async throws -> (applied: [ClipEntry], deleted: Int) {
        let saved = try store.meta(Self.cursorKey).flatMap(SyncCursor.init(stored:))
        var after = saved.map { SyncCursor(updatedAt: $0.updatedAt.addingTimeInterval(-Self.cursorOverlap), id: nil) }
        var newest = saved
        var applied: [Int64: ClipEntry] = [:]
        var deleted = 0
        var skipped = 0
        unmatchedTombstones = [:]
        while true {
            let page = try await transport.fetch(after: after, limit: Self.pageSize)
            for row in page {
                if let updated = row.updatedAt, let id = row.id {
                    let position = SyncCursor(updatedAt: updated, id: id)
                    if newest.map({ $0 < position }) ?? true { newest = position }
                }
                if row.deleted {
                    if try store.applyRemoteDelete(remoteHash: row.hash) {
                        deleted += 1
                    } else {
                        unmatchedTombstones[row.hash] = row.createdAt
                    }
                    continue
                }
                // The hash check binds the ciphertext to its row: a payload moved to another row is rejected.
                guard let sealed = row.payload, let payload = try? key.openPayload(sealed),
                      key.hash(payload.text) == row.hash else {
                    skipped += 1
                    continue
                }
                if let entry = try store.applyRemote(text: payload.text, origin: payload.origin, source: payload.source,
                                                     device: deviceName(of: payload),
                                                     createdAt: Date(timeIntervalSince1970: payload.createdAt),
                                                     remoteHash: row.hash) {
                    applied[entry.id] = entry
                }
            }
            // A full page means more rows may follow. Without a keyset position (no id) the next page cannot advance.
            guard page.count >= Self.pageSize, let last = page.last, let updated = last.updatedAt, let id = last.id else { break }
            let next = SyncCursor(updatedAt: updated, id: id)
            if let after, after.id != nil, !(after < next) { break }
            after = next
        }
        if let newest, newest != saved {
            try store.setMeta(Self.cursorKey, newest.stored)
        }
        lastSkipped = skipped
        // Entries deleted later in the same pull are gone; report only what still exists, newest first.
        let present = try applied.values.compactMap { try store.entry(id: $0.id) }
        return (present.sorted { $0.createdAt > $1.createdAt }, deleted)
    }

    /// Push, then pull. Pulls first when asked or when this store has never pulled, so a full re-upload
    /// (`markAllDirty` after unlock) sees remote deletes before it can overwrite them.
    public func sync(pullFirst: Bool = false) async throws -> Result {
        let neverPulled = try store.meta(Self.cursorKey) == nil
        if pullFirst || neverPulled {
            let (applied, deleted) = try await pull()
            let pushed = try await push()
            return Result(pushed: pushed, applied: applied, deleted: deleted)
        }
        // A refused push (e.g. row_limit) must not stop this device from receiving: pull, then report it.
        var pushed = 0
        var refusal: SupabaseError?
        do {
            pushed = try await push()
        } catch let error as SupabaseError {
            guard case .rejected = error else { throw error }
            refusal = error
        }
        let (applied, deleted) = try await pull()
        if let refusal { throw refusal }
        return Result(pushed: pushed, applied: applied, deleted: deleted)
    }

    /// Hard-delete remote rows created before `date` (retention).
    public func pruneRemote(olderThan date: Date) async throws {
        try await transport.deleteOlder(than: date)
    }

    /// Derive the sync key from the passphrase. The first device creates the key record (random salt and an
    /// encrypted check value); later devices verify against it. PBKDF2 runs off the main actor.
    public static func unlock(passphrase: String, transport: SyncTransport,
                              iterations: Int = SyncKey.defaultIterations) async throws -> SyncKey {
        if let record = try await transport.fetchKeyRecord() {
            // The record comes from the server: refuse counts that would be trivially weak or hang the Mac.
            guard acceptedIterations.contains(record.iterations) else {
                throw SyncCryptoError.unsupportedIterations(record.iterations)
            }
            guard let salt = Data(base64Encoded: record.salt) else { throw SyncCryptoError.keyDerivation }
            let key = try await Task.detached {
                try SyncKey.derive(passphrase: passphrase, salt: salt, iterations: record.iterations)
            }.value
            guard key.verify(check: record.check) else { throw SyncCryptoError.wrongPassphrase }
            return key
        }
        let salt = SyncKey.randomSalt()
        let key = try await Task.detached {
            try SyncKey.derive(passphrase: passphrase, salt: salt, iterations: iterations)
        }.value
        try await transport.createKeyRecord(SyncKeyRecord(salt: salt.base64EncodedString(), check: key.makeCheck(),
                                                          iterations: iterations))
        return key
    }

    // MARK: - Helpers

    /// An entry made here carries this device. One that came from elsewhere keeps its original device name;
    /// its id is unknown here, so it is sent empty.
    private func payload(for entry: ClipEntry) -> SyncPayload {
        SyncPayload(text: entry.text, origin: entry.origin, source: entry.source,
                    createdAt: entry.createdAt.timeIntervalSince1970,
                    deviceId: entry.device == nil ? device.id : "",
                    deviceName: entry.device ?? device.name)
    }

    /// nil when the payload was made on this device. An empty id with this device's name is one of our own
    /// entries re-pushed by another device (see `payload(for:)`).
    private func deviceName(of payload: SyncPayload) -> String? {
        if payload.deviceId == device.id { return nil }
        if payload.deviceId.isEmpty, payload.deviceName == device.name { return nil }
        return payload.deviceName
    }
}
