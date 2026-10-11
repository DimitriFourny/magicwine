#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$ROOT/dist/MagicWine.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MagicWine" "$APP/Contents/MacOS/MagicWine"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$BIN_DIR/magicwine" "$ROOT/dist/magicwine"
/usr/bin/plutil -lint "$APP/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$APP"
printf '\nBuilt %s\nCLI: %s/dist/magicwine\nLaunch: open "%s"\n' "$APP" "$ROOT" "$APP"
