import AppKit

/// Clipboard operations shared by the app, the CLI and the MCP server.
public enum ClipActions {
    /// Record `text` with the caller's source, then put it on the clipboard.
    /// Recording first lets the app's watcher see the entry and skip it.
    @discardableResult
    public static func copy(_ text: String, label: String?, origin: ClipOrigin, store: ClipStore) throws -> ClipEntry {
        let entry = try store.record(text: text, origin: origin, source: SourceResolver.callerEnvironment(label: label))
        writePasteboard(text)
        return entry
    }

    /// Put an older entry back on the clipboard, keeping its original source.
    @discardableResult
    public static func restore(id: Int64, store: ClipStore) throws -> ClipEntry? {
        guard let entry = try store.entry(id: id) else { return nil }
        try store.touch(id: id)
        writePasteboard(entry.text)
        return try store.entry(id: id)
    }

    public static func writePasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// Text and JSON renderings for the CLI and MCP server.
public enum ClipFormatter {
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    public static func line(_ e: ClipEntry, previewLength: Int = 200) -> String {
        var source = e.source.originLine
        if let label = e.source.label { source = "[\(label)] " + source }
        return "#\(e.id) · \(dateFormatter.string(from: e.createdAt)) · \(e.origin.rawValue) · \(source)\n    \(e.preview(previewLength))"
    }

    public static func detail(_ e: ClipEntry) -> String {
        var lines = ["#\(e.id) · \(dateFormatter.string(from: e.createdAt)) · \(e.origin.rawValue)"]
        let s = e.source
        let fields: [(String, String?)] = [("label", s.label), ("app", s.app), ("bundle", s.bundleId),
                                           ("window", s.windowTitle), ("session", s.session),
                                           ("cwd", s.cwd), ("terminal", s.terminal)]
        for (name, value) in fields {
            if let value { lines.append("\(name): \(value)") }
        }
        return lines.joined(separator: "\n") + "\n\n" + e.text
    }

    public static func list(_ entries: [ClipEntry]) -> String {
        entries.isEmpty ? "No entries." : entries.map { line($0) }.joined(separator: "\n")
    }

    public static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }

    /// Parse "30m", "2h", "7d" or an ISO 8601 date.
    public static func parseSince(_ value: String?, now: Date = Date()) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        let units: [Character: TimeInterval] = ["s": 1, "m": 60, "h": 3600, "d": 86400]
        if let unit = value.last.flatMap({ units[$0] }), let n = Double(value.dropLast()) {
            return now.addingTimeInterval(-n * unit)
        }
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withFullDate]
        return iso.date(from: value)
    }
}
