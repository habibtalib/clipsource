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
            Image(systemName: "doc.on.clipboard")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(AppModel.shared)
        }
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
}
