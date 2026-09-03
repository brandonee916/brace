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

# A plain PNG as well, for the README and GitHub's social preview.
cp "$WORK/AppIcon.iconset/icon_512x512@2x.png" AppIcon.png

echo "wrote $(pwd)/AppIcon.icns and AppIcon.png"
