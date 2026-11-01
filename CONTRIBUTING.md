# Contributing

Issues and pull requests are welcome.

## Develop

```bash
swift build
swift test
swift run ClipSource          # run the menu-bar app unbundled (fine for UI work)
Scripts/bundle-app.sh         # build a real .app into ./build
```

To use a throwaway history while testing:

```bash
export CLIPSOURCE_DB=/tmp/clipsource-dev.sqlite
```

To render the history panel to a PNG without screen-recording permission (handy for screenshots):

```bash
CLIPSOURCE_DB=/tmp/sample.sqlite CLIPSOURCE_SNAPSHOT=panel.png CLIPSOURCE_SNAPSHOT_APPEARANCE=dark swift run ClipSource
```

## Guidelines

- Keep the project dependency-free. It uses only Apple frameworks and the system SQLite.
- Logic that the CLI, the MCP server and the app share goes in `Sources/ClipCore`, with tests in `Tests/ClipCoreTests`.
- Privacy comes first. Nothing leaves the machine, and contents marked concealed are never stored. Any change to what gets recorded must say so in the PR.
- Run `swift build` and `swift test` before opening a PR. CI runs both on macOS 15 (the app supports macOS 14+).
