import Foundation

/// Chrome native messaging: framing and request handling for the browser extension.
/// Each message is a 4-byte little-endian length followed by UTF-8 JSON. Read-only:
/// nothing here writes the pasteboard or the store.
public enum NativeMessaging {
    public static let hostName = "dev.habibtalib.clipsource"
    /// Chrome caps host→browser messages at 1 MB; apply the same cap both ways.
    public static let maxMessageBytes = 1024 * 1024
    public static let defaultLimit = 30
    public static let maxLimit = 200

    public enum FrameError: Error, Equatable, CustomStringConvertible {
        case truncated
        case tooLarge(Int)
        case notJSONObject

        public var description: String {
            switch self {
            case .truncated: return "truncated message"
            case .tooLarge(let n): return "message of \(n) bytes exceeds \(NativeMessaging.maxMessageBytes)"
            case .notJSONObject: return "message is not a JSON object"
            }
        }
    }

    // MARK: Framing

    public static func encode(_ message: [String: Any]) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys, .withoutEscapingSlashes])
        guard body.count <= maxMessageBytes else { throw FrameError.tooLarge(body.count) }
        var length = UInt32(body.count).littleEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(body)
        return frame
    }

    /// Length prefix of a frame header, or an error for a short or oversize header.
    public static func length(ofHeader header: Data) throws -> Int {
        guard header.count >= 4 else { throw FrameError.truncated }
        let bytes = [UInt8](header.prefix(4))
        let length = Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
        guard length <= maxMessageBytes else { throw FrameError.tooLarge(length) }
        return length
    }

    public static func decodeBody(_ body: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: body), let dict = object as? [String: Any] else {
            throw FrameError.notJSONObject
        }
        return dict
    }

    /// Decode one complete frame. Returns nil for empty input (clean EOF).
    public static func decode(_ frame: Data) throws -> [String: Any]? {
        if frame.isEmpty { return nil }
        let length = try length(ofHeader: frame)
        let body = frame.dropFirst(4)
        guard body.count >= length else { throw FrameError.truncated }
        return try decodeBody(Data(body.prefix(length)))
    }

    // MARK: Requests

    public static func handle(request: [String: Any], store: ClipStore) -> [String: Any] {
        let op = request["op"] as? String ?? ""
        do {
            switch op {
            case "ping":
                return ["ok": true, "version": ClipSourceVersion.string]
            case "recent":
                let limit = min(max(intValue(request["limit"]) ?? defaultLimit, 1), maxLimit)
                let query = (request["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let entries = query.isEmpty ? try store.recent(limit: limit) : try store.search(query, limit: limit)
                return ["ok": true, "entries": entries.map(serialize)]
            case "get":
                guard let id = intValue(request["id"]) else { return failure("get needs a numeric id") }
                guard let entry = try store.entry(id: Int64(id)) else { return failure("no entry #\(id)") }
                return ["ok": true, "entry": serialize(entry)]
            case "latest":
                guard let entry = try store.recent(limit: 1).first else { return failure("history is empty") }
                return ["ok": true, "entry": serialize(entry)]
            default:
                return failure(op.isEmpty ? "missing op" : "unknown op \(op)")
            }
        } catch {
            return failure("\(error)")
        }
    }

    /// Entry as JSON: the ClipEntry Codable fields (minus the hash) plus a cleaned window title.
    public static func serialize(_ entry: ClipEntry) -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var dict = (try? encoder.encode(entry))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        dict["hash"] = nil
        if let clean = entry.source.cleanWindowTitle { dict["windowClean"] = clean }
        return dict
    }

    private static func failure(_ message: String) -> [String: Any] {
        ["ok": false, "error": message]
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let n as Int: return n
        case let n as Double where n.rounded() == n: return Int(n)
        case let s as String: return Int(s)
        default: return nil
        }
    }
}
