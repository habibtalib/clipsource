@testable import ClipCore
import XCTest

final class NativeMessagingTests: XCTestCase {
    private var dir: URL!
    private var store: ClipStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("clipsource-native-\(UUID().uuidString)")
        store = try ClipStore(url: dir.appendingPathComponent("history.sqlite"))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: dir)
    }

    func testFrameRoundTrip() throws {
        let frame = try NativeMessaging.encode(["op": "recent", "query": "línea 2", "limit": 5])
        XCTAssertEqual(try NativeMessaging.length(ofHeader: frame), frame.count - 4)
        let decoded = try XCTUnwrap(NativeMessaging.decode(frame))
        XCTAssertEqual(decoded["op"] as? String, "recent")
        XCTAssertEqual(decoded["query"] as? String, "línea 2")
        XCTAssertEqual(decoded["limit"] as? Int, 5)
    }

    func testHeaderIsLittleEndian() throws {
        let frame = try NativeMessaging.encode(["op": "ping"])
        let body = frame.count - 4
        XCTAssertEqual(Array(frame.prefix(4)), [UInt8(body & 0xFF), UInt8(body >> 8 & 0xFF), 0, 0])
    }

    func testEmptyInputIsEOF() throws {
        XCTAssertNil(try NativeMessaging.decode(Data()))
    }

    func testTruncatedFrameRejected() throws {
        let frame = try NativeMessaging.encode(["op": "ping"])
        XCTAssertThrowsError(try NativeMessaging.decode(frame.dropLast(2))) {
            XCTAssertEqual($0 as? NativeMessaging.FrameError, .truncated)
        }
        XCTAssertThrowsError(try NativeMessaging.decode(Data([1, 0])))
    }

    func testOversizeLengthRejected() throws {
        let tooBig = UInt32(NativeMessaging.maxMessageBytes + 1)
        let header = Data([UInt8(tooBig & 0xFF), UInt8(tooBig >> 8 & 0xFF), UInt8(tooBig >> 16 & 0xFF), UInt8(tooBig >> 24)])
        XCTAssertThrowsError(try NativeMessaging.length(ofHeader: header)) {
            XCTAssertEqual($0 as? NativeMessaging.FrameError, .tooLarge(Int(tooBig)))
        }
        XCTAssertThrowsError(try NativeMessaging.encode(["text": String(repeating: "x", count: NativeMessaging.maxMessageBytes)]))
    }

    func testNonObjectBodyRejected() throws {
        var frame = Data([2, 0, 0, 0])
        frame.append(Data("[]".utf8))
        XCTAssertThrowsError(try NativeMessaging.decode(frame)) {
            XCTAssertEqual($0 as? NativeMessaging.FrameError, .notJSONObject)
        }
    }

    func testPing() {
        let response = NativeMessaging.handle(request: ["op": "ping"], store: store)
        XCTAssertEqual(response["ok"] as? Bool, true)
        XCTAssertEqual(response["version"] as? String, ClipSourceVersion.string)
    }

    func testRecentAndSearch() throws {
        try store.record(text: "uptime", origin: .watch,
                         source: ClipSourceInfo(app: "Google Chrome", windowTitle: "XTAM - Google Chrome"),
                         at: Date(timeIntervalSince1970: 100))
        try store.record(text: "systemctl status cbc", origin: .cli, source: ClipSourceInfo(app: "Terminal", label: "CBC check"),
                         at: Date(timeIntervalSince1970: 200))

        let recent = NativeMessaging.handle(request: ["op": "recent"], store: store)
        XCTAssertEqual(recent["ok"] as? Bool, true)
        let entries = try XCTUnwrap(recent["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.map { $0["text"] as? String }, ["systemctl status cbc", "uptime"])
        XCTAssertNil(entries[0]["hash"])
        XCTAssertEqual(entries[0]["origin"] as? String, "cli")
        XCTAssertEqual((entries[0]["source"] as? [String: Any])?["label"] as? String, "CBC check")
        XCTAssertEqual(entries[1]["windowClean"] as? String, "XTAM")
        XCTAssertEqual(entries[1]["createdAt"] as? String, "1970-01-01T00:01:40Z")

        let limited = NativeMessaging.handle(request: ["op": "recent", "limit": 1], store: store)
        XCTAssertEqual((limited["entries"] as? [[String: Any]])?.count, 1)

        let searched = NativeMessaging.handle(request: ["op": "recent", "query": "systemctl"], store: store)
        XCTAssertEqual((searched["entries"] as? [[String: Any]])?.map { $0["text"] as? String }, ["systemctl status cbc"])

        // The response must survive framing (all values JSON-serializable).
        XCTAssertNoThrow(try NativeMessaging.encode(recent))
    }

    func testGetAndLatest() throws {
        let first = try store.record(text: "first", origin: .watch, source: ClipSourceInfo(), at: Date(timeIntervalSince1970: 100))
        try store.record(text: "second", origin: .watch, source: ClipSourceInfo(), at: Date(timeIntervalSince1970: 200))

        let got = NativeMessaging.handle(request: ["op": "get", "id": Int(first.id)], store: store)
        XCTAssertEqual((got["entry"] as? [String: Any])?["text"] as? String, "first")
        XCTAssertEqual((got["entry"] as? [String: Any])?["id"] as? Int, Int(first.id))

        let missing = NativeMessaging.handle(request: ["op": "get", "id": 9999], store: store)
        XCTAssertEqual(missing["ok"] as? Bool, false)
        XCTAssertEqual(NativeMessaging.handle(request: ["op": "get"], store: store)["ok"] as? Bool, false)

        let latest = NativeMessaging.handle(request: ["op": "latest"], store: store)
        XCTAssertEqual((latest["entry"] as? [String: Any])?["text"] as? String, "second")
    }

    func testLatestOnEmptyStoreAndUnknownOp() {
        XCTAssertEqual(NativeMessaging.handle(request: ["op": "latest"], store: store)["ok"] as? Bool, false)
        let unknown = NativeMessaging.handle(request: ["op": "copy", "text": "x"], store: store)
        XCTAssertEqual(unknown["ok"] as? Bool, false)
        XCTAssertEqual(unknown["error"] as? String, "unknown op copy")
        XCTAssertEqual(NativeMessaging.handle(request: [:], store: store)["error"] as? String, "missing op")
    }
}
