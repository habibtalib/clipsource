import ClipCore
import Foundation

let usage = """
clipsrc \(ClipSourceVersion.string): clipboard with source tracking

USAGE
  clipsrc copy [--label L] [text...]     Copy text (stdin when no text) and tag it with its source
  clipsrc list [--limit N] [--app A] [--label L] [--since 2h] [--json]
  clipsrc search <query> [--limit N] [--json]
  clipsrc get <id> [--json]              Show one entry with its full text
  clipsrc restore <id>                   Put an older entry back on the clipboard
  clipsrc delete <id>                    Delete one entry
  clipsrc clear --clipboard              Empty the system clipboard (history is kept)
  clipsrc clear --since 1h               Delete history from the last 30m, 1h, 1d, … (or an ISO date)
  clipsrc clear --all                    Delete all history
  clipsrc path                           Print the history database path
  clipsrc native-host [--install <extension-id> | --uninstall]   Chrome extension helper

SYNC (end-to-end encrypted; the server stores only ciphertext)
  clipsrc sync status                    Server, account, lock state and pending count
  clipsrc sync setup --url U --anon-key K   Use your own Supabase server instead of ClipSource Cloud
  clipsrc sync login --email E           Email sign-in; password read from stdin
  clipsrc sync unlock                    Sync passphrase read from stdin
  clipsrc sync once                      Push, then pull
  clipsrc sync account                   Plan, limits and registered devices (* = this device)
  clipsrc sync devices                   Registered devices with their ids (* = this device)
  clipsrc sync devices rename <id> <name>
  clipsrc sync devices remove <id>       Remove another device; it frees a Mac slot on the Free plan
  clipsrc sync new-device-id             Give this device a fresh id (when another sign-in uses it)
  clipsrc sync logout                    Sign out and forget the key on this device

The source is the frontmost app and window, plus $CLIPSOURCE_SESSION (or $CLAUDE_SESSION_ID),
the current directory and $TERM_PROGRAM. Database: $CLIPSOURCE_DB or
~/Library/Application Support/ClipSource/history.sqlite. Sync settings live in sync.json next to it;
the session and key in the Keychain ($CLIPSOURCE_SYNC_SECRETS=file keeps them in a file instead).
"""

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("clipsrc: \(message)\n".utf8))
    exit(code)
}

/// Splits `--name value` options and `--flag`s from positional arguments.
struct Arguments {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ args: ArraySlice<String>, valueOptions: Set<String>) {
        var it = args.makeIterator()
        while let arg = it.next() {
            if arg.hasPrefix("--") {
                let name = String(arg.dropFirst(2))
                if valueOptions.contains(name) {
                    guard let value = it.next() else { fail("--\(name) needs a value") }
                    options[name] = value
                } else {
                    flags.insert(name)
                }
            } else {
                positional.append(arg)
            }
        }
    }

    func int(_ name: String, default value: Int) -> Int {
        guard let raw = options[name] else { return value }
        guard let n = Int(raw), n > 0 else { fail("--\(name) must be a positive number") }
        return n
    }
}

let argv = CommandLine.arguments
guard argv.count > 1 else {
    print(usage)
    exit(0)
}
let command = argv[1]
// Chrome starts the native host with the extension origin as the only argument.
if command == "native-host" || command.hasPrefix("chrome-extension://") {
    runNativeHost(arguments: Array(argv.dropFirst(command == "native-host" ? 2 : 1)))
}
let args = Arguments(argv.dropFirst(2), valueOptions: ["label", "limit", "app", "since", "url", "anon-key", "email"])

if ["help", "-h", "--help"].contains(command) {
    print(usage)
    exit(0)
}
if command == "--version" || command == "version" {
    print(ClipSourceVersion.string)
    exit(0)
}

let store: ClipStore
do {
    store = try ClipStore()
} catch {
    fail("\(error)")
}

func entryId(_ args: Arguments) -> Int64 {
    guard let raw = args.positional.first, let id = Int64(raw.trimmingCharacters(in: CharacterSet(charactersIn: "#"))) else {
        fail("expected an entry id")
    }
    return id
}

