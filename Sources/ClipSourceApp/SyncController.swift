import AppKit
import AuthenticationServices
import ClipCore
import SwiftUI

/// Drives cross-device sync for the app: sign-in, passphrase unlock, device registration, debounced push,
/// periodic and realtime pulls, and the ClipSource Cloud account (plan, devices, billing).
@MainActor
final class SyncController: NSObject, ObservableObject {
    static let redirectURL = "clipsource://auth-callback"

    @Published private(set) var status: SyncStatus = .off
    @Published private(set) var config = SyncConfig()
    @Published private(set) var email: String?
    @Published private(set) var pendingCount = 0
    @Published private(set) var lastSync: Date?
    /// Entries over the server's size limit, kept on this Mac only (from the last sync).
    @Published private(set) var oversizedCount = 0
    /// Plan, limits and devices; nil until fetched after sign-in.
    @Published private(set) var account: CloudAccount?
    /// The plan's Mac or synced-entry limit was hit; Settings offers Upgrade.
    @Published private(set) var upgradeSuggested = false
    /// Another sign-in owns this Mac's device id (a copied database); Settings offers a new id.
    @Published private(set) var deviceIdInUse = false
    /// This Mac holds the sync key.
    @Published private(set) var hasKey = false

    private var store: ClipStore?
    private weak var watcher: PasteboardWatcher?
    private var reload: () -> Void = {}
    private var secrets: SyncSecretStore?
    private var client: SupabaseClient?
    private var engine: SyncEngine?
    private var realtime: RealtimeClient?
    private var timer: Timer?
    private var pushTask: Task<Void, Never>?
    private var syncing = false
    private var syncAgain = false
    private var generation = 0
    /// Store meta flag: the next sync pulls before pushing (set by unlock, shared with the CLI).
    private static let pullFirstKey = "sync.pullFirst"
    private var authSession: ASWebAuthenticationSession?

    var isConfigured: Bool { config.isConfigured }
    var isSignedIn: Bool { client?.session != nil }
    /// Signed in, but this Mac has no sync key yet.
    var needsPassphrase: Bool { isSignedIn && !hasKey }
    var isRunning: Bool { engine != nil }

    func start(store: ClipStore, watcher: PasteboardWatcher?, reload: @escaping () -> Void) {
        self.store = store
        self.watcher = watcher
        self.reload = reload
        secrets = SyncSecrets.store(storeURL: store.url)
        config = SyncConfig.load(storeURL: store.url)
        makeClient()
        resume()
    }

    // MARK: Server

