import Foundation
import SQLite3

public enum ClipStoreError: Error, CustomStringConvertible {
    case sqlite(String)

    public var description: String {
        switch self {
        case let .sqlite(message): return "SQLite: \(message)"
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Clipboard history in SQLite (WAL, FTS5). Shared by the app, the CLI and the MCP server.
public final class ClipStore: @unchecked Sendable {
    public let url: URL
    private var db: OpaquePointer?

    /// `$CLIPSOURCE_DB`, else `~/Library/Application Support/ClipSource/history.sqlite`.
    public static var defaultURL: URL {
        if let path = ProcessInfo.processInfo.environment["CLIPSOURCE_DB"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ClipSource/history.sqlite")
    }

    public init(url: URL = ClipStore.defaultURL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(url.path)"
            sqlite3_close(db)
            throw ClipStoreError.sqlite(message)
        }
        sqlite3_busy_timeout(db, 3000)
        try exec("PRAGMA journal_mode=WAL;")
        try migrate()
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Schema

    private func migrate() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS entries(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            text TEXT NOT NULL,
            hash TEXT NOT NULL,
            created_at REAL NOT NULL,
            origin TEXT NOT NULL,
            app TEXT, bundle_id TEXT, window_title TEXT,
            label TEXT, session TEXT, cwd TEXT, terminal TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_entries_created ON entries(created_at DESC);
        CREATE UNIQUE INDEX IF NOT EXISTS idx_entries_hash ON entries(hash);
        CREATE VIRTUAL TABLE IF NOT EXISTS entries_fts USING fts5(
            text, label, window_title, app, content='entries', content_rowid='id'
        );
        CREATE TRIGGER IF NOT EXISTS entries_ai AFTER INSERT ON entries BEGIN
            INSERT INTO entries_fts(rowid, text, label, window_title, app)
            VALUES (new.id, new.text, new.label, new.window_title, new.app);
        END;
        CREATE TRIGGER IF NOT EXISTS entries_ad AFTER DELETE ON entries BEGIN
            INSERT INTO entries_fts(entries_fts, rowid, text, label, window_title, app)
            VALUES ('delete', old.id, old.text, old.label, old.window_title, old.app);
        END;
        CREATE TRIGGER IF NOT EXISTS entries_au AFTER UPDATE ON entries BEGIN
            INSERT INTO entries_fts(entries_fts, rowid, text, label, window_title, app)
            VALUES ('delete', old.id, old.text, old.label, old.window_title, old.app);
            INSERT INTO entries_fts(rowid, text, label, window_title, app)
            VALUES (new.id, new.text, new.label, new.window_title, new.app);
        END;
        """)
        if try userVersion() < 2 {
            // Sync (0.3): device of remote copies, dirty flag for pending pushes, remote HMAC hash,
            // tombstones for deletes that must reach other devices, and a key/value meta table.
            try exec("""
            BEGIN;
            ALTER TABLE entries ADD COLUMN device TEXT;
            ALTER TABLE entries ADD COLUMN dirty INTEGER NOT NULL DEFAULT 1;
            ALTER TABLE entries ADD COLUMN remote_hash TEXT;
            CREATE INDEX IF NOT EXISTS idx_entries_dirty ON entries(dirty) WHERE dirty = 1;
            CREATE INDEX IF NOT EXISTS idx_entries_remote ON entries(remote_hash);
            CREATE TABLE IF NOT EXISTS tombstones(remote_hash TEXT PRIMARY KEY, deleted_at REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
            PRAGMA user_version = 2;
            COMMIT;
            """)
        }
    }

    private func userVersion() throws -> Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        try prepare("PRAGMA user_version", [], &stmt)
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    // MARK: - Writes

    /// Insert `text`, or move an existing identical entry to the top with the new source.
    @discardableResult
    public func record(text: String, origin: ClipOrigin, source: ClipSourceInfo, at date: Date = Date()) throws -> ClipEntry {
        let hash = ClipHash.of(text)
        let s = source
        if let existing = try entry(hash: hash) {
            try run("""
            UPDATE entries SET created_at=?, origin=?, app=?, bundle_id=?, window_title=?,
                label=?, session=?, cwd=?, terminal=?, device=NULL, dirty=1 WHERE id=?
            """, [date.timeIntervalSince1970, origin.rawValue, s.app, s.bundleId, s.windowTitle,
                  s.label, s.session, s.cwd, s.terminal, existing.id])
            return try entry(id: existing.id)!
        }
        try run("""
        INSERT INTO entries(text, hash, created_at, origin, app, bundle_id, window_title, label, session, cwd, terminal)
        VALUES (?,?,?,?,?,?,?,?,?,?,?)
        """, [text, hash, date.timeIntervalSince1970, origin.rawValue, s.app, s.bundleId, s.windowTitle,
              s.label, s.session, s.cwd, s.terminal])
        return try entry(id: sqlite3_last_insert_rowid(db))!
    }

    /// Add the session and working folder found after the copy was recorded.
    public func updateContext(id: Int64, session: String?, cwd: String?) throws {
        try run("UPDATE entries SET session=?, cwd=?, dirty=1 WHERE id=?", [session, cwd, id])
    }

    /// Move an entry to the top, keeping its source (used when re-copying).
    public func touch(id: Int64, at date: Date = Date()) throws {
        try run("UPDATE entries SET created_at=?, dirty=1 WHERE id=?", [date.timeIntervalSince1970, id])
    }

    /// Delete an entry. A synced entry leaves a tombstone so the delete reaches other devices.
    public func delete(id: Int64, at date: Date = Date()) throws {
        try run("""
        INSERT OR REPLACE INTO tombstones(remote_hash, deleted_at)
        SELECT remote_hash, ? FROM entries WHERE id=? AND remote_hash IS NOT NULL
        """, [date.timeIntervalSince1970, id])
        try run("DELETE FROM entries WHERE id=?", [id])
    }

    /// Delete every entry, leaving tombstones for synced ones.
    public func clear(at date: Date = Date()) throws {
        try run("""
        INSERT OR REPLACE INTO tombstones(remote_hash, deleted_at)
        SELECT remote_hash, ? FROM entries WHERE remote_hash IS NOT NULL
        """, [date.timeIntervalSince1970])
        try run("DELETE FROM entries", [])
    }

    /// Delete entries copied at or after `since` (leaving tombstones for synced ones). Returns how many were removed.
    @discardableResult
    public func clear(since: Date, at date: Date = Date()) throws -> Int {
        let count = try scalarInt("SELECT COUNT(*) FROM entries WHERE created_at >= \(since.timeIntervalSince1970)")
        try run("""
        INSERT OR REPLACE INTO tombstones(remote_hash, deleted_at)
        SELECT remote_hash, ? FROM entries WHERE remote_hash IS NOT NULL AND created_at >= ?
        """, [date.timeIntervalSince1970, since.timeIntervalSince1970])
        try run("DELETE FROM entries WHERE created_at >= ?", [since.timeIntervalSince1970])
        return count
    }

    // MARK: - Sync

    /// Entries changed locally since their last push, oldest first.
    public func pendingSync(limit: Int = 500) throws -> [ClipEntry] {
        try query("SELECT \(Self.columns) FROM entries e WHERE e.dirty=1 ORDER BY e.created_at LIMIT ?", [Int64(limit)])
    }

    public func pendingCount() throws -> Int {
        try scalarInt("SELECT (SELECT COUNT(*) FROM entries WHERE dirty=1) + (SELECT COUNT(*) FROM tombstones)")
    }

    /// Mark a pushed entry clean, unless it changed again after it was read (`createdAt` moved).
    public func markSynced(id: Int64, createdAt: Date, remoteHash: String) throws {
        try run("UPDATE entries SET dirty=0, remote_hash=? WHERE id=? AND created_at=?",
                [remoteHash, id, createdAt.timeIntervalSince1970])
    }

    /// Mark every entry dirty so the next push uploads the whole history (after sign-in or a key change).
    public func markAllDirty() throws {
        try run("UPDATE entries SET dirty=1", [])
    }

    public func pendingTombstones() throws -> [(remoteHash: String, deletedAt: Date)] {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        try prepare("SELECT remote_hash, deleted_at FROM tombstones ORDER BY deleted_at", [], &stmt)
        var rows: [(String, Date)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append((String(cString: sqlite3_column_text(stmt, 0)), Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))))
        }
        return rows
    }

    public func removeTombstones(_ remoteHashes: [String]) throws {
        for hash in remoteHashes { try run("DELETE FROM tombstones WHERE remote_hash=?", [hash]) }
    }

    /// Merge an entry from another device. Same text: the newer copy wins the source (the `record` rule).
    /// Never touches the pasteboard and never marks the entry dirty. Returns the entry when it was inserted
    /// or moved to the top, nil when the local copy was already newer.
    @discardableResult
    public func applyRemote(text: String, origin: ClipOrigin, source: ClipSourceInfo, device: String?,
                            createdAt: Date, remoteHash: String) throws -> ClipEntry? {
        let hash = ClipHash.of(text)
        let s = source
        // A local delete newer than the remote copy wins: keep the tombstone so the next push sends it.
        if let deletedAt = try scalarDouble("SELECT deleted_at FROM tombstones WHERE remote_hash=?", [remoteHash]),
           deletedAt >= createdAt.timeIntervalSince1970 {
            return nil
        }
        try run("DELETE FROM tombstones WHERE remote_hash=?", [remoteHash])
        if let existing = try entry(hash: hash) {
            guard createdAt.timeIntervalSince1970 > existing.createdAt.timeIntervalSince1970 + 0.0005 else {
                try run("UPDATE entries SET remote_hash=? WHERE id=?", [remoteHash, existing.id])
                return nil
            }
            try run("""
            UPDATE entries SET created_at=?, origin=?, app=?, bundle_id=?, window_title=?,
                label=?, session=?, cwd=?, terminal=?, device=?, dirty=0, remote_hash=? WHERE id=?
            """, [createdAt.timeIntervalSince1970, origin.rawValue, s.app, s.bundleId, s.windowTitle,
                  s.label, s.session, s.cwd, s.terminal, device, remoteHash, existing.id])
            return try entry(id: existing.id)
        }
        try run("""
        INSERT INTO entries(text, hash, created_at, origin, app, bundle_id, window_title, label, session, cwd, terminal,
            device, dirty, remote_hash)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,0,?)
        """, [text, hash, createdAt.timeIntervalSince1970, origin.rawValue, s.app, s.bundleId, s.windowTitle,
              s.label, s.session, s.cwd, s.terminal, device, remoteHash])
        return try entry(id: sqlite3_last_insert_rowid(db))
    }

    /// Delete the entry another device deleted. Leaves no tombstone. Returns whether a row was removed.
    @discardableResult
    public func applyRemoteDelete(remoteHash: String) throws -> Bool {
        try run("DELETE FROM entries WHERE remote_hash=?", [remoteHash])
        return sqlite3_changes(db) > 0
    }

    public func meta(_ key: String) throws -> String? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        try prepare("SELECT value FROM meta WHERE key=?", [key], &stmt)
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_text(stmt, 0).map { String(cString: $0) } : nil
    }

    public func setMeta(_ key: String, _ value: String?) throws {
        if let value {
            try run("INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)", [key, value])
        } else {
            try run("DELETE FROM meta WHERE key=?", [key])
        }
    }

    /// Delete entries older than `maxAge` and beyond the newest `maxCount`. Returns rows deleted.
    @discardableResult
    public func prune(maxAge: TimeInterval, maxCount: Int, now: Date = Date()) throws -> Int {
        try run("DELETE FROM entries WHERE created_at < ?", [now.timeIntervalSince1970 - maxAge])
        var deleted = Int(sqlite3_changes(db))
        try run("DELETE FROM entries WHERE id NOT IN (SELECT id FROM entries ORDER BY created_at DESC LIMIT ?)", [Int64(maxCount)])
        deleted += Int(sqlite3_changes(db))
        return deleted
    }

    // MARK: - Reads

    private static let columns = "e.id, e.text, e.hash, e.created_at, e.origin, e.app, e.bundle_id, e.window_title, e.label, e.session, e.cwd, e.terminal, e.device"

    public func entry(id: Int64) throws -> ClipEntry? {
        try query("SELECT \(Self.columns) FROM entries e WHERE e.id=?", [id]).first
    }

    public func entry(hash: String) throws -> ClipEntry? {
        try query("SELECT \(Self.columns) FROM entries e WHERE e.hash=?", [hash]).first
    }

    /// Newest first. `app` matches app name or bundle ID; `label` is a substring match.
    public func recent(limit: Int = 50, app: String? = nil, label: String? = nil, since: Date? = nil) throws -> [ClipEntry] {
        var clauses: [String] = []
        var binds: [Any?] = []
        if let app = app?.nilIfBlank {
            clauses.append("(e.app LIKE ? OR e.bundle_id = ?)")
            binds += ["%\(app)%", app]
        }
        if let label = label?.nilIfBlank {
            clauses.append("e.label LIKE ?")
            binds.append("%\(label)%")
        }
        if let since {
            clauses.append("e.created_at >= ?")
            binds.append(since.timeIntervalSince1970)
        }
        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        binds.append(Int64(limit))
        return try query("SELECT \(Self.columns) FROM entries e \(whereSQL) ORDER BY e.created_at DESC LIMIT ?", binds)
    }

    /// Full-text search over text, label, window title and app. Each word is a prefix match.
    public func search(_ text: String, limit: Int = 50) throws -> [ClipEntry] {
        guard let match = Self.ftsQuery(text) else { return try recent(limit: limit) }
        return try query("""
        SELECT \(Self.columns) FROM entries_fts f JOIN entries e ON e.id = f.rowid
        WHERE entries_fts MATCH ? ORDER BY e.created_at DESC LIMIT ?
        """, [match, Int64(limit)])
    }

    public func count() throws -> Int {
        try scalarInt("SELECT COUNT(*) FROM entries")
    }

    private func scalarInt(_ sql: String) throws -> Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        try prepare(sql, [], &stmt)
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    private func scalarDouble(_ sql: String, _ binds: [Any?]) throws -> Double? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        try prepare(sql, binds, &stmt)
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_double(stmt, 0) : nil
    }

    /// Quote each word so user input can't break FTS5 syntax.
    static func ftsQuery(_ text: String) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        return words.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }.joined(separator: " ")
    }

    // MARK: - SQLite helpers

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(err)
            throw ClipStoreError.sqlite(message)
        }
    }

    private func prepare(_ sql: String, _ binds: [Any?], _ stmt: inout OpaquePointer?) throws {
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ClipStoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        for (i, value) in binds.enumerated() {
            let index = Int32(i + 1)
            switch value {
            case nil: sqlite3_bind_null(stmt, index)
            case let v as Int64: sqlite3_bind_int64(stmt, index, v)
            case let v as Int: sqlite3_bind_int64(stmt, index, Int64(v))
            case let v as Double: sqlite3_bind_double(stmt, index, v)
            case let v as String: sqlite3_bind_text(stmt, index, v, -1, SQLITE_TRANSIENT)
            default: throw ClipStoreError.sqlite("unsupported bind type \(type(of: value))")
            }
        }
    }

    private func run(_ sql: String, _ binds: [Any?]) throws {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        try prepare(sql, binds, &stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw ClipStoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func query(_ sql: String, _ binds: [Any?]) throws -> [ClipEntry] {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        try prepare(sql, binds, &stmt)
        var rows: [ClipEntry] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw ClipStoreError.sqlite(String(cString: sqlite3_errmsg(db))) }
            func text(_ i: Int32) -> String? {
                sqlite3_column_text(stmt, i).map { String(cString: $0) }
            }
            rows.append(ClipEntry(
                id: sqlite3_column_int64(stmt, 0),
                text: text(1) ?? "",
                hash: text(2) ?? "",
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                origin: ClipOrigin(rawValue: text(4) ?? "") ?? .watch,
                source: ClipSourceInfo(app: text(5), bundleId: text(6), windowTitle: text(7),
                                       label: text(8), session: text(9), cwd: text(10), terminal: text(11)),
                device: text(12)
            ))
        }
        return rows
    }
}
