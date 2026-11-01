import AppKit
import ClipCore
import ServiceManagement
import SwiftUI
import WidgetKit

struct SourceGroup: Identifiable {
    let title: String
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

    var groups: [SourceGroup] {
        var order: [String] = []
        var byTitle: [String: [ClipEntry]] = [:]
        for entry in entries {
            let title = entry.source.title
            if byTitle[title] == nil { order.append(title) }
            byTitle[title, default: []].append(entry)
        }
        return order.map { SourceGroup(title: $0, entries: byTitle[$0] ?? []) }
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
