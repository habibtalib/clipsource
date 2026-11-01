@testable import ClipCore
import SQLite3
import XCTest

/// In-memory `SyncTransport` with the server rules of supabase/migrations: upsert by hash keeping the row id,
/// one `now()` per statement (every row of a batch gets the same `updated_at`), keyset fetch on (updated_at, id),
/// deleted rows kept as tombstones, optionally the no-revive trigger, and (when `registeredDevices` is set) writes
/// refused unless `device_id` is a registered device.
final class FakeTransport: SyncTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [String: RemoteClip] = [:]
    private var keyRecord: SyncKeyRecord?
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private(set) var upsertCalls = 0
    private(set) var fetchCalls = 0
    /// nil accepts any writer.
    var registeredDevices: Set<String>?
    /// clips_tombstone_guard: a live row no newer than the tombstone keeps the tombstone and its `updated_at`.
    var noRevive = false
    /// clips row cap: an upsert that would exceed it fails as a whole with `row_limit`.
    var rowLimit: Int?

    var allRows: [RemoteClip] { lock.withLock { Array(rows.values) } }

    func fetchKeyRecord() async throws -> SyncKeyRecord? { lock.withLock { keyRecord } }

    func createKeyRecord(_ record: SyncKeyRecord) async throws { lock.withLock { keyRecord = record } }

    func setKeyRecord(_ record: SyncKeyRecord) { lock.withLock { keyRecord = record } }

    func upsert(_ rows: [RemoteClip]) async throws {
        try lock.withLock {
            if let registered = registeredDevices, !rows.allSatisfy({ $0.deviceId.map(registered.contains) ?? false }) {
                throw SupabaseError.http(403, "new row violates row-level security policy for table \"clips\"")
            }
            upsertCalls += 1
            if let rowLimit, Set(self.rows.keys).union(rows.map(\.hash)).count > rowLimit {
                throw SupabaseError.rejected("row_limit", detail: "Synced history is limited to \(rowLimit) entries on this plan.")
            }
            clock = clock.addingTimeInterval(0.001)
            for var row in rows {
                let existing = self.rows[row.hash]
                if noRevive, let existing, existing.deleted, !row.deleted, row.createdAt <= existing.createdAt {
                    self.rows[row.hash] = RemoteClip(hash: existing.hash, payload: existing.payload, createdAt: existing.createdAt,
                                                     updatedAt: existing.updatedAt, deleted: true, deviceId: row.deviceId,
                                                     id: existing.id)
                    continue
                }
                row.id = existing?.id ?? UUID().uuidString.lowercased()
                row.updatedAt = clock
                self.rows[row.hash] = row
            }
        }
    }

    func fetch(after cursor: SyncCursor?, limit: Int) async throws -> [RemoteClip] {
        lock.withLock {
            fetchCalls += 1
            return Array(rows.values.filter { row in
                guard let cursor else { return true }
                guard let id = cursor.id else { return row.updatedAt! >= cursor.updatedAt }
                return SyncCursor(updatedAt: row.updatedAt!, id: row.id!) > SyncCursor(updatedAt: cursor.updatedAt, id: id)
            }
            .sorted { SyncCursor(updatedAt: $0.updatedAt!, id: $0.id!) < SyncCursor(updatedAt: $1.updatedAt!, id: $1.id!) }
            .prefix(limit))
        }
    }

    func deleteOlder(than date: Date) async throws {
        lock.withLock { rows = rows.filter { $0.value.createdAt >= date } }
    }

    func deleteAll() async throws {
        lock.withLock {
            rows = [:]
            keyRecord = nil
        }
    }
}

private struct Vector: Decodable {
    var passphrase, salt, master, hash, text, payloadJSON, payload, nonce, check: String
    var iterations: Int
}

final class SyncCryptoTests: XCTestCase {
    private func vector() throws -> Vector {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "sync-vector", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Vector.self, from: Data(contentsOf: url))
    }

    func testVector() throws {
        let v = try vector()
        let key = try SyncKey.derive(passphrase: v.passphrase, salt: XCTUnwrap(Data(base64Encoded: v.salt)), iterations: v.iterations)
        XCTAssertEqual(key.master.base64EncodedString(), v.master)
        XCTAssertEqual(key.hash(v.text), v.hash)
        let expected = try JSONDecoder().decode(SyncPayload.self, from: Data(v.payloadJSON.utf8))
        XCTAssertEqual(try key.openPayload(v.payload), expected)
        XCTAssertEqual(try key.sealPayload(expected, nonce: XCTUnwrap(Data(base64Encoded: v.nonce))), v.payload)
        XCTAssertTrue(key.verify(check: v.check))
    }

    func testWrongPassphraseFailsVerify() throws {
        let v = try vector()
        let key = try SyncKey.derive(passphrase: "wrong", salt: XCTUnwrap(Data(base64Encoded: v.salt)), iterations: v.iterations)
        XCTAssertFalse(key.verify(check: v.check))
        XCTAssertThrowsError(try key.openPayload(v.payload))
    }
}

