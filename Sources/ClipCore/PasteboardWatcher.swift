import AppKit

/// Polls the general pasteboard and records each new text copy with its source.
@MainActor
public final class PasteboardWatcher {
    /// A copy recorded by the CLI/MCP (or a re-copy) within this window is not recorded again.
    public static let mergeWindow: TimeInterval = 3

    public var policy: PrivacyPolicy
    public var paused = false
    /// Called on every pasteboard change, whether or not an entry was recorded.
    public var onChange: (() -> Void)?

    private let store: ClipStore
    private var lastChangeCount: Int
    private var timer: Timer?

    public init(store: ClipStore, policy: PrivacyPolicy = PrivacyPolicy()) {
        self.store = store
        self.policy = policy
        lastChangeCount = NSPasteboard.general.changeCount
    }

    public func start(interval: TimeInterval = 0.25) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Treat the pasteboard's current contents as already seen, so a programmatic write is not recorded.
    public func adoptCurrentChange() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    func tick() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        defer { onChange?() }

        guard !paused, let text = pasteboard.string(forType: .string) else { return }
        let source = SourceResolver.frontmost()
        if source.bundleId == Bundle.main.bundleIdentifier, source.bundleId != nil { return }
        let types = pasteboard.types?.map(\.rawValue) ?? []
        guard policy.shouldStore(types: types, bundleId: source.bundleId, text: text) else { return }

        if let existing = try? store.entry(hash: ClipHash.of(text)),
           Date().timeIntervalSince(existing.createdAt) < Self.mergeWindow {
            return
        }
        _ = try? store.record(text: text, origin: .watch, source: source)
    }
}
