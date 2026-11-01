@testable import ClipCore
import XCTest

final class ClipStoreTests: XCTestCase {
    private var dir: URL!
    private var store: ClipStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("clipsource-tests-\(UUID().uuidString)")
        store = try ClipStore(url: dir.appendingPathComponent("history.sqlite"))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: dir)
    }

    func testRecordAndGet() throws {
        let source = ClipSourceInfo(app: "Terminal", bundleId: "com.apple.Terminal", windowTitle: "claude — mcmc", label: "Pang reply", cwd: "/tmp/mcmc")
        let entry = try store.record(text: "hello", origin: .cli, source: source)
        let fetched = try XCTUnwrap(store.entry(id: entry.id))
        XCTAssertEqual(fetched.text, "hello")
        XCTAssertEqual(fetched.origin, .cli)
        XCTAssertEqual(fetched.source, source)
        XCTAssertEqual(fetched.hash, ClipHash.of("hello"))
    }

    func testSameTextMovesToTopWithNewSource() throws {
        let first = try store.record(text: "same", origin: .watch, source: ClipSourceInfo(app: "Safari"), at: Date(timeIntervalSince1970: 100))
        try store.record(text: "other", origin: .watch, source: ClipSourceInfo(app: "Notes"), at: Date(timeIntervalSince1970: 200))
        let again = try store.record(text: "same", origin: .mcp, source: ClipSourceInfo(app: "Terminal", label: "x"), at: Date(timeIntervalSince1970: 300))
        XCTAssertEqual(again.id, first.id)
        XCTAssertEqual(try store.count(), 2)
        let recent = try store.recent()
        XCTAssertEqual(recent.map(\.text), ["same", "other"])
        XCTAssertEqual(recent[0].source.app, "Terminal")
        XCTAssertEqual(recent[0].origin, .mcp)
    }

    func testTouchKeepsSource() throws {
        let a = try store.record(text: "a", origin: .cli, source: ClipSourceInfo(label: "keep"), at: Date(timeIntervalSince1970: 100))
        try store.record(text: "b", origin: .watch, source: ClipSourceInfo(), at: Date(timeIntervalSince1970: 200))
        try store.touch(id: a.id, at: Date(timeIntervalSince1970: 300))
        let recent = try store.recent()
        XCTAssertEqual(recent.first?.id, a.id)
        XCTAssertEqual(recent.first?.source.label, "keep")
    }

    func testRecentFilters() throws {
        try store.record(text: "one", origin: .watch, source: ClipSourceInfo(app: "WhatsApp", bundleId: "net.whatsapp.WhatsApp"), at: Date(timeIntervalSince1970: 100))
        try store.record(text: "two", origin: .cli, source: ClipSourceInfo(app: "Terminal", label: "KH group"), at: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(try store.recent(app: "whats").map(\.text), ["one"])
        XCTAssertEqual(try store.recent(app: "net.whatsapp.WhatsApp").map(\.text), ["one"])
        XCTAssertEqual(try store.recent(label: "KH").map(\.text), ["two"])
        XCTAssertEqual(try store.recent(since: Date(timeIntervalSince1970: 150)).map(\.text), ["two"])
        XCTAssertEqual(try store.recent(limit: 1).map(\.text), ["two"])
    }

    func testSearchMatchesTextLabelAndWindow() throws {
        try store.record(text: "Knowi returns 504 on Lot 30", origin: .cli, source: ClipSourceInfo(label: "Pang reply"))
        try store.record(text: "unrelated", origin: .watch, source: ClipSourceInfo(app: "Safari", windowTitle: "Release notes"))
        XCTAssertEqual(try store.search("knowi").count, 1)
        XCTAssertEqual(try store.search("pang").count, 1)
        XCTAssertEqual(try store.search("release").map(\.text), ["unrelated"])
        XCTAssertEqual(try store.search("Know 504").count, 1, "words are prefix matches and all must match")
        XCTAssertEqual(try store.search("\"quoted\" OR (").count, 0, "user input must not break FTS syntax")
    }

    func testSearchFollowsUpdatesAndDeletes() throws {
        let e = try store.record(text: "alpha", origin: .watch, source: ClipSourceInfo(label: "first"))
        try store.record(text: "alpha", origin: .cli, source: ClipSourceInfo(label: "second"))
        XCTAssertEqual(try store.search("first").count, 0)
        XCTAssertEqual(try store.search("second").count, 1)
        try store.delete(id: e.id)
        XCTAssertEqual(try store.search("alpha").count, 0)
    }

    func testPrune() throws {
        let now = Date(timeIntervalSince1970: 10 * 86400)
        try store.record(text: "old", origin: .watch, source: ClipSourceInfo(), at: Date(timeIntervalSince1970: 0))
        for i in 0..<5 {
            try store.record(text: "new \(i)", origin: .watch, source: ClipSourceInfo(), at: now.addingTimeInterval(Double(-i)))
        }
        let deleted = try store.prune(maxAge: 86400, maxCount: 3, now: now)
        XCTAssertEqual(deleted, 3)
        XCTAssertEqual(try store.recent().map(\.text), ["new 0", "new 1", "new 2"])
    }

    func testSecondConnectionSeesWrites() throws {
        let other = try ClipStore(url: store.url)
        try store.record(text: "shared", origin: .cli, source: ClipSourceInfo())
        XCTAssertEqual(try other.recent().map(\.text), ["shared"])
    }
}

