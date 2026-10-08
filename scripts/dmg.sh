#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Packs Perekey.app into a compressed, read-only DMG with an /Applications
# link, using only hdiutil. Writes Perekey-<version>.dmg and its .sha256.
#
# Usage: scripts/dmg.sh [path/to/Perekey.app]
# Environment:
#   VERSION        goes into the file name (default: 0.0.0)
#   DMG_DIR        output directory (default: .build/dmg)
#   SIGN_IDENTITY  if set and not "-", the DMG itself is signed with it
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.0.0}"
DMG_DIR="${DMG_DIR:-.build/dmg}"
APP="${1:-.build/universal/app/Perekey.app}"
[[ -d "$APP" ]] || { echo "error: no app at $APP (run scripts/build-universal.sh)" >&2; exit 1; }

DMG="$DMG_DIR/Perekey-$VERSION.dmg"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/perekey-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$DMG_DIR"
rm -f "$DMG" "$DMG.sha256"
# ditto keeps the code signature, symlinks and extended attributes intact.
ditto "$APP" "$STAGE/Perekey.app"
ln -s /Applications "$STAGE/Applications"

hdiutil create -quiet -volname "Perekey $VERSION" -srcfolder "$STAGE" \
    -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG"

if [[ -n "${SIGN_IDENTITY:-}" && "$SIGN_IDENTITY" != "-" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" "$DMG"
fi

hdiutil verify -quiet "$DMG"
(cd "$DMG_DIR" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "$DMG" >&2
cat "$DMG.sha256" >&2
echo "$DMG"
