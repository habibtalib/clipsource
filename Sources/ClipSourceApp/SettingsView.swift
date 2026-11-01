import ClipCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            SyncSettingsView(sync: model.sync)
                .tabItem { Label("Sync", systemImage: "icloud") }
        }
        .frame(width: 520)
        .tint(BrandIcons.accent)
    }
}

struct GeneralSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section("Capture") {
                LabeledContent("Accessibility") {
                    if model.axTrusted {
                        Text("Granted: window titles are recorded").foregroundStyle(.secondary)
                    } else {
                        Button("Grant…") { model.requestAccessibility() }
                    }
                }
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
            }

            Section("Status") {
                Toggle("Show latest source in the menu bar", isOn: $model.menuBarShowsSource)
                Toggle("Hide clipboard text in widgets", isOn: $model.widgetHidesContent)
                if WidgetBridge.appGroupId == nil {
                    Text("Widgets need the Xcode build (Scripts/build-widgets.sh).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                TextEditor(text: $model.excludedBundleIdsText)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 110)
            } header: {
                Text("Never record copies from these apps (bundle IDs, one per line)")
            } footer: {
                Text("Copies marked concealed by password managers are always skipped.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("History") {
                Stepper("Keep for \(model.retentionDays) days", value: $model.retentionDays, in: 1...365)
                Stepper("Keep at most \(model.maxEntries) entries", value: $model.maxEntries, in: 100...50000, step: 100)
                HStack {
                    Button("Apply retention now") { model.prune() }
                    Spacer()
                    Button("Clear history…", role: .destructive) { confirmClear = true }
                }
                if let path = model.store?.url.path {
                    Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding()
        .confirmationDialog("Delete all clipboard history?", isPresented: $confirmClear) {
            Button("Delete all", role: .destructive) { model.clearAll() }
        }
    }
}

struct SyncSettingsView: View {
    @ObservedObject var sync: SyncController
    @State private var passphrase = ""
    @State private var deviceName = ""
    @State private var unlocking = false
    @State private var confirmDelete = false
    @State private var showAdvanced = false
    @State private var url = ""
    @State private var anonKey = ""

    var body: some View {
        Form {
            if sync.isSignedIn {
                accountSection
                if sync.needsPassphrase { passphraseSection }
                devicesSection
                optionsSection
            } else {
                signInSection
            }
            statusSection
            advancedSection
        }
        .formStyle(.grouped)
        .padding()
        .frame(minHeight: 560)
        .onAppear(perform: load)
        .onChange(of: sync.config.device.name) { _, name in deviceName = name }
        .confirmationDialog("Delete every synced entry from the server and sign out?", isPresented: $confirmDelete) {
            Button("Delete synced data", role: .destructive) { Task { await sync.deleteRemoteData() } }
        } message: {
            Text("History on this Mac is kept. Other devices stop syncing until you set a new passphrase.")
        }
    }

    // MARK: Signed out

    private var signInSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(nsImage: BrandIcons.appIcon).resizable().frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sync.config.customServer ? "Your own server" : "ClipSource Cloud").font(.headline)
                        Text("Your clipboard history on every Mac and in the browser, end-to-end encrypted.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button { sync.signIn(provider: "github") } label: {
                        Label("Sign in with GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    Button { sync.signIn(provider: "google") } label: {
                        Label("Sign in with Google", systemImage: "globe")
                    }
                }
                .controlSize(.large)
                .disabled(!sync.isConfigured)
                if !sync.isConfigured {
                    Text(sync.config.customServer
                         ? "Enter your server's URL and anon key under Advanced."
                         : "This build has no ClipSource Cloud server. Use your own Supabase server under Advanced.")
                        .font(.caption).foregroundStyle(.orange)
                } else if !sync.config.customServer {
                    Text("Free: \(ClipSourceCloud.freeDeviceLimit) Macs and the web viewer, \(ClipSourceCloud.freeRetentionDays) days of synced history. Pro: unlimited Macs, 365 days.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: Signed in

    private var accountSection: some View {
        Section("Account") {
            LabeledContent("Signed in as") {
                HStack(spacing: 8) {
                    Text(sync.email ?? "Signed in").textSelection(.enabled)
                    if let account = sync.account { PlanBadge(account: account) }
                }
            }
            if let account = sync.account {
                LabeledContent("Plan") { Text(planSummary(account)).foregroundStyle(.secondary) }
                if let rows = rowSummary(account) {
                    LabeledContent("Synced history") { Text(rows).foregroundStyle(.secondary).monospacedDigit() }
                }
                if account.isPro {
                    HStack {
                        if let end = account.currentPeriodEnd {
                            Text("Renews \(end.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Manage billing…") { sync.manageBilling() }
                    }
                } else {
                    HStack {
                        Text("Pro: unlimited Macs and a year of synced history.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Menu("Upgrade to Pro") {
                            Button("Monthly, \(ClipSourceCloud.proPriceMonthly)") { sync.upgrade(interval: "month") }
                            Button("Yearly, \(ClipSourceCloud.proPriceYearly)") { sync.upgrade(interval: "year") }
                        }
                        .fixedSize()
                    }
                }
            }
        }
    }

    private var passphraseSection: some View {
        Section {
            SecureField("Sync passphrase", text: $passphrase)
                .onSubmit(unlock)
            HStack {
                if unlocking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Unlock", action: unlock).disabled(passphrase.isEmpty || unlocking)
            }
        } header: {
            Text("Passphrase")
        } footer: {
            Text("Choose a new passphrase on your first device and enter the same one on the others. It can't be recovered and never leaves this Mac.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var devicesSection: some View {
        Section {
            HStack {
                TextField("This Mac's name", text: $deviceName)
                    .onSubmit { sync.setDeviceName(deviceName) }
                Button("Rename") { sync.setDeviceName(deviceName) }
                    .disabled(deviceName.trimmingCharacters(in: .whitespaces).isEmpty || deviceName == sync.config.device.name)
            }
            ForEach(sync.account?.devices ?? []) { device in
                DeviceRow(device: device, isThisMac: device.current) {  // bound to this sign-in, not just a matching id
                    Task { await sync.removeDevice(device) }
                }
            }
        } header: {
            Text("Devices")
        } footer: {
            Text("Device names are visible in your account; clipboard contents never are. Removing a device signs it out immediately.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var optionsSection: some View {
        Section("This Mac") {
            Toggle("Copy entries from other devices to this Mac's clipboard",
                   isOn: Binding(get: { sync.config.autoCopyRemote }, set: { sync.setAutoCopy($0) }))
        }
    }

    // MARK: Status

    private var statusSection: some View {
        Section("Status") {
            LabeledContent("Sync") {
                Text(statusText).foregroundStyle(statusColor).multilineTextAlignment(.trailing)
            }
            if sync.oversizedCount > 0 {
                Text("\(sync.oversizedCount) \(sync.oversizedCount == 1 ? "entry" : "entries") too large to sync stayed on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if sync.deviceIdInUse {
                HStack {
                    Text("Happens when this Mac's history was copied from another Mac.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Use a new device ID") { sync.useNewDeviceId() }
                }
            }
            if sync.upgradeSuggested, sync.account?.isPro != true {
                HStack {
                    Text("Remove a Mac or old entries, or upgrade.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Upgrade to Pro") { sync.upgrade(interval: "month") }
                        .buttonStyle(.borderedProminent)
                }
            }
            if sync.isSignedIn {
                LabeledContent("Waiting to upload") { Text("\(sync.pendingCount)").monospacedDigit() }
                HStack {
                    Button("Sync now") { sync.syncNow() }
                        .disabled(sync.needsPassphrase)
                    Spacer()
                    Button("Sign out") { Task { await sync.signOut() } }
                    Button("Delete my synced data…", role: .destructive) { confirmDelete = true }
                }
            }
        }
    }

    // MARK: Advanced

    private var advancedSection: some View {
        Section {
            DisclosureGroup("Advanced: use my own Supabase server", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Server URL", text: $url, prompt: Text("https://xyz.supabase.co"))
                    TextField("Anon key", text: $anonKey)
                        .font(.system(.body, design: .monospaced))
                    Text("Apply the migrations in supabase/ to your project first. Switching servers signs you out.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        if sync.config.customServer {
                            Button("Use ClipSource Cloud") { sync.useCloud() }
                        }
                        Spacer()
                        Button(sync.config.customServer ? "Save" : "Use this server") {
                            sync.saveServer(url: url, anonKey: anonKey)
                        }
                        .disabled(url.isEmpty || anonKey.isEmpty)
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    // MARK: Helpers

    private func load() {
        url = sync.config.url ?? ""
        anonKey = sync.config.anonKey ?? ""
        deviceName = sync.config.device.name
        showAdvanced = sync.config.customServer
    }

    private func unlock() {
        guard !passphrase.isEmpty, !unlocking else { return }
        unlocking = true
        let value = passphrase
        Task {
            await sync.unlock(passphrase: value)
            unlocking = false
            if !sync.needsPassphrase { passphrase = "" }
        }
    }

    private func planSummary(_ account: CloudAccount) -> String {
        let macs = account.deviceLimit.map { "\(account.macCount) of \($0) Macs" } ?? "\(account.macCount) Macs"
        return "\(macs) · kept \(account.retentionDays) days"
    }

    /// "1,234 of 5,000 entries", or nil when the server sends no row limit.
    private func rowSummary(_ account: CloudAccount) -> String? {
        guard let max = account.maxRows else { return nil }
        return "\((account.rowsUsed ?? 0).formatted()) of \(max.formatted()) entries"
    }

    private var statusText: String {
        switch sync.status {
        case .off: return sync.isConfigured ? "Off: sign in to start" : "Off: no server"
        case .locked: return "Locked: enter your passphrase"
        case .syncing: return "Syncing…"
        case .synced(let date): return "Synced " + date.formatted(.relative(presentation: .named))
        case .error(let message): return message
        }
    }

    private var statusColor: Color {
        switch sync.status {
        case .error: return .red
        case .locked: return .orange
        default: return .secondary
        }
    }
}

struct PlanBadge: View {
    let account: CloudAccount

    var body: some View {
        Text(account.planName)
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(account.isPro ? Color.white : BrandIcons.accent)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(account.isPro ? AnyShapeStyle(BrandIcons.accent) : AnyShapeStyle(BrandIcons.accent.opacity(0.16)),
                        in: Capsule())
    }
}

struct DeviceRow: View {
    let device: CloudDevice
    let isThisMac: Bool
    let onRemove: () -> Void
    @State private var confirmRemove = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.kind == "web" ? "globe" : "laptopcomputer")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(device.name).lineLimit(1)
                    if isThisMac {
                        Text("This Mac")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(BrandIcons.accent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(BrandIcons.accent.opacity(0.16), in: Capsule())
                    }
                }
                if let seen = device.lastSeenAt {
                    Text("Last seen " + seen.formatted(.relative(presentation: .named)))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !isThisMac {
                Button("Remove…") { confirmRemove = true }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
            }
        }
        .confirmationDialog("Remove \(device.name) from your account?", isPresented: $confirmRemove) {
            Button("Remove and sign out", role: .destructive, action: onRemove)
        } message: {
            Text("It is signed out immediately and stops syncing. Its local history is not touched.")
        }
    }
}
