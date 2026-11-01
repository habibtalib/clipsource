import CryptoKit
import Foundation

public enum ClipSourceVersion {
    public static let string = "0.1.0"
}

/// How an entry reached the history.
public enum ClipOrigin: String, Codable, Sendable {
    /// Seen by the menu-bar app's pasteboard watcher (a manual copy).
    case watch
    /// Copied through the `clipsrc` CLI.
    case cli
    /// Copied through the MCP server.
    case mcp
}

/// Where a copy came from.
public struct ClipSourceInfo: Codable, Equatable, Sendable {
    public var app: String?
    public var bundleId: String?
    public var windowTitle: String?
    public var label: String?
    public var session: String?
    public var cwd: String?
    public var terminal: String?

    public init(app: String? = nil, bundleId: String? = nil, windowTitle: String? = nil,
                label: String? = nil, session: String? = nil, cwd: String? = nil, terminal: String? = nil) {
        self.app = app
        self.bundleId = bundleId
        self.windowTitle = windowTitle
        self.label = label
        self.session = session
        self.cwd = cwd
        self.terminal = terminal
    }

    /// Short title used to group entries: the label if set, else app + window.
    public var title: String {
        if let label, !label.isEmpty { return label }
        switch (app, windowTitle) {
        case let (a?, w?): return "\(a) — \(w)"
        case let (a?, nil): return a
        case let (nil, w?): return w
        default: return "Unknown source"
        }
    }

    /// One-line description: app, window and folder.
    public var originLine: String {
        var parts: [String] = []
        if let app { parts.append(app) }
        if let windowTitle { parts.append(windowTitle) }
        if let cwd { parts.append((cwd as NSString).lastPathComponent) }
        return parts.isEmpty ? "Unknown source" : parts.joined(separator: " · ")
    }
}

public struct ClipEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64
    public var text: String
    public var hash: String
    public var createdAt: Date
    public var origin: ClipOrigin
    public var source: ClipSourceInfo

    public init(id: Int64, text: String, hash: String, createdAt: Date, origin: ClipOrigin, source: ClipSourceInfo) {
        self.id = id
        self.text = text
        self.hash = hash
        self.createdAt = createdAt
        self.origin = origin
        self.source = source
    }

    /// Single-line preview, whitespace collapsed.
    public func preview(_ maxLength: Int = 200) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > maxLength ? String(flat.prefix(maxLength)) + "…" : flat
    }
}

public enum ClipHash {
    public static func of(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