final class SyncStoreTests: XCTestCase {
    private var dir: URL!
    private var store: ClipStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("clipsource-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = try ClipStore(url: dir.appendingPathComponent("history.sqlite"))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: dir)
    }

    func testMigrationFromV1() throws {
        let url = dir.appendingPathComponent("v1.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        let sql = """
        CREATE TABLE entries(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            text TEXT NOT NULL,
            hash TEXT NOT NULL,
            created_at REAL NOT NULL,
            origin TEXT NOT NULL,
            app TEXT, bundle_id TEXT, window_title TEXT,
            label TEXT, session TEXT, cwd TEXT, terminal TEXT
        );
        CREATE INDEX idx_entries_created ON entries(created_at DESC);
        CREATE UNIQUE INDEX idx_entries_hash ON entries(hash);
        CREATE VIRTUAL TABLE entries_fts USING fts5(
            text, label, window_title, app, content='entries', content_rowid='id'
        );
        CREATE TRIGGER entries_ai AFTER INSERT ON entries BEGIN
            INSERT INTO entries_fts(rowid, text, label, window_title, app)
            VALUES (new.id, new.text, new.label, new.window_title, new.app);
        END;
        CREATE TRIGGER entries_ad AFTER DELETE ON entries BEGIN
            INSERT INTO entries_fts(entries_fts, rowid, text, label, window_title, app)
            VALUES ('delete', old.id, old.text, old.label, old.window_title, old.app);
        END;
        CREATE TRIGGER entries_au AFTER UPDATE ON entries BEGIN
            INSERT INTO entries_fts(entries_fts, rowid, text, label, window_title, app)
            VALUES ('delete', old.id, old.text, old.label, old.window_title, old.app);
            INSERT INTO entries_fts(rowid, text, label, window_title, app)
            VALUES (new.id, new.text, new.label, new.window_title, new.app);
        END;
        PRAGMA user_version = 1;
        INSERT INTO entries(text, hash, created_at, origin, app, label)
        VALUES ('legacy entry', '\(ClipHash.of("legacy entry"))', 100, 'cli', 'Terminal', 'old label');
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let migrated = try ClipStore(url: url)
        let entry = try XCTUnwrap(migrated.recent().first)
        XCTAssertEqual(entry.text, "legacy entry")
        XCTAssertNil(entry.device)
        XCTAssertEqual(try migrated.pendingCount(), 1)
        XCTAssertEqual(try migrated.search("legacy").map(\.text), ["legacy entry"])
        XCTAssertEqual(try migrated.search("old label").map(\.text), ["legacy entry"])
    }

    func testApplyRemoteNewerMovesToTop() throws {
        try store.record(text: "same", origin: .watch, source: ClipSourceInfo(app: "Safari"), at: Date(timeIntervalSince1970: 100))
        try store.record(text: "other", origin: .watch, source: ClipSourceInfo(app: "Notes"), at: Date(timeIntervalSince1970: 200))
        let moved = try store.applyRemote(text: "same", origin: .cli, source: ClipSourceInfo(app: "iTerm2"), device: "Mac B",
                                          createdAt: Date(timeIntervalSince1970: 300), remoteHash: "r1")
        XCTAssertNotNil(moved)
        let top = try XCTUnwrap(store.recent().first)
        XCTAssertEqual(top.text, "same")
        XCTAssertEqual(top.source.app, "iTerm2")
        XCTAssertEqual(top.device, "Mac B")
        XCTAssertEqual(top.origin, .cli)
    }

    func testApplyRemoteOlderKeepsLocal() throws {
        try store.record(text: "same", origin: .watch, source: ClipSourceInfo(app: "Safari"), at: Date(timeIntervalSince1970: 300))
        let result = try store.applyRemote(text: "same", origin: .cli, source: ClipSourceInfo(app: "iTerm2"), device: "Mac B",
                                           createdAt: Date(timeIntervalSince1970: 100), remoteHash: "r1")
        XCTAssertNil(result)
        let entry = try XCTUnwrap(store.recent().first)
        XCTAssertEqual(entry.source.app, "Safari")
        XCTAssertNil(entry.device)
    }

    func testApplyRemoteInsertsNeverDirty() throws {
        let inserted = try XCTUnwrap(store.applyRemote(text: "new", origin: .mcp, source: ClipSourceInfo(label: "L"), device: "Mac B",
                                                       createdAt: Date(timeIntervalSince1970: 100), remoteHash: "r1"))
        XCTAssertEqual(inserted.device, "Mac B")
        XCTAssertEqual(try store.count(), 1)
        XCTAssertEqual(try store.pendingCount(), 0)
    }

    func testDeleteTombstonesOnlySyncedRows() throws {
        let local = try store.record(text: "local", origin: .watch, source: ClipSourceInfo())
        let synced = try store.record(text: "synced", origin: .watch, source: ClipSourceInfo())
        try store.markSynced(id: synced.id, createdAt: synced.createdAt, remoteHash: "r-synced")
        XCTAssertEqual(try store.pendingCount(), 1)
        try store.delete(id: local.id)
        XCTAssertEqual(try store.pendingTombstones().count, 0)
        try store.delete(id: synced.id)
        XCTAssertEqual(try store.pendingTombstones().map(\.remoteHash), ["r-synced"])
    }

    func testClearTombstonesSyncedRows() throws {
        try store.record(text: "local", origin: .watch, source: ClipSourceInfo())
        try store.applyRemote(text: "remote", origin: .cli, source: ClipSourceInfo(), device: "Mac B",
                              createdAt: Date(timeIntervalSince1970: 100), remoteHash: "r1")
        try store.clear()
        XCTAssertEqual(try store.count(), 0)
        XCTAssertEqual(try store.pendingTombstones().map(\.remoteHash), ["r1"])
    }

    func testApplyRemoteKeepsNewerLocalTombstone() throws {
        let synced = try store.record(text: "deleted here", origin: .cli, source: ClipSourceInfo(), at: Date(timeIntervalSince1970: 100))
        try store.markSynced(id: synced.id, createdAt: synced.createdAt, remoteHash: "r1")
        try store.delete(id: synced.id, at: Date(timeIntervalSince1970: 500))
        XCTAssertNil(try store.applyRemote(text: "deleted here", origin: .cli, source: ClipSourceInfo(), device: "Mac B",
                                           createdAt: Date(timeIntervalSince1970: 100), remoteHash: "r1"))
        XCTAssertEqual(try store.count(), 0)
        XCTAssertEqual(try store.pendingTombstones().map(\.remoteHash), ["r1"])
        // A copy made after the delete wins and drops the tombstone.
        XCTAssertNotNil(try store.applyRemote(text: "deleted here", origin: .cli, source: ClipSourceInfo(), device: "Mac B",
                                              createdAt: Date(timeIntervalSince1970: 600), remoteHash: "r1"))
        XCTAssertEqual(try store.count(), 1)
        XCTAssertTrue(try store.pendingTombstones().isEmpty)
    }

    func testApplyRemoteDelete() throws {
        try store.applyRemote(text: "remote", origin: .cli, source: ClipSourceInfo(), device: "Mac B",
                              createdAt: Date(timeIntervalSince1970: 100), remoteHash: "r1")
        XCTAssertFalse(try store.applyRemoteDelete(remoteHash: "nope"))
        XCTAssertTrue(try store.applyRemoteDelete(remoteHash: "r1"))
        XCTAssertEqual(try store.count(), 0)
        XCTAssertEqual(try store.pendingCount(), 0)
    }
}

@MainActor
final class SyncEngineTests: XCTestCase {
    private var dir: URL!
    private var transport: FakeTransport!
    private var storeA: ClipStore!
    private var storeB: ClipStore!
    private var engineA: SyncEngine!
    private var engineB: SyncEngine!
    private let deviceA = SyncDevice(id: "aaaa", name: "Mac A")
    private let deviceB = SyncDevice(id: "bbbb", name: "Mac B")

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("clipsource-engine-\(UUID().uuidString)")
        transport = FakeTransport()
        SyncEngine.acceptedIterations = 1000...10_000_000
        storeA = try ClipStore(url: dir.appendingPathComponent("a/history.sqlite"))
        storeB = try ClipStore(url: dir.appendingPathComponent("b/history.sqlite"))
        let key = try await SyncEngine.unlock(passphrase: "secret", transport: transport, iterations: 1000)
        engineA = SyncEngine(store: storeA, transport: transport, key: key, device: deviceA)
        engineB = SyncEngine(store: storeB, transport: transport, key: key, device: deviceB)
    }