final class PrivacyPolicyTests: XCTestCase {
    func testConcealedTypesAreSkipped() {
        let policy = PrivacyPolicy()
        XCTAssertFalse(policy.shouldStore(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"], bundleId: "com.example", text: "secret"))
        XCTAssertFalse(policy.shouldStore(types: ["org.nspasteboard.TransientType"], bundleId: nil, text: "x"))
    }

    func testExcludedAppsAndLimits() {
        let policy = PrivacyPolicy(maxBytes: 10)
        XCTAssertFalse(policy.shouldStore(types: [], bundleId: "com.1password.1password", text: "pw"))
        XCTAssertFalse(policy.shouldStore(types: [], bundleId: "com.example", text: "   \n"))
        XCTAssertFalse(policy.shouldStore(types: [], bundleId: "com.example", text: String(repeating: "a", count: 11)))
        XCTAssertTrue(policy.shouldStore(types: ["public.utf8-plain-text"], bundleId: "com.example", text: "hello"))
    }
}

final class FormatterTests: XCTestCase {
    func testParseSince() {
        let now = Date(timeIntervalSince1970: 100_000)
        XCTAssertEqual(ClipFormatter.parseSince("2h", now: now), now.addingTimeInterval(-7200))
        XCTAssertEqual(ClipFormatter.parseSince("30m", now: now), now.addingTimeInterval(-1800))
        XCTAssertEqual(ClipFormatter.parseSince("1d", now: now), now.addingTimeInterval(-86400))
        XCTAssertNotNil(ClipFormatter.parseSince("2026-11-01T10:00:00Z"))
        XCTAssertNotNil(ClipFormatter.parseSince("2026-11-01"))
        XCTAssertNil(ClipFormatter.parseSince("soon"))
        XCTAssertNil(ClipFormatter.parseSince(nil))
    }

    func testSourceTitle() {
        XCTAssertEqual(ClipSourceInfo(app: "Terminal", windowTitle: "claude", label: "KH").title, "KH")
        XCTAssertEqual(ClipSourceInfo(app: "Terminal", windowTitle: "claude").title, "Terminal — claude")
        XCTAssertEqual(ClipSourceInfo().title, "Unknown source")
    }

    func testPreviewCollapsesWhitespace() {
        let e = ClipEntry(id: 1, text: "a\n\n b   c", hash: "", createdAt: Date(), origin: .watch, source: ClipSourceInfo())
        XCTAssertEqual(e.preview(), "a b c")
        XCTAssertEqual(e.preview(3), "a b…")
    }
}
