#!/bin/bash
# Packs a signed Grab.app into the disk image people download: a designed window with
# Grab, an arrow and Applications (see packaging/).
#
#   scripts/make-dmg.sh build/Grab.app 1.4.0 dist/Grab-1.4.0.dmg
#
# The disk image itself stays unsigned unless it's going to be notarized: macOS checks
# a signed disk image the moment it's opened, and one signed but not notarized is
# stopped with "Apple could not verify…". release.sh signs and notarizes it when it can.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:?usage: scripts/make-dmg.sh <Grab.app> <version> <out.dmg>}"
VERSION="${2:?usage: scripts/make-dmg.sh <Grab.app> <version> <out.dmg>}"
DMG="${3:?usage: scripts/make-dmg.sh <Grab.app> <version> <out.dmg>}"

# dmgbuild writes Finder's layout directly (no Finder scripting), so this works the
# same here and on CI. It lives in a virtual environment inside .build.
DMGBUILD="${DMGBUILD:-.build/dmgbuild-venv/bin/dmgbuild}"
if [ ! -x "$DMGBUILD" ]; then
  python3 -m venv .build/dmgbuild-venv
  .build/dmgbuild-venv/bin/pip install --quiet --disable-pip-version-check "dmgbuild>=1.6,<2"
  DMGBUILD=.build/dmgbuild-venv/bin/dmgbuild
fi

WORK=$(mktemp -d)
trap 'hdiutil detach "$WORK/mnt" >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT
tiffutil -cathidpicheck packaging/dmg-background.png packaging/dmg-background@2x.png -out "$WORK/background.tiff" >/dev/null
rm -f "$DMG"
"$DMGBUILD" -s packaging/dmg_settings.py -D app="$APP" -D background="$WORK/background.tiff" \
  -D icon=Resources/AppIcon.icns "Grab $VERSION" "$DMG" >/dev/null

# The app inside must still be exactly what was signed.
mkdir "$WORK/mnt"
hdiutil attach -nobrowse -readonly -mountpoint "$WORK/mnt" "$DMG" >/dev/null 2>&1
codesign --verify --strict --deep "$WORK/mnt/Grab.app"
test "$(defaults read "$WORK/mnt/Grab.app/Contents/Info" CFBundleShortVersionString)" = "$VERSION"
hdiutil detach "$WORK/mnt" >/dev/null 2>&1
