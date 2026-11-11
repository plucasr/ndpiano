#!/bin/bash
# Rebuild NordPiano (release), deploy to ~/Applications, re-sign, flush caches.
# Usage: ./build-app.sh          (from anywhere)
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/NordPiano.app"
SRC="$REPO/dist/NordPiano.app"

echo "→ Building release…"
swift build -c release --package-path "$REPO"

echo "→ Syncing bundle (binary, fonts, icon)…"
cp "$REPO/.build/release/NordPianoApp" "$APP/Contents/MacOS/"
cp "$REPO/Sources/NordPianoApp/Fonts/"*.ttf "$APP/Contents/Resources/"
if [ -f "$SRC/Contents/Resources/AppIcon.icns" ]; then
  cp "$SRC/Contents/Resources/AppIcon.icns" "$APP/Contents/Resources/"
fi

echo "→ Re-signing…"
codesign --force --sign - "$APP"
codesign --verify "$APP"

echo "→ Flushing Launch Services / Dock cache…"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
killall Dock 2>/dev/null || true

echo "✔ Done. Relaunch NordPiano from ~/Applications."
