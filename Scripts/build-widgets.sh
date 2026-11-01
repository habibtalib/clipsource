#!/usr/bin/env bash
# Signed build of ClipSource.app with the WidgetKit extension (widgets need a team-signed app + App Group).
#   CLIPSOURCE_TEAM=<team id> Scripts/build-widgets.sh            build into ./build/xcode
#   CLIPSOURCE_TEAM=<team id> Scripts/build-widgets.sh --install  also install the app and the CLIs
# Find your team ID in Xcode > Settings > Accounts (a free Personal Team works).
set -euo pipefail

cd "$(dirname "$0")/.."
: "${CLIPSOURCE_TEAM:?Set CLIPSOURCE_TEAM to your Apple Developer team ID}"
command -v xcodegen >/dev/null || { echo "Install XcodeGen: brew install xcodegen" >&2; exit 1; }

export CLIPSOURCE_TEAM
xcodegen generate --quiet
xcodebuild -project ClipSource.xcodeproj -scheme ClipSource -configuration Release \
  -derivedDataPath build/xcode -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$CLIPSOURCE_TEAM" build | grep -E '^(\*\*|error:|warning: .*ClipSource)' || true

APP="build/xcode/Build/Products/Release/ClipSource.app"
[[ -d "$APP/Contents/PlugIns/ClipSourceWidget.appex" ]] || { echo "Build failed: no widget extension in $APP" >&2; exit 1; }
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  swift build -c release
  BIN="$(swift build -c release --show-bin-path)"
  mkdir -p "$HOME/Applications" "$HOME/.local/bin"
  osascript -e 'quit app "ClipSource"' 2>/dev/null || true
  rm -rf "$HOME/Applications/ClipSource.app"
  cp -R "$APP" "$HOME/Applications/"
  install -m 0755 "$BIN/clipsrc" "$BIN/clipsource-mcp" "$HOME/.local/bin/"
  pluginkit -a "$HOME/Applications/ClipSource.app/Contents/PlugIns/ClipSourceWidget.appex" || true
  open "$HOME/Applications/ClipSource.app"
  echo "Installed and launched ~/Applications/ClipSource.app (widgets: right-click the desktop > Edit Widgets > ClipSource)"
fi
