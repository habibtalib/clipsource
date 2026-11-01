import AppKit
import Carbon.HIToolbox
import ClipCore
import SwiftUI

/// Global hotkey through Carbon's RegisterEventHotKey (no Accessibility needed).
final class HotKey {
    static let keyV = UInt32(kVK_ANSI_V)
    static let optionCommand = UInt32(optionKey | cmdKey)

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { hotKey.action() }
            return noErr
        }, 1, &eventType, context, &handlerRef)
        let id = EventHotKeyID(signature: OSType(0x434C_5053), id: 1) // "CLPS"
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}

/// Floating history panel shown by the hotkey.
@MainActor
final class HistoryPanel: NSObject, NSWindowDelegate {
    private let panel: NSPanel

    init(model: AppModel) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 540),
                        styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        super.init()
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let view = HistoryView(onPicked: { [weak self] in self?.close() }).environmentObject(model)
        panel.contentView = NSHostingView(rootView: view)
    }

    func toggle() {
        if panel.isVisible { close() } else { show() }
    }

    func show() {
        AppModel.shared.reload()
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}
