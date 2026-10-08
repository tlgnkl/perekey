#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds a universal (arm64 + x86_64) Perekey.app without Xcode.
#
# `swift build --arch` needs XCBuild, which Command Line Tools lack. So this
# builds each triple into its own scratch path, joins the executables with
# `lipo -create`, and lets scripts/bundle.sh assemble and sign the bundle
# (PEREKEY_BINARY makes bundle.sh skip its own build).
#
# Environment (same meaning as in bundle.sh):
#   CONFIG         debug | release (default: release)
#   SCRATCH_PATH   build directory (default: .build/universal)
#   OUT            where Perekey.app goes (default: $SCRATCH_PATH/app)
#   VERSION, BUILD, SIGN_IDENTITY, PEREKEY_MODEL
#   MIN_MACOS      deployment target (default: 14.0)
set -euo pipefail

cd "$(dirname "$0")/.."

export CONFIG="${CONFIG:-release}"
export SCRATCH_PATH="${SCRATCH_PATH:-.build/universal}"
export OUT="${OUT:-$SCRATCH_PATH/app}"
MIN_MACOS="${MIN_MACOS:-14.0}"

slices=()
for arch in arm64 x86_64; do
    scratch="$SCRATCH_PATH/$arch"
    triple="$arch-apple-macosx$MIN_MACOS"
    swift build -c "$CONFIG" --scratch-path "$scratch" --triple "$triple" --product Perekey >&2
    bin_dir="$(swift build -c "$CONFIG" --scratch-path "$scratch" --triple "$triple" --show-bin-path)"
    slices+=("$bin_dir/Perekey")
done

mkdir -p "$SCRATCH_PATH/lipo"
lipo -create "${slices[@]}" -output "$SCRATCH_PATH/lipo/Perekey"
# Sparkle's XCFramework is already universal: any slice's copy will do.
# bundle.sh finds it next to PEREKEY_BINARY.
rm -rf "$SCRATCH_PATH/lipo/Sparkle.framework"
ditto "$bin_dir/Sparkle.framework" "$SCRATCH_PATH/lipo/Sparkle.framework"

# The model is architecture-independent; build it once, next to the slices.
export PEREKEY_MODEL="${PEREKEY_MODEL:-$SCRATCH_PATH/model}"
PEREKEY_BINARY="$SCRATCH_PATH/lipo/Perekey" scripts/bundle.sh >/dev/null

APP="$OUT/Perekey.app"
archs="$(lipo -archs "$APP/Contents/MacOS/Perekey")"
if [[ "$archs" != "arm64 x86_64" && "$archs" != "x86_64 arm64" ]]; then
    echo "error: expected arm64 and x86_64, got: $archs" >&2
    exit 1
fi
codesign --verify --strict --verbose=2 "$APP" >&2
echo "archs: $archs" >&2
echo "$APP"
