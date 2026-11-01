import Foundation

/// What a row shows about where a copy came from, beyond the app name.
public struct SourceDetails: Equatable, Sendable {
    /// Claude Code session title, when the copy came from (or through) a session.
    public var sessionTitle: String?
    /// Repository and branch of the working folder.
    public var repo: RepoInfo?
    /// Chat or document title from the window (browsers, Slack, WhatsApp, Claude desktop).
    public var chat: String?

    public init(sessionTitle: String? = nil, repo: RepoInfo? = nil, chat: String? = nil) {
        self.sessionTitle = sessionTitle
        self.repo = repo
        self.chat = chat
    }

    public var isEmpty: Bool { sessionTitle == nil && repo == nil && chat == nil }

    /// `fix-login-bug · clipsource · main`
    public var line: String? {
        var parts: [String] = []
        if let sessionTitle { parts.append(sessionTitle) } else if let chat { parts.append(chat) }
        if let repo { parts.append(repo.display) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Adds the Claude Code session and working folder to a copy's source, and describes it for display.
public enum SourceEnricher {
    /// Terminal apps whose window title is the shell's folder or the Claude Code session title.
    public static let terminalBundleIds: Set<String> = [
        "com.googlecode.iterm2", "com.apple.Terminal", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper", "com.raphaelamorim.rio",
    ]

    /// Returns the source with `session` and `cwd` filled in, or nil when nothing could be added.
    public static func enrich(_ source: ClipSourceInfo, index: SessionIndex = .shared) -> ClipSourceInfo? {
        var s = source
        if let id = s.session, s.cwd == nil, let session = index.session(id: id) {
            s.cwd = session.cwd
        }
        if s.session == nil, let bundleId = s.bundleId, terminalBundleIds.contains(bundleId), let title = s.windowTitle {
            if let session = index.session(matchingWindowTitle: title) {
                s.session = session.id
                if s.cwd == nil { s.cwd = session.cwd }
            } else if s.cwd == nil, let path = folder(inWindowTitle: title) {
                s.cwd = path
            }
        }
        return s == source ? nil : s
    }

    /// Display details. Reads transcripts and `.git`, so call it off the main thread.
    public static func details(for source: ClipSourceInfo, index: SessionIndex = .shared) -> SourceDetails {
        var details = SourceDetails()
        if let id = source.session, let session = index.session(id: id) {
            details.sessionTitle = session.title
        }
        details.repo = RepoInfo.resolve(source.cwd)
        if details.sessionTitle == nil, let title = source.cleanWindowTitle {
            let isTerminal = source.bundleId.map(terminalBundleIds.contains) ?? false
            // A terminal title that is just `user@host:~/path` adds nothing once the repo is known.
            if !(isTerminal && (folder(inWindowTitle: title) != nil || title.contains("@"))) { details.chat = title }
        }
        return details
    }

    /// `habib@mbp:~/Git/clipsource`, `~/Git/clipsource (zsh)`, `/Users/x/y — -zsh` → an existing folder.
    public static func folder(inWindowTitle title: String, fileManager: FileManager = .default) -> String? {
        let candidates = title.components(separatedBy: CharacterSet(charactersIn: " \t—–()")).flatMap { word -> [String] in
            guard let start = word.firstIndex(where: { $0 == "~" || $0 == "/" }) else { return [] }
            return [String(word[start...])]
        }
        for candidate in candidates {
            let path = (candidate.trimmingCharacters(in: CharacterSet(charactersIn: ":,;")) as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if path.count > 1, fileManager.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue { return path }
        }
        return nil
    }
}
