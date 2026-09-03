#!/bin/bash
# Regenerates the app icon from MakeIcon.swift.
# Run this after changing the artwork, then rebuild with ./build.sh.
set -euo pipefail
cd "$(dirname "$0")"

WORK="$(mktemp -d)"
COMPLETED=0
# Bash 3.2 — the /bin/bash macOS ships — reaches an EXIT trap with $? already
# zeroed when set -u aborts the script, so the exit status alone cannot tell a
# finished run from one that died on an unset variable. The sentinel can.
cleanup() {
  rc=$?
  rm -rf "$WORK"
  if [ "$rc" = 0 ] && [ "$COMPLETED" != 1 ]; then rc=1; fi
  exit $rc
}
trap cleanup EXIT

VARIANT="${1:-bars}"
swiftc -O MakeIcon.swift -o "$WORK/makeicon"
"$WORK/makeicon" "$WORK/AppIcon.iconset" "$VARIANT"
iconutil --convert icns "$WORK/AppIcon.iconset" --output AppIcon.icns

# A plain PNG as well, for the README.
cp "$WORK/AppIcon.iconset/icon_512x512@2x.png" AppIcon.png

# GitHub's link preview wants a wide image: 1280x640, under 1 MB.
"$WORK/makeicon" SocialPreview.png social

echo "wrote $(pwd)/AppIcon.icns and AppIcon.png"

COMPLETED=1
