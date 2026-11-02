import AppKit
import ApplicationServices
import ClipCore

/// Copy on select: text highlighted with the mouse goes straight to the clipboard, like the X11 primary selection.
///
/// Watches mouse drags, double/triple clicks and ⇧-clicks in other apps, then reads the focused element's
/// selected text through Accessibility. Nothing is copied from password fields, from excluded apps, or when
/// recording is paused. Apps that don't expose selected text to Accessibility are skipped (no synthetic ⌘C).
@MainActor
final class SelectionCopier {
    /// Pointer travel (points) that turns a click into a drag selection.
    static let dragThreshold: CGFloat = 4
    /// Wait after mouse-up so the app finishes updating its selection.
    static let settleDelay: TimeInterval = 0.06

    private var monitor: Any?
    private var downLocation: NSPoint?
    private var dragged = false
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    var isRunning: Bool { monitor != nil }

    /// Starts watching the mouse. Returns false when Accessibility is not granted yet.
    @discardableResult
    func start() -> Bool {
        guard monitor == nil else { return true }
        guard AXIsProcessTrusted() else { return false }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { event in
            MainActor.assumeIsolated { AppModel.shared.selectionCopier?.handle(event) }
        }
        return monitor != nil
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        downLocation = nil
        dragged = false
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            downLocation = NSEvent.mouseLocation
            dragged = false
        case .leftMouseDragged:
            if let start = downLocation, !dragged {
                let now = NSEvent.mouseLocation
                dragged = hypot(now.x - start.x, now.y - start.y) >= Self.dragThreshold
            }
        case .leftMouseUp:
            let selecting = dragged || event.clickCount >= 2 || event.modifierFlags.contains(.shift)
            downLocation = nil
            dragged = false
            guard selecting else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay) {
                MainActor.assumeIsolated { AppModel.shared.selectionCopier?.copySelection() }
            }
        default:
            break
        }
    }

    private func copySelection() {
        guard !model.paused, let text = Self.selectedText() else { return }
        let bundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let bundleId, bundleId == Bundle.main.bundleIdentifier || model.policy.excludedBundleIds.contains(bundleId) { return }
        let pasteboard = NSPasteboard.general
        guard pasteboard.string(forType: .string) != text else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // The pasteboard watcher records it on its next tick, with the frontmost app as the source.
    }

    /// Selected text of the focused UI element, or nil (nothing selected, a secure field, or no AX support).
    static func selectedText() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement

        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        let secure = kAXSecureTextFieldSubrole as String
        if (role as? String) == secure || (subrole as? String) == secure { return nil }

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
              let text = value as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}
