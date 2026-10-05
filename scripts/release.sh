#!/bin/bash
# Makes a release of Grab that other people can download and open.
#
#   scripts/release.sh 1.2.0
#
# In dist/:
#   Grab-1.2.0.dmg   the drag-to-Applications disk image people download
#   Grab-1.2.0.zip   what Grab's built-in updater installs (attach both to the GitHub release)
#   grab.rb          a Homebrew cask for that release
#
# Signing, in order of preference:
#   GRAB_RELEASE_P12 / GRAB_RELEASE_P12_PASSWORD
#       the "Grab Release" key (a .p12 file and its password). Every official release is
#       signed with it, so Grab's updater accepts each new one. It's loaded into a
#       throwaway keychain that's deleted afterwards. The release workflow sets these.
#   your "Developer ID Application" certificate (paid Apple Developer Program), notarized
#   your "Apple Development" certificate: opens only on your own Macs
#
# Notarizing (Developer ID only) needs either
#   NOTARY_PROFILE=grab-notary  a profile you save once with
#       xcrun notarytool store-credentials grab-notary --apple-id <your Apple ID> --team-id <TEAMID>
#   or, for CI, an App Store Connect API key: NOTARY_KEY (path to the .p8), NOTARY_KEY_ID, NOTARY_ISSUER.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?(-[A-Za-z0-9.]+)?$ ]]; then
  echo "usage: scripts/release.sh <version>   (like 1.2.0)" >&2
  exit 1
fi
REPO="0x1p0/grab"
DIST=dist
BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null || echo 1)

echo "▸ Grab $VERSION (build $BUILD_NUMBER)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" Resources/Info.plist

scripts/build.sh
APP=build/Grab.app

SIGN=()          # extra codesign arguments
STAMP=--timestamp=none
PUBLIC=0
RELEASE_KEY=0
if [ -n "${GRAB_RELEASE_P12:-}" ]; then
  # A keychain of its own, never added to your keychain list, deleted on exit.
  KC_DIR=$(mktemp -d)
  KC="$KC_DIR/grab-release.keychain-db"
  KC_PASS=$(uuidgen)
  trap 'security delete-keychain "$KC" 2>/dev/null; rm -rf "$KC_DIR"' EXIT
  security create-keychain -p "$KC_PASS" "$KC"
  security set-keychain-settings -lut 3600 "$KC"
  security unlock-keychain -p "$KC_PASS" "$KC"
  security import "$GRAB_RELEASE_P12" -k "$KC" -P "${GRAB_RELEASE_P12_PASSWORD:-}" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple: -s -k "$KC_PASS" "$KC" >/dev/null
  # On CI (a throwaway machine) codesign needs it in the search list; on your Mac it's left out.
  if [ "${CI:-}" = "true" ]; then
    security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')
  fi
  IDENTITY=$(security find-identity -p codesigning "$KC" | awk '/"Grab Release"/ {print $2; exit}')
  if [ -z "$IDENTITY" ]; then
    echo "✗ GRAB_RELEASE_P12 doesn't hold the Grab Release certificate" >&2
    exit 1
  fi
  SIGN=(--keychain "$KC")
  RELEASE_KEY=1
  echo "▸ Signing with the Grab Release key"
else
  IDS=$(security find-identity -v -p codesigning 2>/dev/null || true)
  IDENTITY=$(awk -F'"' '/Developer ID Application/ {print $2; exit}' <<<"$IDS")
  if [ -n "$IDENTITY" ]; then
    PUBLIC=1
    STAMP=--timestamp
    echo "▸ Signing with your Developer ID"
  else
    IDENTITY=$(awk -F'"' '/Apple Development/ {print $2; exit}' <<<"$IDS")
    echo "▸ Signing with your Apple Development certificate (no release key or Developer ID)"
  fi
fi
if [ -z "$IDENTITY" ]; then
  echo "✗ No code signing certificate" >&2
  exit 1
fi

codesign --force --options runtime "$STAMP" ${SIGN[@]+"${SIGN[@]}"} --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

CAN_NOTARIZE=0
if [ "$PUBLIC" = 1 ] && { [ -n "${NOTARY_PROFILE:-}" ] || [ -n "${NOTARY_KEY:-}" ]; }; then
  CAN_NOTARIZE=1
fi

notarize() {
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
  else
    xcrun notarytool submit "$1" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
  fi
}

rm -rf "$DIST"
mkdir -p "$DIST"
ZIP="$DIST/Grab-$VERSION.zip"
DMG="$DIST/Grab-$VERSION.dmg"

ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
if [ "$CAN_NOTARIZE" = 1 ]; then
  echo "▸ Notarizing the app (a few minutes)"
  notarize "$ZIP"
  xcrun stapler staple "$APP"
  rm "$ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
fi

echo "▸ Making the disk image"
scripts/make-dmg.sh "$APP" "$VERSION" "$DMG"
# Only a disk image that's going to be notarized gets signed: macOS checks a signed one
# the moment it opens, and stops it if it isn't notarized.
if [ "$CAN_NOTARIZE" = 1 ]; then
  codesign --force "$STAMP" ${SIGN[@]+"${SIGN[@]}"} --sign "$IDENTITY" "$DMG"
  echo "▸ Notarizing the disk image"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
fi

SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')
cat > "$DIST/grab.rb" <<EOF
cask "grab" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/$REPO/releases/download/v#{version}/Grab-#{version}.dmg"
  name "Grab"
  desc "Copy anything on your screen by pointing at it"
  homepage "https://github.com/$REPO"

  auto_updates true
  depends_on macos: :sonoma

  app "Grab.app"

  zap trash: [
    "~/Library/Application Support/Grab",
    "~/Library/Preferences/com.thirteen.Grab.plist",
  ]
end
EOF

echo
if [ "$CAN_NOTARIZE" = 1 ]; then
  spctl --assess --type execute "$APP" && echo "✓ Gatekeeper accepts the app"
  spctl --assess --type open --context context:primary-signature "$DMG" && echo "✓ Gatekeeper accepts the disk image"
  echo "✓ Ready: attach $DMG and $ZIP to a GitHub release tagged v$VERSION"
elif [ "$PUBLIC" = 1 ]; then
  echo "! Signed with Developer ID but not notarized: set NOTARY_PROFILE (see the top of this script)."
elif [ "$RELEASE_KEY" = 1 ]; then
  echo "✓ Ready: signed with the Grab Release key. It isn't notarized, so the first time a"
  echo "  downloaded copy opens, macOS asks to allow it (Privacy & Security → Open Anyway)."
else
  echo "! This build opens only on your own Macs. For everyone else you need a Developer ID"
  echo "  certificate (Apple Developer Program), then run this again with NOTARY_PROFILE set."
fi
ls -lh "$DIST"
