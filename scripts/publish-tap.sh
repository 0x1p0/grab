#!/bin/bash
# Publishes the Homebrew cask for a release that's already on GitHub, so
#   brew install --cask 0x1p0/tap/grab
# installs it.
#
#   scripts/release.sh 1.2.0
#   gh release create v1.2.0 dist/Grab-1.2.0.dmg dist/Grab-1.2.0.zip
#   scripts/publish-tap.sh 1.2.0
#
# The cask goes to github.com/0x1p0/homebrew-tap (Casks/grab.rb). While the grab repo
# is private, the cask downloads with your GitHub login (HOMEBREW_GITHUB_API_TOKEN, or
# the GitHub CLI's), so only people with access to the repo can install it. Once the
# repo is public it becomes a plain download, and Grab's own updater takes over updates.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  echo "usage: scripts/publish-tap.sh <version>   (like 1.2.0)" >&2
  exit 1
fi
REPO="0x1p0/grab"
TAP="0x1p0/homebrew-tap"
TAG="v$VERSION"
DMG="Grab-$VERSION.dmg"

ASSET=$(gh api "repos/$REPO/releases/tags/$TAG" --jq ".assets[] | select(.name == \"$DMG\") | .id")
if [ -z "$ASSET" ]; then
  echo "✗ Release $TAG has no $DMG" >&2
  exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Checksum what's actually published, not a local build.
echo "▸ Downloading $DMG from the $TAG release"
gh release download "$TAG" --repo "$REPO" --pattern "$DMG" --dir "$WORK"
SHA=$(shasum -a 256 "$WORK/$DMG" | awk '{print $1}')
VISIBILITY=$(gh repo view "$REPO" --json visibility --jq .visibility)

if [ "$VISIBILITY" = "PUBLIC" ]; then
  DOWNLOAD=$(cat <<EOF
  url "https://github.com/$REPO/releases/download/v#{version}/Grab-#{version}.dmg"
EOF
)
  UPDATES='  auto_updates true
'
  CAVEATS=""
else
  DOWNLOAD=$(cat <<EOF
  # Grab's releases are private for now, so the download signs in with your GitHub
  # account: HOMEBREW_GITHUB_API_TOKEN if it's set, otherwise the GitHub CLI's login.
  token = ENV.fetch("HOMEBREW_GITHUB_API_TOKEN") do
    gh = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].find { |path| File.executable?(path) }
    gh ? \`#{gh} auth token 2>/dev/null\`.strip : ""
  end

  url "https://api.github.com/repos/$REPO/releases/assets/$ASSET",
      header: ["Accept: application/octet-stream", "Authorization: Bearer #{token}"]
EOF
)
  # Grab's updater can't see private releases; let `brew upgrade` handle them.
  UPDATES=""
  CAVEATS=$(cat <<'EOF'

  caveats <<~EOS
    Grab isn't notarized yet, so macOS stops it the first time it opens.
    Open System Settings → Privacy & Security and click "Open Anyway" for Grab.
  EOS
EOF
)
fi

echo "▸ Updating $TAP"
gh repo clone "$TAP" "$WORK/tap" -- --quiet
mkdir -p "$WORK/tap/Casks"
cat > "$WORK/tap/Casks/grab.rb" <<EOF
cask "grab" do
  version "$VERSION"
  sha256 "$SHA"

$DOWNLOAD
  name "Grab"
  desc "Copy anything on your screen by pointing at it"
  homepage "https://github.com/$REPO"

$UPDATES  depends_on macos: ">= :sonoma"

  app "Grab.app"

  zap trash: [
    "~/Library/Application Support/Grab",
    "~/Library/Preferences/com.thirteen.Grab.plist",
  ]$CAVEATS
end
EOF

# Commit as whoever commits to the grab repo.
NAME=$(git config user.name || echo 0x1p0)
EMAIL=$(git config user.email || echo 264620981+0x1p0@users.noreply.github.com)
cd "$WORK/tap"
git config user.name "$NAME"
git config user.email "$EMAIL"
if git diff --quiet -- Casks/grab.rb 2>/dev/null && git ls-files --error-unmatch Casks/grab.rb >/dev/null 2>&1; then
  echo "✓ The cask is already at $VERSION"
  exit 0
fi
git add Casks/grab.rb
git commit --quiet -m "Grab $VERSION"
git push --quiet origin HEAD
echo "✓ brew install --cask 0x1p0/tap/grab now installs Grab $VERSION"
