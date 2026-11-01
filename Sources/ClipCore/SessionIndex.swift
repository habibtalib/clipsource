import Foundation

/// A Claude Code session, read from its transcript (`~/.claude/projects/<project>/<id>.jsonl`).
public struct AgentSession: Equatable, Sendable {
    public var id: String
    /// The session's title (`ai-title`, `custom-title` or `agent-name` line), also shown as the terminal title.
    public var title: String?
    /// Last working directory recorded in the transcript.
    public var cwd: String?
    public var updatedAt: Date

    public init(id: String, title: String?, cwd: String?, updatedAt: Date) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.updatedAt = updatedAt
    }
}

/// Finds Claude Code sessions by ID or by title, so a copy can say which chat session (and repo) it came from.
/// Transcripts are read incrementally: only bytes appended since the last scan are parsed.
public final class SessionIndex: @unchecked Sendable {
    public static let shared = SessionIndex()

    private struct FileState {
        var offset: UInt64 = 0
        var modified: Date = .distantPast
        var titles: [String] = []
        var cwd: String?
    }

    private let lock = NSLock()
    private var files: [String: FileState] = [:]
    private let roots: [URL]
    /// Only transcripts touched this recently are searched by title.
    private let recentWindow: TimeInterval

    public init(roots: [URL]? = nil, recentWindow: TimeInterval = 3 * 86400) {
        self.roots = roots ?? Self.defaultRoots()
        self.recentWindow = recentWindow
    }