    /// Use a self-hosted Supabase project instead of ClipSource Cloud.
    func saveServer(url: String, anonKey: String) {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let anonKey = anonKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: url), parsed.scheme?.hasPrefix("http") == true, parsed.host != nil else {
            status = .error("Enter the server URL, like https://xyz.supabase.co")
            return
        }
        guard !anonKey.isEmpty else {
            status = .error("Enter the anon key")
            return
        }
        switchServer { $0.url = url; $0.anonKey = anonKey; $0.customServer = true }
    }

    /// Go back to ClipSource Cloud. The custom URL and key are kept for later.
    func useCloud() {
        guard config.customServer else { return }
        switchServer { $0.customServer = false }
    }

    /// A session and key belong to one server, so changing servers signs out first.
    private func switchServer(_ change: (inout SyncConfig) -> Void) {
        let before = config.server.map { "\($0.url.absoluteString) \($0.anonKey)" }
        var next = config
        change(&next)
        let after = next.server.map { "\($0.url.absoluteString) \($0.anonKey)" }
        stopRunning()
        if before != after {
            try? secrets?.saveSession(nil)
            try? secrets?.saveSyncKey(nil)
            next.enabled = false
            account = nil
        }
        config = next
        saveConfig()
        makeClient()
        resume()
    }

    // MARK: Settings

    /// Rename this Mac locally and in the account's device list.
    func setDeviceName(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != config.device.name else { return }
        config.device.name = name
        saveConfig()
        if let engine { self.engine = SyncEngine(store: engine.store, transport: engine.transport, key: engine.key, device: config.device) }
        guard let client, isRunning else { return }
        let id = config.device.id
        Task {
            do {
                try await client.renameDevice(id: id, name: name)
                await refreshAccount()
            } catch {
                status = .error("Rename failed: \(Self.describe(error))")
            }
        }
    }

    func setAutoCopy(_ on: Bool) {
        config.autoCopyRemote = on
        saveConfig()
    }

    // MARK: Account

    func signIn(provider: String) {
        guard let client else { status = .error("Sync server is not set up"); return }
        let pkce = SupabaseClient.pkcePair()
        let url = client.authorizeURL(provider: provider, redirectTo: Self.redirectURL, challenge: pkce.challenge)
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "clipsource") { [weak self] callback, error in
            Task { @MainActor in
                self?.authSession = nil
                self?.finishSignIn(callback: callback, error: error, verifier: pkce.verifier)
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        authSession = session
        if !session.start() { status = .error("Cannot open the sign-in window") }
    }

    private func finishSignIn(callback: URL?, error: Error?, verifier: String) {
        if let error {
            if (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
                status = .error("Sign-in failed: \(error.localizedDescription)")
            }
            return
        }
        let items = callback.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let failure = value("error_description") ?? value("error") {
            status = .error("Sign-in failed: \(failure)")
            return
        }
        guard let code = value("code"), let client else {
            status = .error("Sign-in failed: no authorization code")
            return
        }
        Task {
            do {
                _ = try await client.exchangeCode(code, verifier: verifier)
                resume()
            } catch {
                status = .error("Sign-in failed: \(Self.describe(error))")
            }
        }
    }

    func unlock(passphrase: String) async {
        guard let client, let store, let secrets else { return }
        guard !passphrase.isEmpty else { status = .error("Enter the sync passphrase"); return }
        status = .syncing
        do {
            let key = try await SyncEngine.unlock(passphrase: passphrase, transport: client)
            try secrets.saveSyncKey(key)
            try store.markAllDirty()
            try store.setMeta(Self.pullFirstKey, "1")
            config.enabled = true
            saveConfig()
            resume()
        } catch {
            status = .error(Self.describe(error))
        }
    }

    func signOut() async {
        stopRunning()
        await client?.signOut()
        try? secrets?.saveSyncKey(nil)
        config.enabled = false
        saveConfig()
        email = nil
        account = nil
        hasKey = false
        upgradeSuggested = false
        deviceIdInUse = false
        status = .off
    }

    /// Another device removed this Mac, which revoked its sign-in: sign out here too and say why.
    private func signOutRemoved() async {
        await signOut()
        status = .error("This Mac was removed from your account, or its sign-in expired. Sign in again to keep syncing.")
    }

    /// Give this Mac a fresh device id, then register again (for `device_in_use`).
    func useNewDeviceId() {
        config.device.id = UUID().uuidString
        saveConfig()
        deviceIdInUse = false
        resume()
    }

    func deleteRemoteData() async {
        guard let client else { return }
        do {
            try await client.deleteAll()
            await signOut()
        } catch {
            status = .error("Delete failed: \(Self.describe(error))")
        }
    }

    func refreshAccount() async {
        guard let client, client.session != nil else { return }
        if let fresh = try? await client.accountStatus() { account = fresh }
    }

    /// Remove another device from the account; it frees a Mac slot on the Free plan.
    func removeDevice(_ device: CloudDevice) async {
        guard let client, !device.current else { return }
        do {
            try await client.removeDevice(id: device.deviceId)
            await refreshAccount()
            if upgradeSuggested, !isRunning { resume() }
        } catch {
            status = .error("Remove failed: \(Self.describe(error))")
        }
    }

    /// Open Stripe Checkout for Pro in the browser. `interval` is "month" or "year".
    func upgrade(interval: String) {
        guard let client else { return }
        Task {
            do {
                NSWorkspace.shared.open(try await client.checkoutURL(interval: interval))
            } catch SupabaseError.rejected("already_subscribed", _) {
                // Already Pro (e.g. bought on the website): manage the subscription instead.
                await refreshAccount()
                manageBilling()
            } catch {
                status = .error("Billing is unavailable: \(Self.describe(error))")
            }
        }
    }

    func manageBilling() {
        openBilling { try await $0.portalURL() }
    }

    private func openBilling(_ make: @escaping (SupabaseClient) async throws -> URL) {
        guard let client else { return }
        Task {
            do {
                NSWorkspace.shared.open(try await make(client))
            } catch {
                status = .error("Billing is unavailable: \(Self.describe(error))")
            }
        }
    }

    // MARK: Sync

    /// Sync soon after a local change; bursts of changes collapse into one push.
    func schedulePush() {
        refreshPending()
        guard engine != nil else { return }
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.syncNow()
        }
    }

    /// Sync now; when this Mac is not registered yet (e.g. after an upgrade), try registering again first.
    func syncNow() {
        guard let engine else {
            if isSignedIn, hasKey { resume() }
            return
        }
        if syncing { syncAgain = true; return }
        syncing = true
        status = .syncing
        Task {
            defer {
                syncing = false
                if syncAgain { syncAgain = false; syncNow() }
            }
            do {
                let result = try await engine.sync(pullFirst: (try? store?.meta(Self.pullFirstKey)) != nil)
                try? store?.setMeta(Self.pullFirstKey, nil)
                oversizedCount = engine.lastOversized
                let now = Date()
                lastSync = now
                status = .synced(now)
                refreshPending()
                reload()
                autoCopy(result.applied.first, now: now)
                if result.pushed > 0 || result.deleted > 0 { await refreshAccount() }  // keeps "N of max entries" current
            } catch SupabaseError.sessionExpired {
                // The refresh token or session was revoked, usually because this Mac was removed.
                await signOutRemoved()
            } catch SupabaseError.http(403, _) {
                // Row-level security refused the write: this Mac is not registered to this sign-in.
                stopRunning()
                status = .error("This Mac is no longer registered with your account. Choose Sync now to add it again.")
            } catch let error as SupabaseError {
                if case .rejected("row_limit", _) = error {
                    upgradeSuggested = true
                    await refreshAccount()
                }
                status = .error(error.description)
                refreshPending()
            } catch {
                status = .error(Self.describe(error))
                refreshPending()
            }
        }
    }

    /// Delete synced rows older than the plan's retention. The server also prunes hourly.
    func pruneRemote() {
        guard let engine, let days = account?.retentionDays else { return }
        Task { try? await engine.pruneRemote(olderThan: Date().addingTimeInterval(-TimeInterval(days) * 86400)) }
    }

    /// Put a just-arrived entry from another device on this Mac's clipboard, without recording it again.
    private func autoCopy(_ entry: ClipEntry?, now: Date) {
        guard config.autoCopyRemote, let entry, entry.device != nil,
              abs(now.timeIntervalSince(entry.createdAt)) < 10 else { return }
        ClipActions.writePasteboard(entry.text)
        watcher?.adoptCurrentChange()
        reload()
    }

    // MARK: Lifecycle

    private func makeClient() {
        guard let secrets, let server = config.server else {
            client = nil
            return
        }
        client = SupabaseClient(url: server.url, anonKey: server.anonKey, secrets: secrets)
    }

    /// Bring sync to the state the stored session and key allow: off, locked, or registered and running.
    private func resume() {
        stopRunning()
        refreshPending()
        guard let client, let session = client.session, let store, let secrets else {
            email = nil
            account = nil
            hasKey = false
            status = .off
            return
        }
        email = session.email
        let key = config.enabled ? secrets.syncKey() : nil
        hasKey = key != nil
        guard let key else {
            status = .locked
            Task { await refreshAccount() }
            return
        }
        status = .syncing
        let device = config.device
        let current = generation
        Task {
            do {
                // Register (or refresh) this Mac before the first write; the server refuses rows from unknown devices.
                let registered = try await client.registerDevice(id: device.id, name: device.name)
                guard current == generation else { return }
                upgradeSuggested = false
                deviceIdInUse = false
                account = registered
                startRunning(client: client, store: store, key: key)
                await refreshAccount()
            } catch SupabaseError.sessionExpired {
                guard current == generation else { return }
                await signOutRemoved()
            } catch SupabaseError.rejected("device_in_use", _) {
                guard current == generation else { return }
                deviceIdInUse = true
                status = .error("This Mac's ID is in use by another sign-in. Sign out and in again, or use a new device ID.")
                await refreshAccount()
            } catch {
                guard current == generation else { return }
                if case SupabaseError.deviceLimit = error { upgradeSuggested = true }
                status = .error(Self.describe(error))
                await refreshAccount()
            }
        }
    }

    private func startRunning(client: SupabaseClient, store: ClipStore, key: SyncKey) {
        engine = SyncEngine(store: store, transport: client, key: key, device: config.device)
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncNow() }
        }
        if let server = config.server {
            let realtime = RealtimeClient(url: server.url, anonKey: server.anonKey) { try await client.validAccessToken() }
            realtime.onChange = { [weak self] in
                Task { @MainActor in self?.syncNow() }
            }
            realtime.connect()
            self.realtime = realtime
        }
        syncNow()
        pruneRemote()
    }

    private func stopRunning() {
        generation += 1
        timer?.invalidate()
        timer = nil
        pushTask?.cancel()
        pushTask = nil
        realtime?.disconnect()
        realtime = nil
        engine = nil
    }

    private func refreshPending() {
        pendingCount = (try? store?.pendingCount()) ?? 0
    }

    private func saveConfig() {
        guard let store else { return }
        do {
            try config.save(storeURL: store.url)
        } catch {
            status = .error("Cannot save sync settings: \(error.localizedDescription)")
        }
    }

    /// Error text for the status line. Errors never carry tokens or the passphrase.
    private static func describe(_ error: Error) -> String {
        error is URLError ? error.localizedDescription : String(describing: error)
    }
}

extension SyncController: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApp.keyWindow ?? NSWindow() }
    }
}
