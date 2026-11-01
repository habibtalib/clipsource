# ClipSource for Chrome

Types a ClipSource history entry into the focused web console as real keystrokes.

It is built for browser consoles where paste does nothing, mainly Apache Guacamole HTML5 sessions inside a PAM portal such as XTON Access Manager. Pick an entry and the extension presses each key for you, as if you typed it.

The extension types only when you ask it to: from the popup, the shortcut or the context menu.

## Install

1. Build and install ClipSource first (see the main [README](../README.md)). `clipsrc` must be on your `PATH`.
2. Open `chrome://extensions`, turn on **Developer mode**, click **Load unpacked** and choose this `chrome-extension` folder.
3. Register the native helper, which lets the extension read your history:

   ```bash
   clipsrc native-host --install kbaaegkcchoinnblhajbhjljpkgbckom
   ```

   The command writes `dev.habibtalib.clipsource.json` to `NativeMessagingHosts/` for Chrome and for each other installed browser (Chrome Beta, Chromium, Brave, Edge). The manifest points to the real path of `clipsrc`. Run the command again if you move the binary. To remove the helper, run `clipsrc native-host --uninstall`.

**Extension ID:** `kbaaegkcchoinnblhajbhjljpkgbckom`. The `key` in `manifest.json` fixes this ID, so it is the same on every Mac that loads this folder.

## Use

| Action | How |
|---|---|
| Pick an entry | Click the toolbar icon or press **⌥⇧H**. Search, then use ↑↓ and Return, or press ⌘1–9. |
| Type the latest entry | Press **⌥⇧V**, or right-click the page and choose *Type latest ClipSource entry*. |
| Stop typing | Click **Stop** in the popup or press **⌥⇧V** again. You can also close Chrome's "started debugging" bar. |

**Typing works only on hosts you allowed.** The first time you use ClipSource on a host, the popup asks "Allow typing on <host>?" and saves your answer. A page whose path contains `/xtam/` or `/guacamole/` gets that question as soon as you open the popup, but a matching path never allows a host by itself. On a host you have not allowed, the shortcut and the context menu open this question instead of typing. You can also use the **Enabled on this site** switch in the popup, or add the host on the options page.

**Typing stops when the page changes.** It stops at once if the tab navigates, reloads or changes its URL, for example when a Guacamole session times out and redirects to a sign-in page. It also stops if the tab closes or the host is removed from the allowed list. Before each line, ClipSource checks the tab is still on the same URL and the host is still allowed. Only one entry is typed at a time.

**Multi-line or long text needs a confirmation.** If an entry has more than one line or more than 500 characters, the popup first shows the line count and the first lines. Each line is followed by Enter, so every line runs as a command in the console. The shortcut and the context menu open this confirmation instead of typing.

Entries longer than 20,000 characters are refused.

Shortcuts can be changed at `chrome://extensions/shortcuts`.

## Settings

The options page sets these values:

| Setting | Default | Purpose |
|---|---|---|
| Delay between characters | 8 ms | Raise it if the console drops characters. |
| Delay after Enter | 60 ms | Gives the remote shell time to start each command. |
| Confirm threshold | 500 characters | Texts longer than this need a confirmation. Texts with more than one line always need one. |
| Allowed sites | none | Hosts (`host` or `host:port`) where typing is allowed. |

## Why Chrome shows "ClipSource started debugging this browser"

Pages ignore key events made by scripts. Guacamole reads real keyboard events only. To produce real key events, the extension uses the Chrome debugger protocol (`Input.dispatchKeyEvent`). Chrome shows its warning bar for as long as the extension is attached.

The extension attaches only to the tab you are typing into and detaches when typing ends or stops. If you close the bar, typing stops.

Characters are sent for a US keyboard layout. A shifted character such as `!` or `A` is sent with the Shift modifier. A character outside the US layout, such as `í`, is sent as its Unicode value, which Guacamole forwards as a keysym.

## Privacy

- Everything stays on your Mac. The extension reads your history through the local `clipsrc` helper over Chrome native messaging. There is no network access.
- The helper only reads. It never changes your clipboard or your history.
- The only output is the keystrokes typed into the tab you chose.
- History text is shown as plain text and is never treated as HTML.

## Development

`test/run.mjs` runs the typing engine against a real `Guacamole.Keyboard` (guacamole-common-js 1.5.0) in headless Chromium:

```bash
cd chrome-extension/test
npm install
node run.mjs
```

The test checks these things:

- The keysyms Guacamole receives for typed text, including Tab `0xFF09`, Enter `0xFF0D`, `í`, and the shifted punctuation of a US layout.
- The extension ID.
- Typing through the service worker and `chrome.debugger`.
- Stop.
- That a navigation during typing stops it.
- That a console path alone does not allow a host, until consent.
- That a second, concurrent run is refused.
- The site gate on another host.
- The install hint that the popup shows when the helper is missing.

`activeTab` needs a real user gesture, which automation cannot give. The test therefore loads a temporary copy of the extension that also has host access to `127.0.0.1` and `localhost`.

Files:

| File | Purpose |
|---|---|
| `keymap.js` | Maps text to CDP key events. This is a pure module that the test also uses. |
| `background.js` | Typing engine, navigation stop, shortcuts, context menus and the site gate. |
| `popup.*` | The entry picker, the confirmation view and typing progress. |
| `options.*` | The settings page. |
| `settings.js` | Storage defaults and the native messaging client. |
| `format.js` | Formats each entry's age and window title for display. |

The key pair for Chrome Web Store packaging is not stored in this repo.
