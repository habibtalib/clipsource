import AppKit
import ClipCore
import ServiceManagement
import SwiftUI
import WidgetKit

struct SourceGroup: Identifiable {
    let title: String
    let bundleId: String?
    let entries: [ClipEntry]
    var id: String { title }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var entries: [ClipEntry] = []
    @Published private(set) var axTrusted = SourceResolver.isTrusted(prompt: false)
    @Published private(set) var errorMessage: String?
    @Published var query = "" { didSet { reload() } }
    @Published var paused = false {
        didSet {
            watcher?.paused = paused
            publishWidget()
        }
    }
    /// Newest entry regardless of the search query; drives the menu-bar status.
    @Published private(set) var latest: ClipEntry?
    @Published private(set) var total = 0
    /// Entry whose text is on the clipboard right now.
    @Published private(set) var currentEntryId: Int64?
    /// Keyboard selection in the history list.
    @Published var selectedId: Int64?

    @AppStorage("menuBarShowsSource") var menuBarShowsSource = true
    @AppStorage("widgetHidesContent") var widgetHidesContent = false { didSet { publishWidget() } }

    @AppStorage("excludedBundleIds") var excludedBundleIdsText = PrivacyPolicy.defaultExcludedBundleIds.joined(separator: "\n") {
        didSet { applyPolicy() }
    }
    @AppStorage("retentionDays") var retentionDays = 30
    @AppStorage("maxEntries") var maxEntries = 5000
    @AppStorage("didPromptAX") private var didPromptAX = false

    private(set) var store: ClipStore?
    private var watcher: PasteboardWatcher?
    private var pruneTimer: Timer?

    /// Entries grouped by source app, in order of each app's newest entry.
    var groupsByApp: [SourceGroup] {
        var order: [String] = []
        var byApp: [String: [ClipEntry]] = [:]
        for entry in entries {
            let app = entry.source.app ?? "Unknown app"
            if byApp[app] == nil { order.append(app) }
            byApp[app, default: []].append(entry)
        }
        return order.map { SourceGroup(title: $0, bundleId: byApp[$0]?.first?.source.bundleId, entries: byApp[$0] ?? []) }
    }

    func start() {
        do {
            let store = try ClipStore()
            self.store = store
            let watcher = PasteboardWatcher(store: store, policy: policy)
            watcher.onChange = { [weak self] in self?.reload() }
            watcher.start()
            self.watcher = watcher
        } catch {
            errorMessage = "Cannot open history: \(error)"
            return
        }
        if !axTrusted && !didPromptAX {
            didPromptAX = true
            requestAccessibility()
        }
        prune()
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.prune() }
        }
        reload()
    }

    var policy: PrivacyPolicy {
        let ids = excludedBundleIdsText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return PrivacyPolicy(excludedBundleIds: Set(ids))
    }

    private func applyPolicy() {
        watcher?.policy = policy
    }

    func reload() {
        axTrusted = AXIsProcessTrusted()
        guard let store else { return }
        do {
            entries = query.trimmingCharacters(in: .whitespaces).isEmpty
                ? try store.recent(limit: 300)
                : try store.search(query, limit: 300)
            let newest = try store.recent(limit: 1).first
            if newest != latest { latest = newest }
            total = try store.count()
            let onClipboard = NSPasteboard.general.string(forType: .string).map(ClipHash.of)
            currentEntryId = onClipboard.flatMap { hash in try? store.entry(hash: hash) }?.id
            if let selectedId, !entries.contains(where: { $0.id == selectedId }) { self.selectedId = nil }
        } catch {
            errorMessage = "\(error)"
        }
        publishWidget()
    }

    private var lastSnapshot: WidgetSnapshot?

    /// Write the widget snapshot to the App Group and reload widget timelines when it changed.
    func publishWidget() {
        guard let store, let url = WidgetBridge.snapshotURL,
              let recent = try? store.recent(limit: 6), let total = try? store.count() else { return }
        let snapshot = WidgetSnapshot.make(entries: recent, total: total, paused: paused, hideContent: widgetHidesContent)
        guard !snapshot.sameContent(as: lastSnapshot) else { return }
        do {
            try snapshot.write(to: url)
            lastSnapshot = snapshot
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            errorMessage = "Widget update failed: \(error.localizedDescription)"
        }
    }

    func restore(id: Int64) {
        guard let store else { return }
        _ = try? ClipActions.restore(id: id, store: store)
        reload()
    }

    func copy(_ entry: ClipEntry) {
        guard let store else { return }
        _ = try? ClipActions.restore(id: entry.id, store: store)
        reload()
    }

    /// Move the keyboard selection up (-1) or down (+1).
    func select(offset: Int) {
        guard !entries.isEmpty else { return }
        let index = selectedId.flatMap { id in entries.firstIndex { $0.id == id } }
        let next = index.map { min(max($0 + offset, 0), entries.count - 1) } ?? (offset > 0 ? 0 : entries.count - 1)
        selectedId = entries[next].id
    }

    /// Copy the selected entry, or the first one when nothing is selected. Returns whether anything was copied.
    @discardableResult
    func copySelected() -> Bool {
        guard let entry = entries.first(where: { $0.id == selectedId }) ?? entries.first else { return false }
        copy(entry)
        return true
    }

    @discardableResult
    func copy(at index: Int) -> Bool {
        guard entries.indices.contains(index) else { return false }
        copy(entries[index])
        return true
    }

    func delete(_ entry: ClipEntry) {
        try? store?.delete(id: entry.id)
        reload()
    }

    func clearAll() {
        try? store?.clear()
        reload()
    }

    func prune() {
        _ = try? store?.prune(maxAge: TimeInterval(max(retentionDays, 1)) * 86400, maxCount: max(maxEntries, 100))
        reload()
    }

    func requestAccessibility() {
        SourceResolver.isTrusted(prompt: true)
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                errorMessage = "Launch at login: \(error.localizedDescription)"
            }
            objectWillChange.send()
        }
    }
}
