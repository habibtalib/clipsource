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
    /// Short confirmation shown in the panel footer after a clear (disappears after a few seconds).
    @Published var notice: String? {
        didSet {
            guard notice != nil else { return }
            noticeWork?.cancel()
            let work = DispatchWorkItem { MainActor.assumeIsolated { AppModel.shared.notice = nil } }
            noticeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        }
    }
    private var noticeWork: DispatchWorkItem?
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

    /// Seconds a new copy's source is shown next to the menu bar icon; 0 = icon only.
    @AppStorage("menuBarFlashSeconds") var menuBarFlashSeconds = 4
    /// Source text currently shown in the menu bar (nil = icon only).
    @Published private(set) var menuBarFlash: String?
    private var flashWork: DispatchWorkItem?
    /// Show the animated "Copied from …" toast after each ⌘C.
    @AppStorage("showCopyHUD") var showCopyHUD = true
    /// Hold ⌘V to choose which entry to paste (needs Accessibility).
    @AppStorage("holdToChoosePaste") var holdToChoosePaste = true { didSet { onPasteSwitcherSettingChanged?() } }
    var onPasteSwitcherSettingChanged: (() -> Void)?
    var pasteSwitcher: PasteSwitcher?

    /// Starts or stops the hold-⌘V switcher to match the setting and the Accessibility grant.
    func updatePasteSwitcher() {
        guard let pasteSwitcher else { return }
        if holdToChoosePaste && AXIsProcessTrusted() {
            if !pasteSwitcher.isRunning { pasteSwitcher.start() }
        } else if pasteSwitcher.isRunning {
            pasteSwitcher.stop()
        }
    }

    /// Copy text to the clipboard as soon as it is highlighted with the mouse (needs Accessibility).
    @AppStorage("copyOnSelect") var copyOnSelect = false { didSet { updateSelectionCopier() } }
    var selectionCopier: SelectionCopier?

    /// Starts or stops copy-on-select to match the setting and the Accessibility grant.
    func updateSelectionCopier() {
        guard let selectionCopier else { return }
        if copyOnSelect && AXIsProcessTrusted() {
            if !selectionCopier.isRunning { selectionCopier.start() }
        } else if selectionCopier.isRunning {
            selectionCopier.stop()
        }
    }

    /// Session, repo and chat for each entry, resolved in the background.
    @Published private(set) var details: [Int64: SourceDetails] = [:]
    private var detailsInFlight: Set<Int64> = []
    private var detailsKeys: [Int64: ClipSourceInfo] = [:]
    @AppStorage("widgetHidesContent") var widgetHidesContent = false { didSet { publishWidget() } }

    @AppStorage("excludedBundleIds") var excludedBundleIdsText = PrivacyPolicy.defaultExcludedBundleIds.joined(separator: "\n") {
        didSet { applyPolicy() }
    }
    @AppStorage("retentionDays") var retentionDays = 30
    @AppStorage("maxEntries") var maxEntries = 5000
    @AppStorage("didPromptAX") private var didPromptAX = false

    private(set) var store: ClipStore?
    let sync = SyncController()
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
            watcher.onRecord = { [weak self] entry in self?.didCopy(entry) }
            watcher.onChange = { [weak self] in
                self?.reload()
                self?.sync.schedulePush()
            }
            watcher.start()
            self.watcher = watcher
            sync.start(store: store, watcher: watcher, reload: { [weak self] in self?.reload() })
        } catch {
            errorMessage = "Cannot open history: \(error)"
            return
        }
        if !axTrusted && !didPromptAX {
            didPromptAX = true
            requestAccessibility()
        }
        // Read Claude Code transcript tails once in the background so the first ⌘C resolves quickly.
        DispatchQueue.global(qos: .utility).async { _ = SessionIndex.shared.session(matchingWindowTitle: "warm-up") }
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
        updatePasteSwitcher()
        updateSelectionCopier()
        guard let store else { return }
        do {
            entries = query.trimmingCharacters(in: .whitespaces).isEmpty
                ? try store.recent(limit: 300)
                : try store.search(query, limit: 300)
            let newest = try store.recent(limit: 1).first
            if newest != latest {
                // Flash the source of a genuinely new copy (not the first load at launch).
                if let newest, latest != nil, newest.id != latest?.id || newest.createdAt != latest?.createdAt { flash(newest) }
                latest = newest
            }
            total = try store.count()
            let onClipboard = NSPasteboard.general.string(forType: .string).map(ClipHash.of)
            currentEntryId = onClipboard.flatMap { hash in try? store.entry(hash: hash) }?.id
            if let selectedId, !entries.contains(where: { $0.id == selectedId }) { self.selectedId = nil }
            loadDetails(for: Array(entries.prefix(60)))
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

    // MARK: Source details (session, repo, chat)

    /// A manual copy: show the toast, find the session and repo off the main thread, then save them.
    func didCopy(_ entry: ClipEntry) {
        if showCopyHUD { CopyHUD.shared.show(entry) }
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let enriched = SourceEnricher.enrich(entry.source)
            let details = SourceEnricher.details(for: enriched ?? entry.source)
            // Keep the loading state on screen long enough to read as an animation.
            let delay = max(0, 0.35 - Date().timeIntervalSince(started))
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated {
                    let model = AppModel.shared
                    if let enriched {
                        try? model.store?.updateContext(id: entry.id, session: enriched.session, cwd: enriched.cwd)
                    }
                    model.details[entry.id] = details
                    model.detailsKeys[entry.id] = enriched ?? entry.source
                    if model.showCopyHUD { CopyHUD.shared.resolve(entryId: entry.id, details: details) }
                    model.reload()
                }
            }
        }
    }

    /// Resolve details for entries not seen yet (or whose source changed).
    func loadDetails(for entries: [ClipEntry]) {
        let missing = entries.filter { detailsKeys[$0.id] != $0.source && !detailsInFlight.contains($0.id) }
        guard !missing.isEmpty else { return }
        missing.forEach { detailsInFlight.insert($0.id) }
        DispatchQueue.global(qos: .utility).async {
            let resolved = missing.map { ($0.id, $0.source, SourceEnricher.details(for: $0.source)) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let model = AppModel.shared
                    for (id, source, details) in resolved {
                        model.details[id] = details
                        model.detailsKeys[id] = source
                        model.detailsInFlight.remove(id)
                    }
                }
            }
        }
    }

    /// Newest entries for the hold-⌘V switcher.
    func switcherEntries(limit: Int = 9) -> [ClipEntry] {
        let recent = (try? store?.recent(limit: limit)) ?? []
        loadDetails(for: recent)
        return recent
    }

    /// Shows the copy's source next to the menu bar icon for `menuBarFlashSeconds`, then goes back to icon only.
    func flash(_ entry: ClipEntry) {
        guard menuBarFlashSeconds > 0 else { return }
        flashWork?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            menuBarFlash = Self.short(entry.source.label ?? entry.source.cleanWindowTitle ?? entry.source.app ?? "Copied")
        }
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                withAnimation(.easeOut(duration: 0.3)) { AppModel.shared.menuBarFlash = nil }
            }
        }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(menuBarFlashSeconds), execute: work)
    }

    private static func short(_ text: String, max: Int = 22) -> String {
        text.count > max ? String(text.prefix(max - 1)) + "…" : text
    }

    func restore(id: Int64) {
        guard let store else { return }
        _ = try? ClipActions.restore(id: id, store: store)
        reload()
        sync.schedulePush()
    }

    func copy(_ entry: ClipEntry) {
        guard let store else { return }
        _ = try? ClipActions.restore(id: entry.id, store: store)
        reload()
        sync.schedulePush()
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
        sync.schedulePush()
    }

    func clearAll() {
        try? store?.clear()
        reload()
        sync.schedulePush()
    }

    enum ClearRange: CaseIterable, Identifiable {
        case fifteenMinutes, hour, today

        var id: Self { self }
        var title: String {
            switch self {
            case .fifteenMinutes: return "Last 15 minutes"
            case .hour: return "Last hour"
            case .today: return "Today"
            }
        }

        func since(_ now: Date = Date()) -> Date {
            switch self {
            case .fifteenMinutes: return now.addingTimeInterval(-15 * 60)
            case .hour: return now.addingTimeInterval(-3600)
            case .today: return Calendar.current.startOfDay(for: now)
            }
        }
    }

    /// Removes recent history; says how many entries went.
    func clear(_ range: ClearRange) {
        guard let store else { return }
        let removed = (try? store.clear(since: range.since())) ?? 0
        reload()
        sync.schedulePush()
        notice = removed == 0 ? "Nothing copied in that time." : "Cleared \(removed) \(removed == 1 ? "entry" : "entries")."
    }

    /// Empties the system clipboard (nothing left to paste); the history stays.
    func clearClipboard() {
        ClipActions.clearPasteboard()
        watcher?.adoptCurrentChange()
        reload()
        notice = "Clipboard cleared."
    }

    func prune() {
        _ = try? store?.prune(maxAge: TimeInterval(max(retentionDays, 1)) * 86400, maxCount: max(maxEntries, 100))
        sync.pruneRemote()  // synced history follows the plan's retention, not this setting
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