    /// `~/.claude/projects`, `$CLAUDE_CONFIG_DIR/projects` and `~/.claude-profiles/*/projects`.
    public static func defaultRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                    environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        var roots = [home.appendingPathComponent(".claude/projects")]
        if let config = environment["CLAUDE_CONFIG_DIR"], !config.isEmpty {
            roots.append(URL(fileURLWithPath: (config as NSString).expandingTildeInPath).appendingPathComponent("projects"))
        }
        let profiles = home.appendingPathComponent(".claude-profiles")
        if let names = try? FileManager.default.contentsOfDirectory(atPath: profiles.path) {
            roots += names.sorted().map { profiles.appendingPathComponent($0).appendingPathComponent("projects") }
        }
        var seen = Set<String>()
        return roots.filter { url in
            let real = url.resolvingSymlinksInPath().path
            return FileManager.default.fileExists(atPath: real) && seen.insert(real).inserted
        }
    }

    // MARK: Lookups

    public func session(id: String) -> AgentSession? {
        let id = id.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !id.contains("/") else { return nil }
        for file in transcripts(maxAge: nil) where file.deletingPathExtension().lastPathComponent == id {
            return read(file)
        }
        return nil
    }

    /// The most recently active session whose title matches a window title such as `✳ fix-login-bug`.
    public func session(matchingWindowTitle windowTitle: String) -> AgentSession? {
        let wanted = Self.normalizedTitle(windowTitle)
        guard wanted.count >= 3 else { return nil }
        var best: AgentSession?
        for file in transcripts(maxAge: recentWindow) {
            guard let session = read(file), let title = session.title else { continue }
            let state = lock.withLock { files[file.path] }
            let titles = (state?.titles ?? [title]).map(Self.normalizedTitle)
            guard titles.contains(wanted) else { continue }
            if best == nil || session.updatedAt > best!.updatedAt { best = session }
        }
        return best
    }

    /// Drops status glyphs that terminals and Claude Code put in front of the title (`✳ `, spinners, `● `).
    public static func normalizedTitle(_ title: String) -> String {
        var t = Substring(title.trimmingCharacters(in: .whitespacesAndNewlines))
        while let first = t.unicodeScalars.first,
              !(CharacterSet.alphanumerics.contains(first)) && first != "~" && first != "/" && first != "." {
            t = t.dropFirst()
        }
        return t.trimmingCharacters(in: .whitespaces).lowercased()
    }

    // MARK: Transcripts

    private func transcripts(maxAge: TimeInterval?) -> [URL] {
        let fm = FileManager.default
        let cutoff = maxAge.map { Date().addingTimeInterval(-$0) }
        var result: [(URL, Date)] = []
        for root in roots {
            guard let projects = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for project in projects {
                guard let items = try? fm.contentsOfDirectory(at: project, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
                for item in items where item.pathExtension == "jsonl" {
                    let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    if let cutoff, modified < cutoff { continue }
                    result.append((item, modified))
                }
            }
        }
        return result.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// Parses lines appended since the last read and returns the session's current state.
    func read(_ file: URL) -> AgentSession? {
        let path = file.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value else { return nil }
        let modified = attributes[.modificationDate] as? Date ?? Date()
        var state = lock.withLock { files[path] } ?? FileState()
        if size < state.offset { state = FileState() }  // rewritten

        if size > state.offset, let handle = try? FileHandle(forReadingFrom: file) {
            defer { try? handle.close() }
            // Transcripts reach hundreds of MB. Titles and cwd are re-written often, so the first read
            // only needs the tail; after that only appended bytes are read.
            var skipPartialLine = false
            if state.offset == 0 && size > Self.tailBytes {
                state.offset = size - Self.tailBytes
                skipPartialLine = true
            }
            try? handle.seek(toOffset: state.offset)
            var carry = Data()
            if skipPartialLine, let first = try? handle.read(upToCount: 1 << 16), let newline = first.firstIndex(of: 0x0A) {
                state.offset += UInt64(first.distance(from: first.startIndex, to: newline) + 1)
                carry = Data(first[first.index(after: newline)...])
            }
            while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                carry.append(chunk)
                guard let lastNewline = carry.lastIndex(of: 0x0A) else { continue }
                let complete = carry[carry.startIndex...lastNewline]
                Self.parse(lines: complete, into: &state)
                state.offset += UInt64(complete.count)
                carry = Data(carry[carry.index(after: lastNewline)...])
            }
        }
        state.modified = modified
        lock.withLock { files[path] = state }
        return AgentSession(id: file.deletingPathExtension().lastPathComponent,
                            title: state.titles.last, cwd: state.cwd, updatedAt: modified)
    }

    static let tailBytes: UInt64 = 256 * 1024
    /// Title lines are short; `cwd` sits near the start of each line. Bounding the search keeps
    /// multi-megabyte tool-output lines cheap.
    static let titleLineMax = 4096
    static let cwdPrefix = 2048

    private static let titleKeys = ["ai-title": "aiTitle", "custom-title": "customTitle", "agent-name": "agentName"]

    private static func parse(lines: Data, into state: inout FileState) {
        for line in lines.split(separator: 0x0A) where !line.isEmpty {
            // Cheap byte checks first; JSON-decode only the few lines that carry a title.
            if line.count <= titleLineMax, let title = title(in: line) {
                state.titles.removeAll { $0 == title }
                state.titles.append(title)
            }
            if let cwd = stringField("\"cwd\":\"", in: line.prefix(cwdPrefix)) { state.cwd = cwd }
        }
    }

    static func title(in line: Data) -> String? {
        guard line.range(of: Data("-title\"".utf8)) != nil || line.range(of: Data("\"agent-name\"".utf8)) != nil,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String, let key = titleKeys[type],
              let title = (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        return title
    }

    /// Reads a JSON string value after `marker` without decoding the whole line.
    static func stringField(_ marker: String, in line: Data) -> String? {
        guard let range = line.range(of: Data(marker.utf8)) else { return nil }
        var bytes: [UInt8] = []
        var index = range.upperBound
        var escaped = false
        while index < line.endIndex {
            let byte = line[index]
            if escaped {
                bytes.append(byte == UInt8(ascii: "n") ? 0x0A : byte)
                escaped = false
            } else if byte == UInt8(ascii: "\\") {
                escaped = true
            } else if byte == UInt8(ascii: "\"") {
                return String(decoding: bytes, as: UTF8.self)
            } else {
                bytes.append(byte)
            }
            index = line.index(after: index)
        }
        return nil
    }
}
