# ClipSource

A macOS menu-bar clipboard manager that records **where every copy came from**: the app, the window or chat title, and, for copies made by AI coding sessions, the session, project folder and a label. It ships with a CLI and an [MCP](https://modelcontextprotocol.io) server, so Claude Code and other MCP clients can copy with a tag and read the history.

Use it when several chats, terminals and agent sessions all write to your clipboard, so you can still tell which one an entry came from.

- **Source per entry.** Each entry records the app, its focused window title, a label, the session ID, the working directory and the terminal.
- **Menu bar plus hotkey.** The menu bar shows the latest copy's source live. Search, group by source, and click to copy back. Press ⌥⌘V for a floating panel.
- **Desktop widgets.** *Latest Copy* (small, medium) and *Recent Copies* (medium, large). Click a row to copy it again.
- **CLI.** `clipsrc copy --label "Reply to Sam"` works as a drop-in for `pbcopy` and adds the tag.
- **MCP server.** `clipboard_copy`, `clipboard_history`, `clipboard_search`, `clipboard_get` and `clipboard_restore`.
- **Private by default.** History stays local in SQLite. Password-manager copies (concealed types) and excluded apps are never stored.
- **Zero dependencies.** Swift, SwiftUI, AppKit and the system SQLite (FTS5).

Requires macOS 14 or later.

## Install

```bash
git clone https://github.com/habibtalib/clipsource.git
cd clipsource
Scripts/bundle-app.sh --install
open ~/Applications/ClipSource.app
```

This installs `ClipSource.app` in `~/Applications`, and `clipsrc` and `clipsource-mcp` in `~/.local/bin`. Make sure `~/.local/bin` is on your `PATH`.

### With widgets (signed build)

Widgets need a team-signed app that shares an App Group with the widget extension, so they come from an Xcode build. A free Personal Team works; find your team ID in *Xcode → Settings → Accounts*.

```bash
brew install xcodegen
CLIPSOURCE_TEAM=<your team id> Scripts/build-widgets.sh --install
```

Then right-click the desktop, choose *Edit Widgets*, search for ClipSource and add *Latest Copy* or *Recent Copies*. The app rewrites the widget snapshot and reloads the widgets on every clipboard change. Relative times tick live. To keep clipboard text off the desktop, turn on *Settings → Hide clipboard text in widgets*.

The SwiftPM build (`bundle-app.sh`) has everything except widgets.

### Permissions

To record window titles (chat names, terminal tab titles, browser tabs), ClipSource needs **Accessibility** permission: *System Settings → Privacy & Security → Accessibility*. The app asks on first launch. Without the permission it still records the app name.

The app is ad-hoc signed, so macOS treats each rebuild as a new app. After rebuilding, remove ClipSource from the Accessibility list and add it again.

For the CLI and MCP server to record the terminal's window title too, give your terminal app (Terminal, iTerm2, and so on) Accessibility permission as well.

## How the source is captured

| Copy made by | Recorded |
|---|---|
| You (⌘C in any app) | Frontmost app, bundle ID, focused window title |
| `clipsrc copy` | The above, plus `--label`, the current directory, `$TERM_PROGRAM` and the session ID |
| MCP `clipboard_copy` | Same as `clipsrc`. The folder is the MCP client's project directory. |

The session ID is taken from `$CLIPSOURCE_SESSION`, then `$CLAUDE_SESSION_ID`, then `$CLAUDE_CODE_SESSION_ID`.

The CLI and MCP server write the entry before setting the clipboard. The app's watcher skips any content recorded in the last 3 seconds, so each copy is stored once and the richer source is kept. Copying identical text again moves the existing entry to the top with the new source.

## CLI

```bash
echo "Draft reply" | clipsrc copy --label "Sam reply"   # copy and tag
clipsrc copy --label notes some words here               # text as arguments
clipsrc list --limit 10                                   # recent entries
clipsrc list --app WhatsApp --since 2h --json
clipsrc search invoice
clipsrc get 42                                            # full text and source
clipsrc restore 42                                        # copy entry 42 back to the clipboard
clipsrc path                                              # database location
```

## MCP server

```bash
claude mcp add clipsource -s user -- ~/.local/bin/clipsource-mcp
```

| Tool | Arguments | Does |
|---|---|---|
| `clipboard_copy` | `text`, `label?` | Sets the clipboard and records the source |
| `clipboard_history` | `limit?`, `app?`, `label?`, `since?` (`30m`, `2h`, `7d` or ISO 8601) | Lists recent entries with source and preview |
| `clipboard_search` | `query`, `limit?` | Full-text search over text, labels, window titles and apps |
| `clipboard_get` | `id` | Returns the full text and source details |
| `clipboard_restore` | `id` | Puts an older entry back on the clipboard |

Example instruction for an agent: *"Copy the draft with `clipboard_copy` and label it with the chat it's for."*

## Data and privacy

- History is stored in `~/Library/Application Support/ClipSource/history.sqlite`; set `$CLIPSOURCE_DB` to use a different file. The database runs in WAL mode, so the app, CLI and MCP server can use it at the same time.
- Text only, up to 1 MB per entry.
- By default, history is kept for 30 days or 5,000 entries; change this in Settings.
- Never stored:
  - Contents marked `org.nspasteboard.ConcealedType`, `TransientType` or `AutoGeneratedType`, which password managers set.
  - Copies from excluded apps. The defaults are 1Password, Keychain Access, Passwords and Bitwarden; edit the list in Settings.
- "Pause" in the menu stops recording.
- Widgets read only a small snapshot of the last 6 entries (160-character previews) from the App Group container.
- Nothing is sent over the network.

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md).

```
Sources/ClipCore         Store (SQLite + FTS5), watcher, source resolver, privacy policy, shared actions
Sources/ClipSourceApp    SwiftUI menu-bar app, ⌥⌘V panel, settings
Widget/                  WidgetKit extension (reads the App Group snapshot)
project.yml, Xcode/      XcodeGen spec, Info.plists and entitlements for the signed build
Sources/clipsrc          CLI
Sources/clipsource-mcp   MCP server (stdio JSON-RPC)
Tests/ClipCoreTests      Unit tests
```

## License

[MIT](LICENSE)