    override func tearDown() async throws {
        SyncEngine.acceptedIterations = 100_000...10_000_000
        engineA = nil
        engineB = nil
        storeA = nil
        storeB = nil
        try? FileManager.default.removeItem(at: dir)
    }

    func testCopyReachesOtherDevice() async throws {
        try storeA.record(text: "hello", origin: .cli, source: ClipSourceInfo(app: "iTerm2", label: "reply"), at: Date(timeIntervalSince1970: 100))
        let resultA = try await engineA.sync()
        XCTAssertEqual(resultA.pushed, 1)
        XCTAssertEqual(try storeA.pendingCount(), 0)
        let resultB = try await engineB.sync()
        XCTAssertEqual(resultB.applied.map(\.text), ["hello"])
        let entry = try XCTUnwrap(storeB.recent().first)
        XCTAssertEqual(entry.device, "Mac A")
        XCTAssertEqual(entry.source.label, "reply")
        XCTAssertEqual(entry.createdAt.timeIntervalSince1970, 100, accuracy: 0.001)
        XCTAssertEqual(try storeB.pendingCount(), 0)
        XCTAssertTrue(transport.allRows.allSatisfy { $0.payload?.contains("hello") != true })
    }

    func testDeleteReachesOtherDevice() async throws {
        try storeA.record(text: "doomed", origin: .cli, source: ClipSourceInfo())
        _ = try await engineA.sync()
        _ = try await engineB.sync()
        let onB = try XCTUnwrap(storeB.recent().first)
        try storeB.delete(id: onB.id)
        _ = try await engineB.sync()
        let resultA = try await engineA.sync()
        XCTAssertEqual(resultA.deleted, 1)
        XCTAssertEqual(try storeA.count(), 0)
        XCTAssertEqual(try storeA.pendingCount(), 0)
    }

