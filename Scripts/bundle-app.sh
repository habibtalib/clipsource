#!/usr/bin/env bash
# Build ClipSource.app (menu-bar app) plus the clipsrc and clipsource-mcp CLIs.
#   Scripts/bundle-app.sh            build into ./build
#   Scripts/bundle-app.sh --install  also copy the app to ~/Applications and the CLIs to ~/.local/bin
# CLIPSOURCE_SUPABASE_URL and CLIPSOURCE_SUPABASE_ANON_KEY (both optional) bake a default sync server into the app.
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="$(sed -n 's/.*static let string = "\(.*\)".*/\1/p' Sources/ClipCore/Models.swift)"
BUNDLE_ID="dev.habibtalib.clipsource"
OUT="build"
APP="$OUT/ClipSource.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/ClipSource" "$APP/Contents/MacOS/ClipSource"
cp Xcode/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN/clipsrc" "$BIN/clipsource-mcp" "$OUT/"

xml_escape() { local s="${1//&/&amp;}"; s="${s//</&lt;}"; printf '%s' "${s//>/&gt;}"; }
SYNC_KEYS=""
if [[ -n "${CLIPSOURCE_SUPABASE_URL:-}" && -n "${CLIPSOURCE_SUPABASE_ANON_KEY:-}" ]]; then
  SYNC_KEYS="  <key>ClipSourceSupabaseURL</key><string>$(xml_escape "$CLIPSOURCE_SUPABASE_URL")</string>
  <key>ClipSourceSupabaseAnonKey</key><string>$(xml_escape "$CLIPSOURCE_SUPABASE_ANON_KEY")</string>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ClipSource</string>
  <key>CFBundleDisplayName</key><string>ClipSource</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>ClipSource</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>${BUNDLE_ID}</string>
      <key>CFBundleURLSchemes</key><array><string>clipsource</string></array>
    </dict>
  </array>
${SYNC_KEYS}
</dict>
</plist>
PLIST

# Ad-hoc signature. Accessibility permission is tied to the signature, so re-grant after rebuilding.
codesign --force --sign - "$APP"
codesign --force --sign - "$OUT/clipsrc" "$OUT/clipsource-mcp"
echo "Built $APP ($VERSION)"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications" "$HOME/.local/bin"
  rm -rf "$HOME/Applications/ClipSource.app"
  cp -R "$APP" "$HOME/Applications/"
  install -m 0755 "$OUT/clipsrc" "$OUT/clipsource-mcp" "$HOME/.local/bin/"
  echo "Installed ~/Applications/ClipSource.app and ~/.local/bin/{clipsrc,clipsource-mcp}"
  echo "Register the MCP server:  claude mcp add clipsource -s user -- \$HOME/.local/bin/clipsource-mcp"
fi
