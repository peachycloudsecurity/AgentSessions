#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="AgentSessions"
BUILD_DIR="$ROOT_DIR/.build/release"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICON_FILE="$ROOT_DIR/assets/AppIcon.icns"

echo "Building release binary..."
swift build -c release --package-path "$ROOT_DIR"

if [[ ! -f "$BUILD_DIR/$APP_NAME" ]]; then
  echo "Error: release binary not found at $BUILD_DIR/$APP_NAME" >&2
  exit 1
fi

# Build icon if iconset exists and icns is missing/stale
if [[ -d "$ROOT_DIR/assets/AppIcon.iconset" ]]; then
  if [[ ! -f "$ICON_FILE" || "$ROOT_DIR/assets/AppIcon.iconset" -nt "$ICON_FILE" ]]; then
    echo "Building app icon..."
    iconutil -c icns "$ROOT_DIR/assets/AppIcon.iconset" -o "$ICON_FILE"
  fi
fi

echo "Creating app bundle at $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BUILD_DIR/$APP_NAME" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

if [[ -f "$ICON_FILE" ]]; then
  cp "$ICON_FILE" "$RESOURCES_DIR/AppIcon.icns"
fi

cat > "$CONTENTS_DIR/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>AgentSessions</string>
    <key>CFBundleIdentifier</key>
    <string>com.peachycloudsecurity.agent-sessions</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleName</key>
    <string>Agent Sessions</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Peachy Cloud Security. All rights reserved.</string>
</dict>
</plist>
EOF

echo "Installing to /Applications..."
if rm -rf "/Applications/$APP_NAME.app" 2>/dev/null && ditto "$APP_DIR" "/Applications/$APP_NAME.app" 2>/dev/null; then
  :
else
  echo "No write access to /Applications — asking for admin permission..."
  osascript -e "do shell script \"rm -rf '/Applications/$APP_NAME.app' && ditto '$APP_DIR' '/Applications/$APP_NAME.app'\" with administrator privileges with prompt \"Agent Sessions wants to install to /Applications\""
fi

echo ""
echo "Done."
echo "Installed: /Applications/$APP_NAME.app"
echo "Run with:  open \"/Applications/$APP_NAME.app\""
