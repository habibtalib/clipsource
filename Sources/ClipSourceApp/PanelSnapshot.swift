import AppKit
import SwiftUI

/// Developer aid: `CLIPSOURCE_SNAPSHOT=out.png` renders the history panel offscreen to a PNG and quits.
/// `CLIPSOURCE_SNAPSHOT_APPEARANCE=dark` renders it in dark mode. Pair with `CLIPSOURCE_DB` for sample data.
@MainActor
enum PanelSnapshot {
    private static var window: NSWindow?

    static func runIfRequested(model: AppModel) -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CLIPSOURCE_SNAPSHOT"], !path.isEmpty else { return false }
        let dark = env["CLIPSOURCE_SNAPSHOT_APPEARANCE"] == "dark"

        let host = NSHostingView(rootView: HistoryView().environmentObject(model))
        host.frame = NSRect(x: 0, y: 0, width: 460, height: 580)
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 460, height: 580),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.97, alpha: 1)
        window.contentView = host
        window.orderFrontRegardless()
        Self.window = window

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
            host.cacheDisplay(in: host.bounds, to: rep)
            do {
                try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("snapshot: \(error)\n".utf8))
                exit(1)
            }
        }
        return true
    }
}
