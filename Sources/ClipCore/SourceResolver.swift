import AppKit
import ApplicationServices

/// Finds out which app and window a copy came from.
public enum SourceResolver {
    /// Whether this process may read other apps' window titles. `prompt` shows the system dialog.
    @discardableResult
    public static func isTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    /// Frontmost app, plus its focused window title when Accessibility is granted.
    public static func frontmost() -> ClipSourceInfo {
        guard let app = NSWorkspace.shared.frontmostApplication else { return ClipSourceInfo() }
        var info = ClipSourceInfo(app: app.localizedName, bundleId: app.bundleIdentifier)
        if AXIsProcessTrusted() {
            info.windowTitle = focusedWindowTitle(pid: app.processIdentifier)
        }
        return info
    }

    /// Source for copies made through the CLI or MCP: frontmost app/window plus the caller's
    /// session (`$CLIPSOURCE_SESSION`, `$CLAUDE_SESSION_ID`, `$CLAUDE_CODE_SESSION_ID`), cwd and terminal.
    public static func callerEnvironment(label: String? = nil) -> ClipSourceInfo {
        let env = ProcessInfo.processInfo.environment
        var info = frontmost()
        info.label = label?.nilIfBlank
        info.session = (env["CLIPSOURCE_SESSION"] ?? env["CLAUDE_SESSION_ID"] ?? env["CLAUDE_CODE_SESSION_ID"])?.nilIfBlank
        info.cwd = FileManager.default.currentDirectoryPath
        info.terminal = env["TERM_PROGRAM"]?.nilIfBlank
        return info
    }

    static func focusedWindowTitle(pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else {
            return nil
        }
        return (title as? String)?.nilIfBlank
    }
}