    func testEchoDoesNotChangeOrRedirty() async throws {
        let source = ClipSourceInfo(app: "Safari", windowTitle: "Docs")
        try storeA.record(text: "mine", origin: .watch, source: source, at: Date(timeIntervalSince1970: 100))
        let first = try await engineA.sync()
        XCTAssertTrue(first.applied.isEmpty)
        let second = try await engineA.sync()
        XCTAssertEqual(second.pushed, 0)
        XCTAssertTrue(second.applied.isEmpty)
        let entry = try XCTUnwrap(storeA.recent().first)
        XCTAssertEqual(entry.source, source)
        XCTAssertNil(entry.device)
        XCTAssertEqual(try storeA.pendingCount(), 0)
    }

    func testTouchOnOtherDeviceMovesUp() async throws {
        try storeA.record(text: "first", origin: .cli, source: ClipSourceInfo(label: "keep"), at: Date(timeIntervalSince1970: 100))
        try storeA.record(text: "second", origin: .cli, source: ClipSourceInfo(), at: Date(timeIntervalSince1970: 200))
        _ = try await engineA.sync()
        _ = try await engineB.sync()
        let firstOnB = try XCTUnwrap(storeB.recent().first { $0.text == "first" })
        try storeB.touch(id: firstOnB.id, at: Date(timeIntervalSince1970: 300))
        _ = try await engineB.sync()
        let resultA = try await engineA.sync()
        XCTAssertEqual(resultA.applied.map(\.text), ["first"])
        let recentA = try storeA.recent()
        XCTAssertEqual(recentA.map(\.text), ["first", "second"])
        XCTAssertEqual(recentA[0].source.label, "keep")
        XCTAssertNil(recentA[0].device, "an entry made on A comes back as local")
        XCTAssertEqual(try storeA.pendingCount(), 0)
        // B keeps the original device after the round trip.
        _ = try await engineB.sync()
        XCTAssertEqual(try storeB.recent().first?.device, "Mac A")
    }

    func testAppliedNewestFirstAndPagination() async throws {
        let count = SyncEngine.pageSize + 1
        for i in 0..<count {
            try storeA.record(text: "entry \(i)", origin: .cli, source: ClipSourceInfo(), at: Date(timeIntervalSince1970: Double(1000 + i)))
        }
        let resultA = try await engineA.sync()
        XCTAssertEqual(resultA.pushed, count)
        let resultB = try await engineB.sync()
        XCTAssertEqual(resultB.applied.count, count)
        XCTAssertEqual(resultB.applied.first?.text, "entry \(count - 1)")
        XCTAssertEqual(try storeB.count(), count)
        XCTAssertNotNil(try storeB.meta(SyncEngine.cursorKey))
    }

    func testUnlockCreatesThenVerifies() async throws {
        let fresh = FakeTransport()
        let created = try await SyncEngine.unlock(passphrase: "pw", transport: fresh, iterations: 1000)
        let record = try await fresh.fetchKeyRecord()
        XCTAssertEqual(record?.iterations, 1000)
        let again = try await SyncEngine.unlock(passphrase: "pw", transport: fresh, iterations: 1000)
        XCTAssertEqual(again.master, created.master)
        do {
            _ = try await SyncEngine.unlock(passphrase: "nope", transport: fresh, iterations: 1000)
            XCTFail("wrong passphrase must throw")
        } catch SyncCryptoError.wrongPassphrase {
        }
    }

    func testUndecryptableRowSkipped() async throws {
        let other = try SyncKey.derive(passphrase: "other", salt: SyncKey.randomSalt(), iterations: 1000)
        let foreign = try other.sealPayload(SyncPayload(text: "foreign", origin: .cli, source: ClipSourceInfo(),
                                                        createdAt: 100, deviceId: "x", deviceName: "X"))
        try await transport.upsert([
            RemoteClip(hash: "garbage", payload: "not base64!", createdAt: Date()),
            RemoteClip(hash: "foreign", payload: foreign, createdAt: Date()),
        ])
        try storeA.record(text: "good", origin: .cli, source: ClipSourceInfo())
        _ = try await engineA.sync()
        let resultB = try await engineB.sync()
        XCTAssertEqual(resultB.applied.map(\.text), ["good"])
        XCTAssertEqual(engineB.lastSkipped, 2)
    }

