import Foundation
import XCTest
@testable import ClipCore

final class SourceContextTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("clipsource-ctx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func write(_ text: String, to path: String) throws -> URL {
        let url = tmp.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: RepoInfo

    func testRepoFromNestedFolder() throws {
        _ = try write("ref: refs/heads/feat/switcher\n", to: "myrepo/.git/HEAD")
        let nested = tmp.appendingPathComponent("myrepo/Sources/App")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let info = RepoInfo.resolve(nested.path)
        XCTAssertEqual(info?.name, "myrepo")
        XCTAssertEqual(info?.branch, "feat/switcher")
        XCTAssertEqual(info?.display, "myrepo · feat/switcher")
    }

    func testRepoWorktreeAndDetachedHead() throws {
        _ = try write("0123456789abcdef\n", to: "main/.git/worktrees/wt/HEAD")
        _ = try write("gitdir: \(tmp.path)/main/.git/worktrees/wt\n", to: "wt/.git")
        let info = RepoInfo.resolve(tmp.appendingPathComponent("wt").path)
        XCTAssertEqual(info?.name, "wt")
        XCTAssertEqual(info?.branch, "0123456")
    }

    func testNoRepo() {
        XCTAssertNil(RepoInfo.resolve(nil))
        XCTAssertNil(RepoInfo.resolve(tmp.appendingPathComponent("nowhere").path))
    }

    // MARK: SessionIndex

    private func transcript(id: String, lines: [String], project: String = "-Users-x-Git-app") throws -> URL {
        try write(lines.joined(separator: "\n") + "\n", to: "profile/projects/\(project)/\(id).jsonl")
    }

    func testSessionByIdAndTitle() throws {
        _ = try transcript(id: "abc-123", lines: [
            #"{"type":"user","cwd":"/Users/x/Git/app","message":{"content":"hi"}}"#,
            #"{"type":"ai-title","aiTitle":"fix-login-bug","sessionId":"abc-123"}"#,
            #"{"type":"assistant","cwd":"/Users/x/Git/app/Sources","message":{"content":"ok"}}"#,
        ])
        let index = SessionIndex(roots: [tmp.appendingPathComponent("profile/projects")])
        let byId = index.session(id: "abc-123")
        XCTAssertEqual(byId?.title, "fix-login-bug")
        XCTAssertEqual(byId?.cwd, "/Users/x/Git/app/Sources")
        XCTAssertEqual(index.session(matchingWindowTitle: "✳ fix-login-bug")?.id, "abc-123")
        XCTAssertEqual(index.session(matchingWindowTitle: "⠂ Fix-Login-Bug ")?.id, "abc-123")
        XCTAssertNil(index.session(matchingWindowTitle: "something-else"))
        XCTAssertNil(index.session(id: "../etc"))
    }

    func testSessionReadsAppendedLinesAndRenames() throws {
        let url = try transcript(id: "s1", lines: [#"{"type":"agent-name","agentName":"first-name","sessionId":"s1"}"#])
        let index = SessionIndex(roots: [tmp.appendingPathComponent("profile/projects")])
        XCTAssertEqual(index.session(id: "s1")?.title, "first-name")

        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data((#"{"type":"custom-title","customTitle":"renamed","cwd":"/tmp/a\"b"}"# + "\n").utf8))
        try handle.close()
        let session = index.session(id: "s1")
        XCTAssertEqual(session?.title, "renamed")
        XCTAssertEqual(session?.cwd, "/tmp/a\"b")
        // Old titles still match a terminal that has not refreshed its title yet.
        XCTAssertEqual(index.session(matchingWindowTitle: "first-name")?.id, "s1")
    }

    func testNormalizedTitle() {
        XCTAssertEqual(SessionIndex.normalizedTitle("✳ Fix Bug"), "fix bug")
        XCTAssertEqual(SessionIndex.normalizedTitle("  ● ⠐ deploy-api "), "deploy-api")
        XCTAssertEqual(SessionIndex.normalizedTitle("~/Git/app"), "~/git/app")
    }

    // MARK: SourceEnricher

    func testEnrichTerminalCopyWithSession() throws {
        _ = try write("ref: refs/heads/main\n", to: "app/.git/HEAD")
        let appPath = tmp.appendingPathComponent("app").path
        _ = try transcript(id: "sess-9", lines: [
            #"{"type":"ai-title","aiTitle":"paste-switcher"}"#,
            "{\"type\":\"user\",\"cwd\":\"\(appPath)\"}",
        ])
        let index = SessionIndex(roots: [tmp.appendingPathComponent("profile/projects")])
        let source = ClipSourceInfo(app: "iTerm2", bundleId: "com.googlecode.iterm2", windowTitle: "✳ paste-switcher")
        let enriched = SourceEnricher.enrich(source, index: index)
        XCTAssertEqual(enriched?.session, "sess-9")
        XCTAssertEqual(enriched?.cwd, appPath)

        let details = SourceEnricher.details(for: enriched!, index: index)
        XCTAssertEqual(details.sessionTitle, "paste-switcher")
        XCTAssertEqual(details.repo?.display, "app · main")
        XCTAssertEqual(details.line, "paste-switcher · app · main")
    }

    func testEnrichTerminalFolderTitle() throws {
        let folder = tmp.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let index = SessionIndex(roots: [])
        let source = ClipSourceInfo(app: "Terminal", bundleId: "com.apple.Terminal", windowTitle: "habib@mbp:\(folder.path) — -zsh")
        XCTAssertEqual(SourceEnricher.enrich(source, index: index)?.cwd, folder.path)
    }

    func testNonTerminalKeepsChatTitle() {
        let index = SessionIndex(roots: [])
        let source = ClipSourceInfo(app: "Slack", bundleId: "com.tinyspeck.slackmacgap", windowTitle: "general (Channel) - Acme - Slack")
        XCTAssertNil(SourceEnricher.enrich(source, index: index))
        XCTAssertEqual(SourceEnricher.details(for: source, index: index).chat, "general (Channel) - Acme")
    }

    func testCLICopyGetsSessionTitle() throws {
        _ = try transcript(id: "cli-1", lines: [#"{"type":"ai-title","aiTitle":"release-notes"}"#])
        let index = SessionIndex(roots: [tmp.appendingPathComponent("profile/projects")])
        let source = ClipSourceInfo(app: "iTerm2", session: "cli-1", cwd: "/nonexistent")
        XCTAssertEqual(SourceEnricher.details(for: source, index: index).sessionTitle, "release-notes")
    }
}
