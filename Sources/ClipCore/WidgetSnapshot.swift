import Foundation

/// What the widgets show. The app writes it to the shared App Group container on every change;
/// the widget extension (sandboxed) only reads it.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Identifiable, Sendable {
        public var id: Int64
        /// Nil when the user hides clipboard content in widgets.
        public var preview: String?
        public var title: String
        public var app: String?
        public var bundleId: String?
        public var label: String?
        public var origin: ClipOrigin
        public var createdAt: Date
    }

    public var updatedAt: Date
    public var paused: Bool
    public var contentHidden: Bool
    public var total: Int
    public var items: [Item]

    public init(updatedAt: Date, paused: Bool, contentHidden: Bool, total: Int, items: [Item]) {
        self.updatedAt = updatedAt
        self.paused = paused
        self.contentHidden = contentHidden
        self.total = total
        self.items = items
    }

    public static func make(entries: [ClipEntry], total: Int, paused: Bool, hideContent: Bool, now: Date = Date()) -> WidgetSnapshot {
        WidgetSnapshot(updatedAt: now, paused: paused, contentHidden: hideContent, total: total, items: entries.map {
            Item(id: $0.id, preview: hideContent ? nil : $0.preview(160), title: $0.source.title,
                 app: $0.source.app, bundleId: $0.source.bundleId, label: $0.source.label,
                 origin: $0.origin, createdAt: $0.createdAt)
        })
    }

    /// Same content, ignoring when it was written.
    public func sameContent(as other: WidgetSnapshot?) -> Bool {
        guard let other else { return false }
        return paused == other.paused && contentHidden == other.contentHidden && total == other.total && items == other.items
    }

    public static let placeholder = WidgetSnapshot(updatedAt: Date(), paused: false, contentHidden: false, total: 3, items: [
        Item(id: 3, preview: "Thanks, I'll check the server and update you.", title: "Reply to Sam",
             app: "iTerm2", bundleId: "com.googlecode.iterm2", label: "Reply to Sam", origin: .mcp, createdAt: Date()),
        Item(id: 2, preview: "https://example.com/report", title: "Safari — Weekly report",
             app: "Safari", bundleId: "com.apple.Safari", label: nil, origin: .watch, createdAt: Date().addingTimeInterval(-300)),
        Item(id: 1, preview: "git push origin main", title: "Terminal — zsh",
             app: "Terminal", bundleId: "com.apple.Terminal", label: nil, origin: .cli, createdAt: Date().addingTimeInterval(-1200)),
    ])

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public static func read(from url: URL) -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }
}

/// Locates the App Group container shared by the app and the widget extension.
/// The group ID comes from the `ClipSourceAppGroup` Info.plist key, set only in the Xcode build;
/// the SwiftPM-built app has no group, so widget publishing is skipped there.
public enum WidgetBridge {
    public static let urlScheme = "clipsource"

    public static var appGroupId: String? {
        guard let id = (Bundle.main.object(forInfoDictionaryKey: "ClipSourceAppGroup") as? String)?.nilIfBlank,
              !id.contains("$(") else { return nil }
        return id
    }

    public static var snapshotURL: URL? {
        guard let group = appGroupId,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        try? FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        return container.appendingPathComponent("widget-snapshot.json")
    }

    public static func restoreURL(id: Int64) -> URL {
        URL(string: "\(urlScheme)://restore/\(id)")!
    }

    public static let panelURL = URL(string: "\(urlScheme)://panel")!
}