/// Run async sync work to completion from top-level code, then exit.
func runAsync(_ work: @escaping @MainActor () async throws -> Void) -> Never {
    Task { @MainActor in
        do {
            try await work()
            exit(0)
        } catch {
            fail("\(error)")
        }
    }
    dispatchMain()
}

/// First line of stdin, for secrets that must never appear in argv.
func readSecret(_ prompt: String) -> String {
    if isatty(STDIN_FILENO) != 0 { FileHandle.standardError.write(Data("\(prompt): ".utf8)) }
    let line = (isatty(STDIN_FILENO) != 0 ? String(cString: getpass("")) : readLine(strippingNewline: true)) ?? ""
    guard !line.isEmpty else { fail("nothing read from stdin") }
    return line
}

/// Store meta flag: the next `sync once` pulls before pushing (set by unlock).
let pullFirstKey = "sync.pullFirst"

func runSync(_ args: Arguments) -> Never {
    var config = SyncConfig.load(storeURL: store.url)
    let secrets = SyncSecrets.store(storeURL: store.url)

    func client() -> SupabaseClient {
        guard let server = config.server else {
            fail("sync is not set up. Run 'clipsrc sync setup --url U --anon-key K'.")
        }
        return SupabaseClient(url: server.url, anonKey: server.anonKey, secrets: secrets)
    }

    /// Register this device before writing; the server refuses rows from unregistered devices.
    func register(_ client: SupabaseClient) async throws -> CloudAccount {
        try await client.registerDevice(id: config.device.id, name: config.device.name)
    }

    func engine(_ client: SupabaseClient) -> SyncEngine {
        guard client.session != nil else { fail("not signed in. Run 'clipsrc sync login --email E'.") }
        guard let key = secrets.syncKey(), config.enabled else { fail("sync is locked. Run 'clipsrc sync unlock'.") }
        return MainActor.assumeIsolated { SyncEngine(store: store, transport: client, key: key, device: config.device) }
    }

    switch args.positional.first ?? "status" {
    case "status":
        let session = config.isConfigured ? client().session : nil
        let server = config.server?.url.absoluteString ?? "not set"
        print("Server:   \(config.customServer ? server : "ClipSource Cloud (\(server))")")
        print("Device:   \(config.device.name) (\(config.device.id))")
        print("Account:  \(session.map { $0.email ?? $0.userId } ?? "signed out")")
        let state = session == nil ? "off" : (secrets.syncKey() != nil && config.enabled ? "unlocked" : "locked")
        print("Sync:     \(state)")
        print("Pending:  \((try? store.pendingCount()) ?? 0)")
        if let cursor = try? store.meta("sync.cursor") { print("Cursor:   \(cursor)") }
        exit(0)

    case "setup":
        guard let raw = args.options["url"]?.trimmingCharacters(in: .whitespaces), let url = URL(string: raw),
              url.scheme?.hasPrefix("http") == true, url.host != nil else { fail("--url must be an http(s) URL") }
        guard let key = args.options["anon-key"]?.trimmingCharacters(in: .whitespaces), !key.isEmpty else {
            fail("--anon-key is required")
        }
        // A session and key belong to one server: changing servers signs this device out.
        if !config.customServer || config.url != raw || config.anonKey != key {
            try? secrets.saveSession(nil)
            try? secrets.saveSyncKey(nil)
            config.enabled = false
        }
        config.url = raw
        config.anonKey = key
        config.customServer = true
        do { try config.save(storeURL: store.url) } catch { fail("\(error)") }
        print("Saved \(SyncConfig.fileURL(storeURL: store.url).path)")
        exit(0)

    case "login":
        guard let email = args.options["email"] else { fail("--email is required") }
        let client = client()
        let password = readSecret("Password")
        runAsync {
            let session = try await client.signIn(email: email, password: password)
            print("Signed in as \(session.email ?? session.userId)")
        }

    case "unlock":
        let client = client()
        guard client.session != nil else { fail("not signed in. Run 'clipsrc sync login --email E'.") }
        let passphrase = readSecret("Sync passphrase")
        runAsync {
            let key = try await SyncEngine.unlock(passphrase: passphrase, transport: client)
            try secrets.saveSyncKey(key)
            try store.markAllDirty()
            try store.setMeta(pullFirstKey, "1")
            config.enabled = true
            try config.save(storeURL: store.url)
            do {
                let account = try await register(client)
                print("Unlocked")
                print("Registered \(config.device.name) on the \(account.planName) plan")
            } catch let error as SupabaseError where error != .sessionExpired {
                // The key is valid and kept: 'sync once' registers this device once the cause is fixed.
                print("Passphrase OK, key saved")
                if case .rejected("device_in_use", _) = error { fail("\(error). Or run 'clipsrc sync new-device-id'.") }
                fail("\(error)")
            }
        }

    case "once":
        let client = client()
        let engine = engine(client)
        runAsync {
            _ = try await register(client)
            // The first sync after unlock pulls before re-uploading, so remote deletes win over the local copy.
            let result = try await engine.sync(pullFirst: try store.meta(pullFirstKey) != nil)
            try store.setMeta(pullFirstKey, nil)
            let oversized = engine.lastOversized > 0 ? ", \(engine.lastOversized) too large to sync (kept local)" : ""
            print("pushed \(result.pushed), applied \(result.applied.count), deleted \(result.deleted)\(oversized)")
        }

    case "new-device-id":
        // For a copied database whose device id another sign-in already owns (device_in_use).
        config.device.id = UUID().uuidString
        do { try config.save(storeURL: store.url) } catch { fail("\(error)") }
        print("New device id \(config.device.id); run 'clipsrc sync once' to register it")
        exit(0)

    case "account":
        let client = client()
        guard client.session != nil else { fail("not signed in. Run 'clipsrc sync login --email E'.") }
        let thisDevice = config.device.id
        runAsync {
            let account = try await client.accountStatus()
            let macs = account.deviceLimit.map { "\(account.macCount) of \($0)" } ?? "\(account.macCount) (unlimited)"
            print("Plan:       \(account.planName)\(account.subscriptionStatus.map { " (\($0))" } ?? "")")
            if let end = account.currentPeriodEnd { print("Renews:     \(SupabaseClient.formatTimestamp(end))") }
            print("Macs:       \(macs)")
            print("Retention:  \(account.retentionDays) days of synced history")
            print("Devices:")
            for device in account.devices {
                let seen = device.lastSeenAt.map { ", last seen \(ClipFormatter.shortAge($0))" } ?? ""
                print("  \(device.deviceId == thisDevice ? "*" : " ") \(device.name) [\(device.kind)]\(seen)")
            }
        }

    case "devices":
        let client = client()
        guard client.session != nil else { fail("not signed in. Run 'clipsrc sync login --email E'.") }
        let thisDevice = config.device.id
        let rest = Array(args.positional.dropFirst(2))
        switch args.positional.dropFirst().first ?? "list" {
        case "list":
            runAsync {
                for device in try await client.accountStatus().devices {
                    let seen = device.lastSeenAt.map { "  last seen \(ClipFormatter.shortAge($0))" } ?? ""
                    print("\(device.deviceId == thisDevice ? "*" : " ") \(device.deviceId)  \(device.name) [\(device.kind)]\(seen)")
                }
            }
        case "rename":
            guard rest.count >= 2 else { fail("usage: clipsrc sync devices rename <id> <name>") }
            let id = rest[0]
            let name = rest.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { fail("the new name is empty") }
            runAsync {
                try await client.renameDevice(id: id, name: name)
                if id == thisDevice {
                    config.device.name = name
                    try config.save(storeURL: store.url)
                }
                print("Renamed \(id) to \(name)")
            }
        case "remove":
            guard rest.count == 1 else { fail("usage: clipsrc sync devices remove <id>") }
            guard rest[0] != thisDevice else { fail("this is the current device; use 'clipsrc sync logout' instead") }
            let id = rest[0]
            runAsync {
                guard try await client.accountStatus().devices.contains(where: { $0.deviceId == id }) else {
                    fail("no device with that id. Run 'clipsrc sync devices'.")
                }
                try await client.removeDevice(id: id)
                print("Removed \(id)")
            }
        case let sub:
            fail("unknown devices command '\(sub)'. Run 'clipsrc help'.", code: 2)
        }

    case "logout":
        let client = client()
        runAsync {
            await client.signOut()
            try secrets.saveSyncKey(nil)
            config.enabled = false
            try config.save(storeURL: store.url)
            print("Signed out")
        }

    case let sub:
        fail("unknown sync command '\(sub)'. Run 'clipsrc help'.", code: 2)
    }
}

