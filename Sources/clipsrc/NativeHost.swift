import ClipCore
import Foundation

/// Browser directories (under ~/Library/Application Support) that read native messaging host manifests.
/// Chrome is always written; the others only when the browser is installed.
private let nativeHostBrowsers = [
    "Google/Chrome",
    "Google/Chrome Beta",
    "Chromium",
    "BraveSoftware/Brave-Browser",
    "Microsoft Edge",
]

/// `clipsrc native-host`: Chrome native messaging host for the ClipSource extension.
/// Without options it serves frames on stdin/stdout until EOF. Chrome runs the manifest `path`
/// with the caller origin (`chrome-extension://<id>/`) and --parent-window as arguments, so
/// main.swift also dispatches here when the first argument is an extension origin; extra
/// arguments are ignored.
func runNativeHost(arguments: [String]) -> Never {
    if let i = arguments.firstIndex(of: "--install") {
        guard i + 1 < arguments.count else { nativeHostFail("--install needs the extension ID") }
        installNativeHost(extensionId: arguments[i + 1])
        exit(0)
    }
    if arguments.contains("--uninstall") {
        uninstallNativeHost()
        exit(0)
    }
    serveNativeHost()
}

private func nativeHostFail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("clipsrc native-host: \(message)\n".utf8))
    exit(1)
}

private func serveNativeHost() -> Never {
    let input = FileHandle.standardInput
    let output = FileHandle.standardOutput
    let store: ClipStore
    do {
        store = try ClipStore()
    } catch {
        // Answer the first request with the error so the extension can show it.
        if let header = try? input.read(upToCount: 4), let length = try? NativeMessaging.length(ofHeader: header) {
            _ = try? input.read(upToCount: length)
        }
        if let frame = try? NativeMessaging.encode(["ok": false, "error": "cannot open history: \(error)"]) {
            output.write(frame)
        }
        exit(1)
    }
    while true {
        guard let header = try? input.read(upToCount: 4), !header.isEmpty else { exit(0) }
        let response: [String: Any]
        do {
            let length = try NativeMessaging.length(ofHeader: header)
            let body = try input.read(upToCount: length) ?? Data()
            guard body.count == length else { throw NativeMessaging.FrameError.truncated }
            response = NativeMessaging.handle(request: try NativeMessaging.decodeBody(body), store: store)
        } catch {
            // A broken frame leaves the stream out of sync: report it and stop.
            if let frame = try? NativeMessaging.encode(["ok": false, "error": "\(error)"]) { output.write(frame) }
            exit(1)
        }
        let frame = (try? NativeMessaging.encode(response))
            ?? (try? NativeMessaging.encode(["ok": false, "error": "response too large"]))
            ?? Data()
        output.write(frame)
    }
}

/// Absolute path of this binary with symlinks resolved (Chrome needs a real path).
private func executablePath() -> String {
    let candidate = Bundle.main.executablePath ?? CommandLine.arguments[0]
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    if realpath(candidate, &buffer) != nil { return String(cString: buffer) }
    return URL(fileURLWithPath: candidate).standardizedFileURL.resolvingSymlinksInPath().path
}

private func manifestDirectories(createChrome: Bool) -> [URL] {
    let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    return nativeHostBrowsers.compactMap { browser in
        let dir = support.appendingPathComponent(browser)
        let exists = FileManager.default.fileExists(atPath: dir.path)
        guard exists || (createChrome && browser == "Google/Chrome") else { return nil }
        return dir.appendingPathComponent("NativeMessagingHosts")
    }
}

private func installNativeHost(extensionId: String) {
    let id = extensionId.trimmingCharacters(in: .whitespaces)
    guard id.count == 32, id.allSatisfy({ ("a"..."p").contains($0) }) else {
        nativeHostFail("\"\(extensionId)\" is not an extension ID (32 letters a-p, see chrome://extensions)")
    }
    let manifest: [String: Any] = [
        "name": NativeMessaging.hostName,
        "description": "ClipSource clipboard history for the ClipSource browser extension",
        "path": executablePath(),
        "type": "stdio",
        "allowed_origins": ["chrome-extension://\(id)/"],
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
        nativeHostFail("cannot encode manifest")
    }
    print("Host binary: \(executablePath())")
    for dir in manifestDirectories(createChrome: true) {
        let file = dir.appendingPathComponent("\(NativeMessaging.hostName).json")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            print("Wrote \(file.path)")
        } catch {
            FileHandle.standardError.write(Data("clipsrc native-host: cannot write \(file.path): \(error)\n".utf8))
        }
    }
    print("Allowed extension: chrome-extension://\(id)/")
}

private func uninstallNativeHost() {
    var removed = 0
    for dir in manifestDirectories(createChrome: false) {
        let file = dir.appendingPathComponent("\(NativeMessaging.hostName).json")
        if (try? FileManager.default.removeItem(at: file)) != nil {
            print("Removed \(file.path)")
            removed += 1
        }
    }
    if removed == 0 { print("No native host manifests found.") }
}
