#!/bin/bash
# Builds Grab.app.
#
#   scripts/build.sh              release build → build/Grab.app
#   scripts/build.sh --install    …and copy it to /Applications
#   scripts/build.sh --run        …and (re)launch it
#   scripts/build.sh --debug      debug build (enables command-line debug hooks)
#
# Signs with your Apple Development / Developer ID certificate when one is in the
# keychain, so macOS keeps Grab's permissions across rebuilds. Falls back to ad-hoc.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
INSTALL=0
RUN=0
for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG=debug ;;
    --install) INSTALL=1 ;;
    --run) RUN=1 ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

if [ ! -f Resources/AppIcon.icns ]; then
  echo "▸ Rendering icon"
  TMP=$(mktemp -d)
  swift scripts/make_icon.swift "$TMP/AppIcon.iconset" >/dev/null
  iconutil -c icns "$TMP/AppIcon.iconset" -o Resources/AppIcon.icns
  rm -rf "$TMP"
fi

echo "▸ Compiling ($CONFIG)"
swift build -c "$CONFIG" --product Grab
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Grab"

APP=build/Grab.app
echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Grab"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application|Apple Development/ {print $2; exit}')
if [ -n "$IDENTITY" ]; then
  echo "▸ Signing with \"$IDENTITY\""
  codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
else
  echo "▸ Signing ad-hoc (permissions will need re-granting after each rebuild)"
  codesign --force --sign - "$APP"
fi

if [ "$INSTALL" = 1 ]; then
  echo "▸ Installing to /Applications"
  pkill -x Grab 2>/dev/null || true
  rm -rf /Applications/Grab.app
  cp -R "$APP" /Applications/Grab.app
  APP=/Applications/Grab.app
fi

if [ "$RUN" = 1 ]; then
  pkill -x Grab 2>/dev/null || true
  sleep 0.4
  open "$APP"
  echo "▸ Launched $APP"
fi

echo "✓ Done"
