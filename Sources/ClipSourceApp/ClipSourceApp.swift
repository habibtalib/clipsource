import AppKit
import ClipCore
import SwiftUI

@main
struct ClipSourceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            HistoryView()
                .environmentObject(AppModel.shared)
        } label: {
            MenuBarLabel(model: AppModel.shared)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(AppModel.shared)
        }
    }
}

/// Live clipboard status in the menu bar: icon plus the newest entry's source.
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.menuBarShowsSource, let latest = model.latest {
            HStack(spacing: 3) {
                Image(systemName: model.paused ? "pause.circle" : "doc.on.clipboard")
                Text(Self.short(latest.source.label ?? latest.source.app ?? latest.source.title))
            }
        } else {
            Image(systemName: model.paused ? "pause.circle" : "doc.on.clipboard")
        }
    }

    private static func short(_ text: String, max: Int = 22) -> String {
        text.count > max ? String(text.prefix(max - 1)) + "…" : text
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKey: HotKey?
    private var panel: HistoryPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        MainActor.assumeIsolated {
            let model = AppModel.shared
            model.start()
            panel = HistoryPanel(model: model)
            // ⌥⌘V opens the history panel.
            hotKey = HotKey(keyCode: HotKey.keyV, modifiers: HotKey.optionCommand) { [weak self] in
                self?.panel?.toggle()
            }
        }
    }

    /// Widget taps: `clipsource://panel` opens the panel, `clipsource://restore/<id>` re-copies an entry.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls where url.scheme == WidgetBridge.urlScheme {
                switch url.host {
                case "restore":
                    if let id = Int64(url.lastPathComponent) { AppModel.shared.restore(id: id) }
                default:
                    panel?.show()
                }
            }
        }
    }
}