do {
    switch command {
    case "copy":
        let text: String
        if args.positional.isEmpty {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            text = String(decoding: data, as: UTF8.self)
        } else {
            text = args.positional.joined(separator: " ")
        }
        guard !text.isEmpty else { fail("nothing to copy") }
        let entry = try ClipActions.copy(text, label: args.options["label"], origin: .cli, store: store)
        if args.flags.contains("verbose") { print(ClipFormatter.line(entry)) }

    case "list":
        let entries = try store.recent(limit: args.int("limit", default: 20), app: args.options["app"],
                                       label: args.options["label"], since: ClipFormatter.parseSince(args.options["since"]))
        print(args.flags.contains("json") ? ClipFormatter.json(entries) : ClipFormatter.list(entries))

    case "search":
        guard !args.positional.isEmpty else { fail("expected a search query") }
        let entries = try store.search(args.positional.joined(separator: " "), limit: args.int("limit", default: 20))
        print(args.flags.contains("json") ? ClipFormatter.json(entries) : ClipFormatter.list(entries))

    case "get":
        guard let entry = try store.entry(id: entryId(args)) else { fail("no entry with that id") }
        print(args.flags.contains("json") ? ClipFormatter.json(entry) : ClipFormatter.detail(entry))

    case "restore":
        guard let entry = try ClipActions.restore(id: entryId(args), store: store) else { fail("no entry with that id") }
        print(ClipFormatter.line(entry))

    case "delete":
        let id = entryId(args)
        guard try store.entry(id: id) != nil else { fail("no entry with that id") }
        try store.delete(id: id)

    case "clear":
        if args.flags.contains("clipboard") {
            ClipActions.clearPasteboard()
            print("Clipboard cleared.")
        }
        if args.flags.contains("all") {
            try store.clear()
            print("History cleared.")
        } else if let raw = args.options["since"] {
            guard let since = ClipFormatter.parseSince(raw) else { fail("can't read --since '\(raw)' (try 30m, 1h, 1d)") }
            let removed = try store.clear(since: since)
            print("Deleted \(removed) \(removed == 1 ? "entry" : "entries").")
        } else if !args.flags.contains("clipboard") {
            fail("say what to clear: --clipboard, --since <30m|1h|1d>, or --all")
        }

    case "path":
        print(store.url.path)

    case "debug-seed":
        // Hidden test helper: N synthetic entries dated in the past, without touching the clipboard.
        guard ProcessInfo.processInfo.environment["CLIPSOURCE_DB"]?.isEmpty == false else {
            fail("debug-seed only runs against a test database ($CLIPSOURCE_DB)")
        }
        let count = Int(args.positional.first ?? "") ?? 0
        guard count > 0 else { fail("usage: clipsrc debug-seed <count>") }
        let start = Date().addingTimeInterval(-86400)
        for i in 0..<count {
            try store.record(text: "seed entry \(i)", origin: .cli, source: ClipSourceInfo(app: "clipsrc", label: "seed"),
                             at: start.addingTimeInterval(-Double(i)))
        }
        print("seeded \(count)")

    case "sync":
        runSync(args)

    default:
        fail("unknown command '\(command)'. Run 'clipsrc help'.", code: 2)
    }
} catch {
    fail("\(error)")
}