    func testRowsCarryDeviceId() async throws {
        transport.registeredDevices = [deviceA.id]
        try storeA.record(text: "tagged", origin: .cli, source: ClipSourceInfo())
        _ = try await engineA.sync()
        let onA = try XCTUnwrap(storeA.recent().first)
        try storeA.delete(id: onA.id)
        _ = try await engineA.sync()
        XCTAssertEqual(transport.allRows.map(\.deviceId), [deviceA.id], "tombstones carry the device id too")
        XCTAssertEqual(transport.allRows.first?.deleted, true)

        try storeB.record(text: "unregistered", origin: .cli, source: ClipSourceInfo())
        do {
            _ = try await engineB.sync()
            XCTFail("an unregistered device must be refused")
        } catch SupabaseError.http(403, _) {
        }
        XCTAssertEqual(try storeB.pendingCount(), 1, "a refused push stays pending")
    }

    func testPagesThroughRowsSharingOneTimestamp() async throws {
        let count = 1200
        for i in 0..<count {
            try storeA.record(text: "bulk \(i)", origin: .cli, source: ClipSourceInfo(), at: Date(timeIntervalSince1970: Double(1000 + i)))
        }
        let resultA = try await engineA.push()
        XCTAssertEqual(resultA, count)
        XCTAssertEqual(transport.upsertCalls, 3, "500 + 500 + 200, each batch one updated_at")
        XCTAssertEqual(Set(transport.allRows.map(\.updatedAt)).count, 3)
        let resultB = try await engineB.sync()
        XCTAssertEqual(resultB.applied.count, count)
        XCTAssertEqual(try storeB.count(), count)
        let cursor = try XCTUnwrap(storeB.meta(SyncEngine.cursorKey).flatMap(SyncCursor.init(stored:)))
        XCTAssertNotNil(cursor.id)
        let again = try await engineB.sync()
        XCTAssertTrue(again.applied.isEmpty)
    }

    func testLegacyCursorStringStillWorks() async throws {
        try storeA.record(text: "after upgrade", origin: .cli, source: ClipSourceInfo())
        _ = try await engineA.push()
        // Pre-keyset cursor: a bare ISO string from before the row was written.
        try storeB.setMeta(SyncEngine.cursorKey, "2027-01-15T08:00:00.000Z")
        let result = try await engineB.pull()
        XCTAssertEqual(result.applied.map(\.text), ["after upgrade"])
        let stored = try XCTUnwrap(storeB.meta(SyncEngine.cursorKey))
        XCTAssertTrue(stored.hasPrefix("{"))
        XCTAssertNotNil(SyncCursor(stored: stored)?.id)
        XCTAssertEqual(SyncCursor(stored: stored), SyncCursor(stored: SyncCursor(stored: stored)!.stored))
    }

    func testReunlockDoesNotReviveRemoteDeletes() async throws {
        try storeA.record(text: "doomed", origin: .cli, source: ClipSourceInfo(), at: Date(timeIntervalSince1970: 100))
        _ = try await engineA.sync()
        _ = try await engineB.sync()
        // A deletes while B is locked; B then re-unlocks and re-uploads everything.
        let onA = try XCTUnwrap(storeA.recent().first)
        try storeA.delete(id: onA.id)
        _ = try await engineA.sync()
        try storeB.markAllDirty()
        let result = try await engineB.sync(pullFirst: true)
        XCTAssertEqual(result.deleted, 1)
        XCTAssertEqual(try storeB.count(), 0)
        XCTAssertEqual(transport.allRows.first?.deleted, true)
        _ = try await engineA.sync()
        XCTAssertEqual(try storeA.count(), 0)
    }

    func testFirstSyncPullsFirstAndDropsCopiesTheServerDeleted() async throws {
        transport.noRevive = true
        try storeA.record(text: "gone", origin: .cli, source: ClipSourceInfo(), at: Date(timeIntervalSince1970: 100))
        _ = try await engineA.sync()
        let onA = try XCTUnwrap(storeA.recent().first)
        try storeA.delete(id: onA.id, at: Date(timeIntervalSince1970: 200))
        _ = try await engineA.sync()
        // B never pulled and holds an older unsynced copy of the same text, plus one new entry.
        try storeB.record(text: "gone", origin: .cli, source: ClipSourceInfo(), at: Date(timeIntervalSince1970: 50))
        try storeB.record(text: "fresh", origin: .cli, source: ClipSourceInfo(), at: Date(timeIntervalSince1970: 300))
        let result = try await engineB.sync()
        XCTAssertEqual(result.pushed, 1, "only the new entry is uploaded")
        XCTAssertEqual(try storeB.recent().map(\.text), ["fresh"])
        XCTAssertEqual(try storeB.pendingCount(), 0)
        let gone = try XCTUnwrap(transport.allRows.first { $0.hash == engineA.key.hash("gone") })
        XCTAssertTrue(gone.deleted)
    }

