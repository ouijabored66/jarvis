#!/usr/bin/env bash
# Builds the iPhone app on your own machine and publishes it as a GitHub release with the .ipa attached.
#
#   scripts/release-ipa.sh              build with xtool, then release
#   scripts/release-ipa.sh path/to.ipa  release an IPA you already built
#   scripts/release-ipa.sh -y ...       skip the "this will be public" prompt
#
# Needs: xtool (only when building), and the GitHub CLI (`gh auth login` once).
# GitHub's own runners can't build this: xtool needs Apple's Xcode.xip, which can't be put on a public runner.
set -euo pipefail

APP="$(cd "$(dirname "$0")/.." && pwd)/ios/JarvisApp"
YES=0; IPA=""
for a in "$@"; do case "$a" in -y) YES=1 ;; *) IPA="$a" ;; esac; done

command -v gh >/dev/null || { echo "Install the GitHub CLI (gh) and run: gh auth login"; exit 1; }
VERSION="$(grep -A1 CFBundleShortVersionString "$APP/Info.plist" | sed -n 's/.*<string>\(.*\)<\/string>.*/\1/p')"
BUILD="$(grep -A1 '<key>CFBundleVersion' "$APP/Info.plist" | sed -n 's/.*<string>\(.*\)<\/string>.*/\1/p')"
BUNDLE="$(sed -n 's/^bundleID: *//p' "$APP/xtool.yml")"
[ -n "$VERSION" ] || { echo "Couldn't read the version from Info.plist"; exit 1; }
TAG="v$VERSION"

if [ -z "$IPA" ]; then
  command -v xtool >/dev/null || { echo "xtool isn't installed. Build the IPA yourself and pass its path."; exit 1; }
  stamp="$(mktemp)"
  (cd "$APP" && xtool dev build -c release --ipa)
  IPA="$(find "$APP" -name '*.ipa' -newer "$stamp" -print 2>/dev/null | head -n1)"
  rm -f "$stamp"
  [ -n "$IPA" ] || { echo "Build finished but no .ipa was found under $APP. Pass its path."; exit 1; }
fi
[ -f "$IPA" ] || { echo "No such file: $IPA"; exit 1; }

# Release assets get a clean, versioned name so Signulous / iLoader users see what they're getting.
OUT="$(mktemp -d)/Jarvis-$VERSION.ipa"
cp "$IPA" "$OUT"

echo "Version:   $VERSION (build $BUILD)   tag: $TAG"
echo "Bundle ID: ${BUNDLE:-unknown}"
echo "IPA:       $IPA  ->  $(basename "$OUT")"
echo "This repository is PUBLIC: anyone can download the release, and it shows the bundle ID above."
echo "The app contains no tokens (you enter those in Settings)."
if [ "$YES" -ne 1 ]; then
  read -r -p "Publish release $TAG? [y/N] " ans
  [ "$ans" = "y" ] || [ "$ans" = "Y" ] || { echo "Cancelled."; exit 1; }
fi

gh release create "$TAG" "$OUT" --title "Jarvis $VERSION" \
  --notes "iPhone / Apple Watch app $VERSION (build $BUILD). Install with Signulous or iLoader: see the README."
echo "Done. Release: $(gh release view "$TAG" --json url --jq .url)"
