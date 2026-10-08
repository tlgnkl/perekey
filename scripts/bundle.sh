#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds Perekey.app from the SwiftPM product.
#
# Environment:
#   CONFIG         debug | release (default: release)
#   SCRATCH_PATH   SwiftPM build directory (default: .build)
#   OUT            where Perekey.app goes (default: $SCRATCH_PATH/app)
#   VERSION        CFBundleShortVersionString (default: 0.0.0)
#   BUILD          CFBundleVersion (default: 0)
#   SIGN_IDENTITY  codesign identity; "-" signs ad hoc (default: -)
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
SCRATCH_PATH="${SCRATCH_PATH:-.build}"
OUT="${OUT:-$SCRATCH_PATH/app}"
VERSION="${VERSION:-0.0.0}"
BUILD="${BUILD:-0}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

swift build -c "$CONFIG" --scratch-path "$SCRATCH_PATH" --product Perekey
BIN_DIR="$(swift build -c "$CONFIG" --scratch-path "$SCRATCH_PATH" --show-bin-path)"

APP="$OUT/Perekey.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Perekey" "$APP/Contents/MacOS/Perekey"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Support/Info.plist > "$APP/Contents/Info.plist"

codesign --force --options runtime --timestamp=none --sign "$SIGN_IDENTITY" "$APP"
echo "$APP"
