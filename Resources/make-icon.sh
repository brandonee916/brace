#!/bin/bash
# Regenerates the app icon from MakeIcon.swift.
# Run this after changing the artwork, then rebuild with ./build.sh.
set -euo pipefail
cd "$(dirname "$0")"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

VARIANT="${1:-bars}"
swiftc -O MakeIcon.swift -o "$WORK/makeicon"
"$WORK/makeicon" "$WORK/AppIcon.iconset" "$VARIANT"
iconutil --convert icns "$WORK/AppIcon.iconset" --output AppIcon.icns

# A plain PNG as well, for the README.
cp "$WORK/AppIcon.iconset/icon_512x512@2x.png" AppIcon.png

# GitHub's link preview wants a wide image: 1280x640, under 1 MB.
"$WORK/makeicon" SocialPreview.png social

echo "wrote $(pwd)/AppIcon.icns and AppIcon.png"