    func testServerKeptTombstoneIsTolerated() async throws {
        transport.noRevive = true
        try storeA.record(text: "stale", origin: .cli, source: ClipSourceInfo(), at: Date(timeIntervalSince1970: 100))
        _ = try await engineA.sync()
        _ = try await engineB.sync()
        let onA = try XCTUnwrap(storeA.recent().first)
        try storeA.delete(id: onA.id, at: Date(timeIntervalSince1970: 200))
        _ = try await engineA.sync()
        // B re-uploads without pulling first: the push succeeds, the server keeps the tombstone, B's pull removes it.
        try storeB.markAllDirty()
        _ = try await engineB.sync()
        XCTAssertEqual(transport.allRows.first?.deleted, true)
        XCTAssertEqual(try storeB.count(), 0)
        XCTAssertEqual(try storeB.pendingCount(), 0)
    }

    func testUnlockRefusesUnsupportedIterations() async throws {
        SyncEngine.acceptedIterations = 100_000...10_000_000
        for bad in [-1, 0, 1000, 50_000_000] {
            let fake = FakeTransport()
            fake.setKeyRecord(SyncKeyRecord(salt: SyncKey.randomSalt().base64EncodedString(), check: "x", iterations: bad))
            do {
                _ = try await SyncEngine.unlock(passphrase: "pw", transport: fake)
                XCTFail("iterations \(bad) must be refused")
            } catch SyncCryptoError.unsupportedIterations(let n) {
                XCTAssertEqual(n, bad)
            }
        }
        XCTAssertThrowsError(try SyncKey.derive(passphrase: "pw", salt: Data([1]), iterations: 0))
        XCTAssertThrowsError(try SyncKey.derive(passphrase: "pw", salt: Data([1]), iterations: -1))
    }

    func testPayloadMovedToAnotherRowIsSkipped() async throws {
        let key = engineA.key
        let sealed = try key.sealPayload(SyncPayload(text: "real text", origin: .cli, source: ClipSourceInfo(),
                                                     createdAt: 100, deviceId: "x", deviceName: "X"))
        try await transport.upsert([RemoteClip(hash: key.hash("other text"), payload: sealed, createdAt: Date())])
        let result = try await engineB.pull()
        XCTAssertTrue(result.applied.isEmpty)
        XCTAssertEqual(engineB.lastSkipped, 1)
        XCTAssertEqual(try storeB.count(), 0)
    }

    func testRowLimitStopsPushButStillPulls() async throws {
        try storeB.record(text: "from B", origin: .cli, source: ClipSourceInfo())
        _ = try await engineB.sync()
        transport.rowLimit = 3
        for i in 0..<5 { try storeA.record(text: "over \(i)", origin: .cli, source: ClipSourceInfo()) }
        for _ in 0..<2 {
            let calls = transport.upsertCalls
            do {
                _ = try await engineA.sync()
                XCTFail("row_limit must surface")
            } catch let error as SupabaseError {
                XCTAssertEqual(error, .rejected("row_limit", detail: "Synced history is limited to 3 entries on this plan."))
                XCTAssertTrue("\(error)".contains("limited to 3 entries"))
            }
            XCTAssertEqual(transport.upsertCalls, calls + 1, "one attempt per sync, no retry loop")
            XCTAssertEqual(try storeA.pendingCount(), 5, "refused rows stay pending")
        }
        XCTAssertEqual(try storeA.recent().first { $0.text == "from B" }?.device, "Mac B", "the pull still ran")
    }

    func testOversizedEntryStaysLocal() async throws {
        try storeA.record(text: String(repeating: "x", count: 1_300_000), origin: .cli, source: ClipSourceInfo(), at: Date(timeIntervalSince1970: 100))
        try storeA.record(text: "small", origin: .cli, source: ClipSourceInfo(), at: Date(timeIntervalSince1970: 200))
        let pushed = try await engineA.push()
        XCTAssertEqual(pushed, 1)
        XCTAssertEqual(engineA.lastOversized, 1)
        XCTAssertEqual(try storeA.pendingCount(), 0)
        XCTAssertEqual(try storeA.count(), 2)
        XCTAssertEqual(transport.allRows.count, 1)
    }

    func testPruneRemote() async throws {
        try storeA.record(text: "old", origin: .cli, source: ClipSourceInfo(), at: Date(timeIntervalSince1970: 100))
        try storeA.record(text: "new", origin: .cli, source: ClipSourceInfo(), at: Date(timeIntervalSince1970: 500))
        _ = try await engineA.push()
        try await engineA.pruneRemote(olderThan: Date(timeIntervalSince1970: 300))
        XCTAssertEqual(transport.allRows.count, 1)
    }
}

final class CloudAccountTests: XCTestCase {
    func testDeviceLimitMapsToError() {
        let json = #"{"ok":false,"error":"device_limit","plan":"free","device_limit":2,"devices_used":2}"#
        XCTAssertThrowsError(try SupabaseClient.checkOK(Data(json.utf8))) { error in
            XCTAssertEqual(error as? SupabaseError, .deviceLimit(2))
            XCTAssertEqual("\(error)", "This account already has 2 Macs on the Free plan. Remove one or upgrade to Pro.")
        }
    }

