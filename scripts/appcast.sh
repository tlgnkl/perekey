#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Writes the Sparkle appcast for one release: an EdDSA-signed entry for the DMG,
# with the download address on GitHub Releases. release.yml runs it; the result
# goes to the release and then to GitHub Pages as appcast.xml (SUFeedURL).
# docs/release.md explains the key and the whole flow.
#
# Usage: scripts/appcast.sh <Perekey-VERSION.dmg>
# Environment:
#   SPARKLE_ED_PRIVATE_KEY  the private EdDSA key (base64, as `generate_keys -x` writes it). Required.
#   TAG            release tag, e.g. v1.2.0 (default: v + CFBundleShortVersionString of the DMG's app)
#   REPO           GitHub owner/name (default: tlgnkl/perekey)
#   APPCAST_DIR    output directory (default: .build/appcast)
#   SPARKLE_BIN    directory with Sparkle's generate_appcast (default: downloaded,
#                  the same zip and checksum as the binaryTarget in Package.swift)
set -euo pipefail

cd "$(dirname "$0")/.."

DMG="${1:?usage: scripts/appcast.sh <Perekey-VERSION.dmg>}"
[[ -f "$DMG" ]] || { echo "error: no DMG at $DMG" >&2; exit 1; }
[[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]] || { echo "error: SPARKLE_ED_PRIVATE_KEY is not set" >&2; exit 1; }
REPO="${REPO:-tlgnkl/perekey}"
APPCAST_DIR="${APPCAST_DIR:-.build/appcast}"

work="$(mktemp -d "${TMPDIR:-/tmp}/perekey-appcast.XXXXXX")"
trap 'hdiutil detach -quiet "$work/mnt" 2>/dev/null || true; rm -rf "$work"' EXIT

# The app inside must carry a real public key, or no installed copy can verify the update.
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$work/mnt" "$DMG"
plist="$work/mnt/Perekey.app/Contents/Info.plist"
public_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$plist")"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
hdiutil detach -quiet "$work/mnt"
if [[ "$(printf '%s' "$public_key" | base64 -d 2>/dev/null | wc -c | tr -d ' ')" != 32 ]]; then
    echo "error: SUPublicEDKey in the DMG's app is not a key ($public_key); see docs/release.md" >&2
    exit 1
fi
TAG="${TAG:-v$version}"

if [[ -z "${SPARKLE_BIN:-}" ]]; then
    url="$(grep -o 'https://github.com/sparkle-project/Sparkle/releases/download/[^"]*' Package.swift)"
    sum="$(awk -F'"' '/checksum:/ { print $2 }' Package.swift)"
    curl -fsSL -o "$work/sparkle.zip" "$url"
    echo "$sum  $work/sparkle.zip" | shasum -a 256 -c - >/dev/null
    mkdir "$work/sparkle"
    unzip -q "$work/sparkle.zip" -d "$work/sparkle"
    SPARKLE_BIN="$work/sparkle/bin"
fi

# One entry per appcast: Sparkle needs only the newest version, and a fresh
# file keeps old entries (and their download addresses) out of the feed.
rm -rf "$APPCAST_DIR"
mkdir -p "$APPCAST_DIR/archives"
cp "$DMG" "$APPCAST_DIR/archives/"
out="$(cd "$APPCAST_DIR" && pwd)/appcast.xml"
printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$SPARKLE_BIN/generate_appcast" \
    --ed-key-file - \
    --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
    --full-release-notes-url "https://github.com/$REPO/releases/tag/$TAG" \
    --maximum-deltas 0 \
    -o "$out" \
    "$APPCAST_DIR/archives"
rm -rf "$APPCAST_DIR/archives"
echo "$APPCAST_DIR/appcast.xml"
