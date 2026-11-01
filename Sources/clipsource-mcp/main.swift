import ClipCore
import Foundation

// Minimal MCP server over stdio: newline-delimited JSON-RPC 2.0, tools only.

func log(_ message: String) {
    FileHandle.standardError.write(Data("clipsource-mcp: \(message)\n".utf8))
}

let store: ClipStore
do {
    store = try ClipStore()
} catch {
    log("\(error)")
    exit(1)
}

func send(_ message: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else {
        log("could not encode response")
        return
    }
    data.append(0x0A)
    FileHandle.standardOutput.write(data)
}

func schema(_ properties: [String: [String: Any]], required: [String] = []) -> [String: Any] {
    ["type": "object", "properties": properties, "required": required]
}

let tools: [[String: Any]] = [
    [
        "name": "clipboard_copy",
        "description": "Put text on the macOS clipboard and record where it came from (this session's folder, terminal window and an optional label such as the chat it is meant for). Use instead of pbcopy.",
        "inputSchema": schema([
            "text": ["type": "string", "description": "Text to copy, exactly as it should be pasted."],
            "label": ["type": "string", "description": "Short tag for the target, e.g. 'Pang reply' or 'KH group'."],
        ], required: ["text"]),
    ],
    [
        "name": "clipboard_history",
        "description": "List recent clipboard entries, newest first, with source app, window, label, folder and a preview.",
        "inputSchema": schema([
            "limit": ["type": "integer", "description": "Max entries (default 20, max 200)."],
            "app": ["type": "string", "description": "Filter by app name or bundle ID."],
            "label": ["type": "string", "description": "Filter by label substring."],
            "since": ["type": "string", "description": "Only entries since '30m', '2h', '7d' or an ISO 8601 date."],
        ]),
    ],
    [
        "name": "clipboard_search",
        "description": "Full-text search over clipboard text, labels, window titles and app names.",
        "inputSchema": schema([
            "query": ["type": "string", "description": "Words to find (prefix match, all words must match)."],
            "limit": ["type": "integer", "description": "Max entries (default 20, max 200)."],
        ], required: ["query"]),
    ],
    [
        "name": "clipboard_get",
        "description": "Get one clipboard entry with its full text and source details.",
        "inputSchema": schema(["id": ["type": "integer", "description": "Entry id from history or search."]], required: ["id"]),
    ],
    [
        "name": "clipboard_restore",
        "description": "Put an older clipboard entry back on the clipboard, keeping its original source.",
        "inputSchema": schema(["id": ["type": "integer", "description": "Entry id from history or search."]], required: ["id"]),
    ],
]

struct ToolError: Error {
    let message: String
}

func int(_ value: Any?) -> Int? {
    switch value {
    case let n as NSNumber: return n.intValue
    case let s as String: return Int(s.trimmingCharacters(in: CharacterSet(charactersIn: "# ")))
    default: return nil
    }
}

func limit(_ args: [String: Any]) -> Int {
    min(max(int(args["limit"]) ?? 20, 1), 200)
}

func requireId(_ args: [String: Any]) throws -> Int64 {
    guard let id = int(args["id"]) else { throw ToolError(message: "'id' is required") }
    return Int64(id)
}

func callTool(_ name: String, _ args: [String: Any]) throws -> String {
    switch name {
    case "clipboard_copy":
        guard let text = args["text"] as? String, !text.isEmpty else { throw ToolError(message: "'text' is required") }
        let entry = try ClipActions.copy(text, label: args["label"] as? String, origin: .mcp, store: store)
        return "Copied to clipboard (entry #\(entry.id), \(text.count) characters).\n" + ClipFormatter.line(entry, previewLength: 80)
    case "clipboard_history":
        let entries = try store.recent(limit: limit(args), app: args["app"] as? String, label: args["label"] as? String,
                                       since: ClipFormatter.parseSince(args["since"] as? String))
        return ClipFormatter.list(entries)
    case "clipboard_search":
        guard let query = args["query"] as? String, !query.isEmpty else { throw ToolError(message: "'query' is required") }
        return ClipFormatter.list(try store.search(query, limit: limit(args)))
    case "clipboard_get":
        guard let entry = try store.entry(id: requireId(args)) else { throw ToolError(message: "No entry with that id.") }
        return ClipFormatter.detail(entry)
    case "clipboard_restore":
        guard let entry = try ClipActions.restore(id: requireId(args), store: store) else {
            throw ToolError(message: "No entry with that id.")
        }
        return "Restored to clipboard.\n" + ClipFormatter.line(entry, previewLength: 80)
    default:
        throw ToolError(message: "Unknown tool '\(name)'.")
    }
}

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty,
          let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
    // Notifications (no id) need no reply.
    guard let id = message["id"] else { continue }
    let method = message["method"] as? String ?? ""
    let params = message["params"] as? [String: Any] ?? [:]

    switch method {
    case "initialize":
        send(["jsonrpc": "2.0", "id": id, "result": [
            "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": "clipsource", "version": ClipSourceVersion.string],
        ]])
    case "ping":
        send(["jsonrpc": "2.0", "id": id, "result": [String: Any]()])
    case "tools/list":
        send(["jsonrpc": "2.0", "id": id, "result": ["tools": tools]])
    case "tools/call":
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        let result: [String: Any]
        do {
            result = ["content": [["type": "text", "text": try callTool(name, args)]]]
        } catch let error as ToolError {
            result = ["content": [["type": "text", "text": error.message]], "isError": true]
        } catch {
            result = ["content": [["type": "text", "text": "\(error)"]], "isError": true]
        }
        send(["jsonrpc": "2.0", "id": id, "result": result])
    default:
        send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
    }
}
