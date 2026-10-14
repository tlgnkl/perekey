#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Checks a universal Perekey.app built the way a release is built: with
# PEREKEY_VOICE=1 (scripts/build-universal.sh). Used by release.yml, by the
# release build job of ci.yml and by the dry run in docs/release.md.
#
# Usage: scripts/check-release-app.sh [path/to/Perekey.app]
#        (default: .build/voice-universal/app/Perekey.app)
set -euo pipefail

cd "$(dirname "$0")/.."

APP="${1:-.build/voice-universal/app/Perekey.app}"
BIN="$APP/Contents/MacOS/Perekey"
PLIST="$APP/Contents/Info.plist"
[[ -x "$BIN" ]] || { echo "error: no app at $APP" >&2; exit 1; }

fail() { echo "error: $*" >&2; exit 1; }

# Both slices carry the speech engines: SwiftPM has no per-architecture
# dependencies. The Intel slice never starts them (VoiceHost.isSupported).
for arch in arm64 x86_64; do
    symbols="$(nm -arch "$arch" "$BIN")"
    for engine in FluidAudio WhisperKit; do
        grep -q "$engine" <<< "$symbols" || fail "the $arch slice has no $engine: this is not a voice build"
    done
done

# Both slices must start on the oldest macOS the app supports: a speech package
# that raised its deployment target would stop the app on macOS 14.
min="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")"
for arch in arm64 x86_64; do
    minos="$(vtool -arch "$arch" -show-build "$BIN" | awk '$1 == "minos" { print $2 }')"
    [[ "$minos" == "$min" ]] || fail "the $arch slice needs macOS $minos, but LSMinimumSystemVersion is $min"
done

# Without these two keys macOS ends the app at the first microphone or system
# audio request.
for key in NSMicrophoneUsageDescription NSAudioCaptureUsageDescription; do
    value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$PLIST" 2>/dev/null || true)"
    [[ -n "$value" ]] || fail "Info.plist has no $key"
done

# The audio input entitlement: the hardened runtime gives no microphone without it.
codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q 'com.apple.security.device.audio-input' \
    || fail "the signature has no com.apple.security.device.audio-input entitlement"

# A resource bundle at the root of the app (FluidAudio's TTS data) breaks the signature.
stray="$(find "$APP" -name '*.bundle' -not -path "$APP/Contents/Frameworks/*")"
[[ -z "$stray" ]] || fail "resource bundles in the app: $stray"

codesign --verify --deep --strict "$APP"
echo "ok: $APP ($(lipo -archs "$BIN"), macOS $min+, voice engines in both slices)"