    func testOtherRPCErrorsAreRejected() {
        XCTAssertThrowsError(try SupabaseClient.checkOK(Data(#"{"ok":false,"error":"invalid_kind"}"#.utf8))) { error in
            XCTAssertEqual(error as? SupabaseError, .rejected("invalid_kind"))
        }
        XCTAssertNoThrow(try SupabaseClient.checkOK(Data(#"{"ok":true}"#.utf8)))
        XCTAssertNoThrow(try SupabaseClient.checkOK(Data(#"{"plan":"free","retention_days":7}"#.utf8)))
    }

    func testKnownServerCodesAreRejected() {
        XCTAssertEqual(SupabaseClient.knownError(Data(#"{"error":"already_subscribed"}"#.utf8)), .rejected("already_subscribed"))
        XCTAssertEqual(SupabaseClient.knownError(Data(#"{"code":"P0001","message":"device_in_use"}"#.utf8)), .rejected("device_in_use"))
        XCTAssertEqual(SupabaseClient.knownError(Data(#"{"message":"web_limit"}"#.utf8)), .rejected("web_limit"))
        XCTAssertNil(SupabaseClient.knownError(Data(#"{"message":"duplicate key value"}"#.utf8)))
        XCTAssertThrowsError(try SupabaseClient.checkOK(Data(#"{"ok":false,"error":"device_in_use"}"#.utf8))) { error in
            XCTAssertEqual(error as? SupabaseError, .rejected("device_in_use"))
            XCTAssertEqual("\(error)", "This device ID is in use by another session; sign out and back in")
        }
        XCTAssertTrue("\(SupabaseError.rejected("web_limit"))".contains("web viewer"))
        XCTAssertTrue("\(SupabaseError.rejected("already_subscribed"))".contains("Pro subscription"))
    }

    func testLogoutEndsOnlyThisSession() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clipsource-logout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = SupabaseClient(url: URL(string: "http://127.0.0.1:54321/")!, anonKey: "anon",
                                    secrets: FileSecretStore(url: dir.appendingPathComponent("secrets.json")))
        let request = client.logoutRequest(token: "tok")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:54321/auth/v1/logout?scope=local")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }

    func testSessionRevokedSignsOut() {
        XCTAssertThrowsError(try SupabaseClient.checkOK(Data(#"{"ok":false,"error":"session_revoked"}"#.utf8))) { error in
            XCTAssertEqual(error as? SupabaseError, .sessionExpired)
        }
        XCTAssertEqual(SupabaseClient.knownError(Data(#"{"code":"P0001","message":"session_revoked"}"#.utf8)), .sessionExpired)
        XCTAssertEqual(SupabaseClient.knownError(Data(#"{"error":"session_revoked"}"#.utf8)), .sessionExpired)
    }

    func testAccountLimitsAndCurrentDevice() throws {
        let json = #"""
        {"plan":"free","device_limit":2,"web_device_limit":1,"max_rows":500,"rows_used":42,"retention_days":7,
         "devices":[{"device_id":"mac-1","name":"This Mac","kind":"mac","current":true},
                    {"device_id":"web-1","name":"Web","kind":"web"}]}
        """#
        let account = try JSONDecoder().decode(CloudAccount.self, from: Data(json.utf8))
        XCTAssertEqual(account.webDeviceLimit, 1)
        XCTAssertEqual(account.maxRows, 500)
        XCTAssertEqual(account.rowsUsed, 42)
        XCTAssertEqual(account.devices.map(\.current), [true, false])
        let old = try JSONDecoder().decode(CloudAccount.self, from: Data(#"{"plan":"pro","device_limit":null,"retention_days":365}"#.utf8))
        XCTAssertNil(old.webDeviceLimit)
        XCTAssertNil(old.maxRows)
        XCTAssertNil(old.rowsUsed)
    }

    func testRowLimitCarriesDetails() {
        let body = #"{"code":"P0001","details":"Synced history is limited to 500 entries on this plan.","hint":"Remove old entries or upgrade.","message":"row_limit"}"#
        let error = SupabaseClient.knownError(Data(body.utf8))
        XCTAssertEqual(error, .rejected("row_limit", detail: "Synced history is limited to 500 entries on this plan."))
        XCTAssertEqual(error.map { "\($0)" }, "Synced history is limited to 500 entries on this plan. Remove old entries or upgrade to Pro.")
        XCTAssertEqual("\(SupabaseError.rejected("row_limit"))", "Synced history is full on this plan. Remove old entries or upgrade to Pro.")
    }

    func testCheckViolationsAreReadable() {
        let size = #"{"code":"23514","details":null,"hint":null,"message":"new row for relation \"clips\" violates check constraint \"clips_payload_size\""}"#
        let hash = #"{"code":"23514","details":null,"hint":null,"message":"new row for relation \"clips\" violates check constraint \"clips_hash_format\""}"#
        let other = #"{"code":"23514","message":"new row for relation \"clips\" violates check constraint \"clips_device_id_length\""}"#
        XCTAssertEqual(SupabaseClient.knownError(Data(size.utf8)), .rejected("payload_too_large"))
        XCTAssertEqual("\(SupabaseError.rejected("payload_too_large"))", "An entry is too large to sync")
        XCTAssertEqual(SupabaseClient.knownError(Data(hash.utf8)), .rejected("invalid_hash"))
        XCTAssertEqual(SupabaseClient.knownError(Data(other.utf8)).map { "\($0)" },
                       "new row for relation \"clips\" violates check constraint \"clips_device_id_length\"")
    }

    func testRegisterDeviceShape() throws {
        let json = #"{"ok":true,"plan":"free","device_limit":2,"devices_used":1,"retention_days":7}"#
        let account = try JSONDecoder().decode(CloudAccount.self, from: Data(json.utf8))
        XCTAssertEqual(account, CloudAccount(plan: "free", deviceLimit: 2, retentionDays: 7, devicesUsed: 1))
        XCTAssertFalse(account.isPro)
        XCTAssertEqual(account.planName, "Free")
        XCTAssertEqual(account.macCount, 1)
    }

    func testAccountStatusShape() throws {
        let json = #"""
        {"plan":"pro","subscription_status":"active","current_period_end":"2026-12-01T10:00:00+00:00",
         "device_limit":null,"retention_days":365,"devices_used":2,
         "devices":[{"device_id":"mac-1","name":"Office iMac","kind":"mac","last_seen_at":"2026-11-01T09:30:00.123456+00:00"},
                    {"device_id":"web-1","name":"Web (Safari)","kind":"web","last_seen_at":"2026-11-01 09:31:00+00"},
                    {"device_id":"mac-2","name":"MacBook","kind":"mac"}]}
        """#
        let account = try JSONDecoder().decode(CloudAccount.self, from: Data(json.utf8))
        XCTAssertTrue(account.isPro)
        XCTAssertNil(account.deviceLimit)
        XCTAssertEqual(account.retentionDays, 365)
        XCTAssertEqual(account.subscriptionStatus, "active")
        XCTAssertEqual(account.currentPeriodEnd, SupabaseClient.parseTimestamp("2026-12-01T10:00:00Z"))
        XCTAssertEqual(account.devices.map(\.name), ["Office iMac", "Web (Safari)", "MacBook"])
        XCTAssertEqual(account.devices[1].kind, "web")
        XCTAssertNotNil(account.devices[1].lastSeenAt)
        XCTAssertNil(account.devices[2].lastSeenAt)
        XCTAssertEqual(account.macCount, 2)
    }

    func testFreshAccountWithoutDevices() throws {
        let json = #"{"plan":"free","subscription_status":null,"current_period_end":null,"device_limit":2,"retention_days":7,"devices_used":0,"devices":[]}"#
        let account = try JSONDecoder().decode(CloudAccount.self, from: Data(json.utf8))
        XCTAssertNil(account.currentPeriodEnd)
        XCTAssertTrue(account.devices.isEmpty)
        XCTAssertEqual(account.macCount, 0)
    }

    func testRemoteClipEncodesDeviceId() throws {
        let row = RemoteClip(hash: "h", payload: nil, createdAt: Date(timeIntervalSince1970: 0), deleted: true, deviceId: "dev-1")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])
        XCTAssertEqual(object["device_id"] as? String, "dev-1")
        let decoded = try JSONDecoder().decode(RemoteClip.self, from: Data(#"{"hash":"h","created_at":0,"deleted":false}"#.utf8))
        XCTAssertNil(decoded.deviceId)
    }

    func testConfigCustomServerAndLegacyFiles() throws {
        let device = #""device":{"id":"d1","name":"Mac"}"#
        let legacyCustom = try JSONDecoder().decode(SyncConfig.self, from: Data(
            #"{"url":"http://127.0.0.1:54321","anonKey":"k","enabled":true,\#(device),"autoCopyRemote":false}"#.utf8))
        XCTAssertTrue(legacyCustom.customServer, "a v0.3 file with a URL was a custom server")
        XCTAssertEqual(legacyCustom.server?.url.absoluteString, "http://127.0.0.1:54321")
        XCTAssertEqual(legacyCustom.device.id, "d1")

        let cloud = try JSONDecoder().decode(SyncConfig.self, from: Data(#"{"enabled":false,\#(device)}"#.utf8))
        XCTAssertFalse(cloud.customServer)
        XCTAssertFalse(cloud.autoCopyRemote)
        XCTAssertEqual(cloud.isConfigured, ClipSourceCloud.isConfigured)

        var custom = cloud
        custom.customServer = true
        XCTAssertNil(custom.server, "custom server without a URL is not configured")
        custom.url = "https://example.supabase.co"
        custom.anonKey = "anon"
        XCTAssertEqual(custom.server?.anonKey, "anon")
        let roundTrip = try JSONDecoder().decode(SyncConfig.self, from: JSONEncoder().encode(custom))
        XCTAssertEqual(roundTrip, custom)
    }
}
