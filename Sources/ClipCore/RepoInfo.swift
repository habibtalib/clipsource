import Foundation

/// The git repository a folder belongs to: its name and current branch.
public struct RepoInfo: Equatable, Sendable {
    public var name: String
    public var branch: String?
    public var root: String

    public init(name: String, branch: String?, root: String) {
        self.name = name
        self.branch = branch
        self.root = root
    }

    /// `clipsource · main`
    public var display: String {
        if let branch, branch != "HEAD", !branch.isEmpty { return "\(name) · \(branch)" }
        return name
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (info: RepoInfo?, at: Date)] = [:]

    /// Walks up from `path` to the nearest `.git` (folder, or file for worktrees). Cached for 30 seconds.
    public static func resolve(_ path: String?, fileManager: FileManager = .default, now: Date = Date()) -> RepoInfo? {
        guard let path = path?.trimmingCharacters(in: .whitespaces), !path.isEmpty else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        lock.lock()
        if let hit = cache[expanded], now.timeIntervalSince(hit.at) < 30 {
            lock.unlock()
            return hit.info
        }
        lock.unlock()

        var info: RepoInfo?
        var dir = URL(fileURLWithPath: expanded).standardizedFileURL
        while dir.path != "/" && !dir.path.isEmpty {
            let git = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: git.path, isDirectory: &isDir) {
                let gitDir = isDir.boolValue ? git : resolveGitFile(git, base: dir)
                info = RepoInfo(name: dir.lastPathComponent, branch: gitDir.flatMap(branch(gitDir:)), root: dir.path)
                break
            }
            dir.deleteLastPathComponent()
        }
        lock.lock()
        cache[expanded] = (info, now)
        lock.unlock()
        return info
    }

    /// Worktrees and submodules have a `.git` file: `gitdir: <path>`.
    static func resolveGitFile(_ file: URL, base: URL) -> URL? {
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path).standardizedFileURL
    }

    /// `ref: refs/heads/main` → `main`; a detached HEAD → short SHA.
    static func branch(gitDir: URL) -> String? {
        guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !head.isEmpty else { return nil }
        if head.hasPrefix("ref: ") {
            let ref = String(head.dropFirst(5))
            return ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
        }
        return String(head.prefix(7))
    }
}
