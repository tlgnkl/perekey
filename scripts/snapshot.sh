#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Renders every UI surface to PNG (Sources/Perekey/DebugSnapshot.swift), in
# English and in Russian, light and dark, without a screen.
#
#   scripts/snapshot.sh <dir> [language...]     (default: en ru)
#
# The debug executable has no Bundle with the .lproj folders, so it would draw
# the English keys only. This wraps it in a bare Perekey.app next to <dir>
# (ad hoc signed, never launched as the app: it renders and exits) and passes
# -AppleLanguages. Pictures land in <dir>/<language>/. Heavy: run it through
# ~/.claude/bin/heavy-gate.
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="${1:?usage: scripts/snapshot.sh <dir> [language...]}"
shift || true
LANGUAGES=("$@")
[[ ${#LANGUAGES[@]} -gt 0 ]] || LANGUAGES=(en ru)

swift build --product Perekey >/dev/null
BIN_DIR="$(swift build --show-bin-path)"
APP="$OUT/.snapshot-app/Perekey.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Perekey" "$APP/Contents/MacOS/Perekey"
sed -e "s/__VERSION__/0.0.0/" -e "s/__BUILD__/0/" Support/Info.plist > "$APP/Contents/Info.plist"
for lproj in Support/*.lproj; do cp -R "$lproj" "$APP/Contents/Resources/"; done
cp Support/AppIcon.icns "$APP/Contents/Resources/"
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Perekey" 2>/dev/null || true
codesign --force --deep --sign - "$APP" >/dev/null 2>&1

for language in "${LANGUAGES[@]}"; do
    mkdir -p "$OUT/$language"
    PEREKEY_SNAPSHOT="$OUT/$language" "$APP/Contents/MacOS/Perekey" -AppleLanguages "($language)" -AppleLocale "$language"
    echo "$OUT/$language: $(find "$OUT/$language" -name '*.png' | wc -l | tr -d ' ') pictures"
done
rm -rf "$OUT/.snapshot-app"
