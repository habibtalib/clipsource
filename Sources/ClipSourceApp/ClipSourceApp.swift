import AppKit
import ClipCore
import SwiftUI

@main
struct ClipSourceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            // Close the menu window after a copy, like the ⌥⌘V panel.
            HistoryView(onPicked: { NSApp.keyWindow?.orderOut(nil) })
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

/// Menu bar: the icon only. A new copy shows its source next to the icon for a few seconds
/// (Settings → "Show new copy in the menu bar for").
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            icon
            if let text = model.menuBarFlash {
                Text(text)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder private var icon: some View {
        if model.paused {
            Image(systemName: "pause.circle")
        } else if model.menuBarFlash != nil {
            Image(systemName: "checkmark.circle.fill")
        } else {
            Image(nsImage: BrandIcons.menuBar)
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
            if PanelSnapshot.runIfRequested(model: model) { return }
            model.pasteSwitcher = PasteSwitcher(model: model)
            model.onPasteSwitcherSettingChanged = { MainActor.assumeIsolated { AppModel.shared.updatePasteSwitcher() } }
            model.updatePasteSwitcher()
            model.selectionCopier = SelectionCopier(model: model)
            model.updateSelectionCopier()
            // Accessibility may be granted later; check again periodically until both features are running.
            Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { timer in
                MainActor.assumeIsolated {
                    let model = AppModel.shared
                    model.updatePasteSwitcher()
                    model.updateSelectionCopier()
                    let switcherDone = model.pasteSwitcher?.isRunning == true || !model.holdToChoosePaste
                    let copierDone = model.selectionCopier?.isRunning == true || !model.copyOnSelect
                    if switcherDone && copierDone { timer.invalidate() }
                }
            }
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
                case "auth-callback":
                    break  // handled by the sign-in session
                default:
                    panel?.show()
                }
            }
        }
    }
}
