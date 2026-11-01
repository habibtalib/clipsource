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
public final class ClipStore {
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
        PRAGMA user_version = 1;
        """)
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
                label=?, session=?, cwd=?, terminal=? WHERE id=?
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

    /// Move an entry to the top, keeping its source (used when re-copying).
    public func touch(id: Int64, at date: Date = Date()) throws {
        try run("UPDATE entries SET created_at=? WHERE id=?", [date.timeIntervalSince1970, id])
    }

    public func delete(id: Int64) throws {
        try run("DELETE FROM entries WHERE id=?", [id])
    }

    public func clear() throws {
        try run("DELETE FROM entries", [])
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

    private static let columns = "e.id, e.text, e.hash, e.created_at, e.origin, e.app, e.bundle_id, e.window_title, e.label, e.session, e.cwd, e.terminal"

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
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        try prepare("SELECT COUNT(*) FROM entries", [], &stmt)
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
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
                                       label: text(8), session: text(9), cwd: text(10), terminal: text(11))
            ))
        }
        return rows
    }
}
