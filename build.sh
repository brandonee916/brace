#!/bin/bash
# Builds "Brace.app" using the Swift compiler that ships with Xcode
# Command Line Tools. No Xcode project, no package manager, no network needed.
#
#   ./build.sh              build into ./build
#   ./build.sh --install    build, then copy into /Applications
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Brace"
BUNDLE_ID="com.brandonee.brace"
DEST_DIR="build"

# The newest heading in CHANGELOG.md is the version, so releasing means editing
# one file rather than remembering to bump a number in here as well.
VERSION="$(sed -n 's/^## \([0-9][0-9.]*\).*/\1/p' CHANGELOG.md | head -1)"
VERSION="${VERSION:-1.0.0}"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "error: swiftc not found. Install the Xcode Command Line Tools with:" >&2
  echo "         xcode-select --install" >&2
  exit 1
fi

# Staging happens outside the project folder on purpose. Desktop and Documents
# are often iCloud-synced, and the extended attributes iCloud adds make codesign
# refuse to sign the bundle in place.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
BUNDLE="$STAGE/$APP_NAME.app"

echo "Building $APP_NAME $VERSION…"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

swiftc \
  -parse-as-library \
  -O \
  -target arm64-apple-macos14.0 \
  -o "$BUNDLE/Contents/MacOS/Brace" \
  Sources/*.swift

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Brace</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Local utility. Edits your own Claude Desktop config.</string>
</dict>
</plist>
PLIST

if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
fi

# The in-app guide renders this file directly, so the README is the single source
# of truth rather than something the app duplicates and lets drift.
cp README.md "$BUNDLE/Contents/Resources/README.md"
cp CHANGELOG.md "$BUNDLE/Contents/Resources/CHANGELOG.md"

# Ad-hoc signature so macOS treats it as a normal locally built app.
codesign --force --sign - "$BUNDLE"
codesign --verify --strict "$BUNDLE" && echo "  signature verified (ad-hoc)"

mkdir -p "$DEST_DIR"
rm -rf "${DEST_DIR:?}/$APP_NAME.app"
ditto "$BUNDLE" "$DEST_DIR/$APP_NAME.app"
echo "Built: $(pwd)/$DEST_DIR/$APP_NAME.app"

if [ "${1:-}" = "--install" ]; then
  rm -rf "/Applications/$APP_NAME.app"
  ditto "$BUNDLE" "/Applications/$APP_NAME.app"
  echo "Installed: /Applications/$APP_NAME.app"
  echo "Open it with:  open \"/Applications/$APP_NAME.app\""
else
  echo "Open it with:  open \"$DEST_DIR/$APP_NAME.app\""
  echo "Install it to /Applications with:  ./build.sh --install"
fi
