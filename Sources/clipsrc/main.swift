import ClipCore
import Foundation

let usage = """
clipsrc \(ClipSourceVersion.string): clipboard with source tracking

USAGE
  clipsrc copy [--label L] [text...]     Copy text (stdin when no text) and tag it with its source
  clipsrc list [--limit N] [--app A] [--label L] [--since 2h] [--json]
  clipsrc search <query> [--limit N] [--json]
  clipsrc get <id> [--json]              Show one entry with its full text
  clipsrc restore <id>                   Put an older entry back on the clipboard
  clipsrc path                           Print the history database path

The source is the frontmost app and window, plus $CLIPSOURCE_SESSION (or $CLAUDE_SESSION_ID),
the current directory and $TERM_PROGRAM. Database: $CLIPSOURCE_DB or
~/Library/Application Support/ClipSource/history.sqlite.
"""

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("clipsrc: \(message)\n".utf8))
    exit(code)
}

/// Splits `--name value` options and `--flag`s from positional arguments.
struct Arguments {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ args: ArraySlice<String>, valueOptions: Set<String>) {
        var it = args.makeIterator()
        while let arg = it.next() {
            if arg.hasPrefix("--") {
                let name = String(arg.dropFirst(2))
                if valueOptions.contains(name) {
                    guard let value = it.next() else { fail("--\(name) needs a value") }
                    options[name] = value
                } else {
                    flags.insert(name)
                }
            } else {
                positional.append(arg)
            }
        }
    }

    func int(_ name: String, default value: Int) -> Int {
        guard let raw = options[name] else { return value }
        guard let n = Int(raw), n > 0 else { fail("--\(name) must be a positive number") }
        return n
    }
}

let argv = CommandLine.arguments
guard argv.count > 1 else {
    print(usage)
    exit(0)
}
let command = argv[1]
let args = Arguments(argv.dropFirst(2), valueOptions: ["label", "limit", "app", "since"])

if ["help", "-h", "--help"].contains(command) {
    print(usage)
    exit(0)
}
if command == "--version" || command == "version" {
    print(ClipSourceVersion.string)
    exit(0)
}

let store: ClipStore
do {
    store = try ClipStore()
} catch {
    fail("\(error)")
}

func entryId(_ args: Arguments) -> Int64 {
    guard let raw = args.positional.first, let id = Int64(raw.trimmingCharacters(in: CharacterSet(charactersIn: "#"))) else {
        fail("expected an entry id")
    }
    return id
}

do {
    switch command {
    case "copy":
        let text: String
        if args.positional.isEmpty {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            text = String(decoding: data, as: UTF8.self)
        } else {
            text = args.positional.joined(separator: " ")
        }
        guard !text.isEmpty else { fail("nothing to copy") }
        let entry = try ClipActions.copy(text, label: args.options["label"], origin: .cli, store: store)
        if args.flags.contains("verbose") { print(ClipFormatter.line(entry)) }

    case "list":
        let entries = try store.recent(limit: args.int("limit", default: 20), app: args.options["app"],
                                       label: args.options["label"], since: ClipFormatter.parseSince(args.options["since"]))
        print(args.flags.contains("json") ? ClipFormatter.json(entries) : ClipFormatter.list(entries))

    case "search":
        guard !args.positional.isEmpty else { fail("expected a search query") }
        let entries = try store.search(args.positional.joined(separator: " "), limit: args.int("limit", default: 20))
        print(args.flags.contains("json") ? ClipFormatter.json(entries) : ClipFormatter.list(entries))

    case "get":
        guard let entry = try store.entry(id: entryId(args)) else { fail("no entry with that id") }
        print(args.flags.contains("json") ? ClipFormatter.json(entry) : ClipFormatter.detail(entry))

    case "restore":
        guard let entry = try ClipActions.restore(id: entryId(args), store: store) else { fail("no entry with that id") }
        print(ClipFormatter.line(entry))

    case "path":
        print(store.url.path)

    default:
        fail("unknown command '\(command)'. Run 'clipsrc help'.", code: 2)
    }
} catch {
    fail("\(error)")
}
