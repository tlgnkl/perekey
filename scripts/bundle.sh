#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds Perekey.app from the SwiftPM product.
#
# Environment:
#   CONFIG         debug | release (default: release)
#   PEREKEY_VOICE  1 builds voice input in (Package.swift)
#   SCRATCH_PATH   SwiftPM build directory (default: .build, .build/voice with PEREKEY_VOICE=1)
#   OUT            where Perekey.app goes (default: $SCRATCH_PATH/app)
#   VERSION        CFBundleShortVersionString (default: 0.0.0)
#   BUILD          CFBundleVersion (default: 0)
#   SIGN_IDENTITY  codesign identity; "-" signs ad hoc
#                  (default: "Perekey Dev" from scripts/dev-cert.sh if present, else -)
#   SIGN_KEYCHAIN  the keychain that holds SIGN_IDENTITY, e.g. the one with
#                  "Perekey Release" (docs/release.md); unlock it first
#   PEREKEY_BINARY a prebuilt executable (a universal one from build-universal.sh)
#                  to use instead of building the host product
#   SPARKLE_FRAMEWORK  Sparkle.framework to embed (default: next to the
#                  executable, where SwiftPM puts it)
#   SPARKLE_PUBLIC_ED_KEY  replaces SUPublicEDKey of Support/Info.plist
#   PEREKEY_MODEL  directory of the language model files (default:
#                  $SCRATCH_PATH/model, built by scripts/build-model.sh if missing)
#   PEREKEY_LANGUAGES  the model files to ship (default: the languages of
#                  data/languages, the one list the app enables by)
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
if [[ "${PEREKEY_VOICE:-}" == 1 ]]; then
    SCRATCH_PATH="${SCRATCH_PATH:-.build/voice}"
else
    SCRATCH_PATH="${SCRATCH_PATH:-.build}"
fi
OUT="${OUT:-$SCRATCH_PATH/app}"
VERSION="${VERSION:-0.0.0}"
BUILD="${BUILD:-0}"
DEV_KEYCHAIN="$HOME/Library/Keychains/perekey-dev.keychain-db"
SIGN_ARGS=()
if [[ -n "${SIGN_KEYCHAIN:-}" ]]; then
    # Without an identity the build would quietly fall back to ad hoc.
    [[ -n "${SIGN_IDENTITY:-}" ]] || { echo "error: SIGN_KEYCHAIN needs SIGN_IDENTITY" >&2; exit 1; }
    SIGN_ARGS=(--keychain "$SIGN_KEYCHAIN")
elif [[ -z "${SIGN_IDENTITY:-}" && -f "$DEV_KEYCHAIN" ]]; then
    security unlock-keychain -p perekey-dev "$DEV_KEYCHAIN"
    SIGN_IDENTITY="Perekey Dev"
    SIGN_ARGS=(--keychain "$DEV_KEYCHAIN")
fi
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

if [[ -n "${PEREKEY_BINARY:-}" ]]; then
    BINARY="$PEREKEY_BINARY"
else
    swift build -c "$CONFIG" --scratch-path "$SCRATCH_PATH" --product Perekey
    BINARY="$(swift build -c "$CONFIG" --scratch-path "$SCRATCH_PATH" --show-bin-path)/Perekey"
fi
SPARKLE_FRAMEWORK="${SPARKLE_FRAMEWORK:-$(dirname "$BINARY")/Sparkle.framework}"
[[ -d "$SPARKLE_FRAMEWORK" ]] || { echo "error: no Sparkle.framework at $SPARKLE_FRAMEWORK" >&2; exit 1; }

APP="$OUT/Perekey.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Perekey"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Support/Info.plist > "$APP/Contents/Info.plist"
# Overrides the public key of Support/Info.plist, e.g. to test scripts/appcast.sh with a throwaway key.
if [[ -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]]; then
    plutil -replace SUPublicEDKey -string "$SPARKLE_PUBLIC_ED_KEY" "$APP/Contents/Info.plist"
fi
# Resources load from Bundle.main; Bundle.module of an executable target would break the signature.
for lproj in Support/*.lproj; do
    cp -R "$lproj" "$APP/Contents/Resources/"
done
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Support/Perekey.sdef "$APP/Contents/Resources/Perekey.sdef" # AppleScript dictionary (Info.plist: OSAScriptingDefinition)

# The language model, a file per language: PEREKEY_MODEL, or the build of
# scripts/build-model.sh, made here if missing (needs the data cache of
# scripts/fetch-data.sh lexicon). The app maps the files of the installed
# layouts' languages from Bundle.main: Contents/Resources/<language>.pklm.
# Each file must match its hash in data/model.sha256: a stale local build
# would otherwise ship silently.
MODEL="${PEREKEY_MODEL:-$SCRATCH_PATH/model}"
LANGUAGES="${PEREKEY_LANGUAGES:-$(grep -v '^#' data/languages | tr '\n' ' ')}"
if [[ -e "$MODEL" && ! -d "$MODEL" ]]; then
    echo "error: PEREKEY_MODEL=$MODEL is a file; it names the directory of <language>.pklm now" >&2
    echo "       (the single perekey.model is gone, scripts/build-model.sh writes ru.pklm, en.pklm, uk.pklm, be.pklm)" >&2
    exit 1
fi
for language in $LANGUAGES; do
    if [[ ! -f "$MODEL/$language.pklm" ]]; then
        scripts/build-model.sh --out "$MODEL" >/dev/null
        break
    fi
done
for language in $LANGUAGES; do
    want="$(awk -v name="$language.pklm" '$2 == name { print $1 }' data/model.sha256)"
    have="$(shasum -a 256 "$MODEL/$language.pklm" | cut -d' ' -f1)"
    if [[ -z "$want" || "$have" != "$want" ]]; then
        echo "error: $MODEL/$language.pklm does not match data/model.sha256 (${want:-no entry})." >&2
        echo "       Rebuild it: scripts/build-model.sh --out $MODEL" >&2
        exit 1
    fi
    cp "$MODEL/$language.pklm" "$APP/Contents/Resources/$language.pklm"
done

# Sparkle 2 (docs/release.md). The executable links @rpath/Sparkle.framework.
# SwiftPM leaves rpaths into the build directory; the bundle needs only
# Contents/Frameworks. Perekey is not sandboxed, so Sparkle's XPC services
# (needed only by sandboxed apps) are left out.
FRAMEWORKS="$APP/Contents/Frameworks"
mkdir -p "$FRAMEWORKS"
ditto "$SPARKLE_FRAMEWORK" "$FRAMEWORKS/Sparkle.framework"
rm -rf "$FRAMEWORKS/Sparkle.framework/Versions/B/XPCServices" "$FRAMEWORKS/Sparkle.framework/XPCServices"
EXE="$APP/Contents/MacOS/Perekey"
# install_name_tool warns that it invalidates the linker signature; the app is signed below.
otool -l "$EXE" | awk '/cmd LC_RPATH/ { getline; getline; print $2 }' | sort -u | while read -r rpath; do
    [[ "$rpath" == /usr/lib/swift ]] || install_name_tool -delete_rpath "$rpath" "$EXE" 2>/dev/null
done
install_name_tool -add_rpath @executable_path/../Frameworks "$EXE" 2>/dev/null

# Resource bundles of packages stay out: SwiftPM leaves them next to the
# executable, and a bundle at the root of the app breaks its signature. The one
# with PEREKEY_VOICE=1, FluidAudio_FluidAudio.bundle, holds TTS data only;
# FluidAudio's speech recognition, VAD and diarization do not read Bundle.module.
stray="$(find "$APP" -name '*.bundle' -not -path "$FRAMEWORKS/*")"
if [[ -n "$stray" ]]; then
    echo "error: resource bundles in the app would break its signature:" >&2
    echo "$stray" >&2
    exit 1
fi

# Sign inside out with one identity: Sparkle's helpers, the framework, the app.
# Every build gets Support/Perekey.entitlements: the hardened runtime gives a
# signature without the audio input entitlement no microphone. Library
# validation lets a hardened app load only libraries of its own team. The
# self-signed "Perekey Dev" and "Perekey Release" and ad hoc signatures have no
# team, so the file turns the check off; Developer ID builds have one and keep
# it on.
SIGN=(codesign --force --options runtime ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} --sign "$SIGN_IDENTITY")
ENTITLEMENTS=Support/Perekey.entitlements
if [[ "$SIGN_IDENTITY" == "Developer ID Application"* ]]; then
    SIGN+=(--timestamp) # notarization needs a secure timestamp
    ENTITLEMENTS="$(mktemp -t perekey-entitlements)"
    trap 'rm -f "$ENTITLEMENTS"' EXIT
    plutil -remove 'com\.apple\.security\.cs\.disable-library-validation' -o "$ENTITLEMENTS" Support/Perekey.entitlements
else
    SIGN+=(--timestamp=none)
fi
SPARKLE="$FRAMEWORKS/Sparkle.framework/Versions/B"
"${SIGN[@]}" "$SPARKLE/Autoupdate"
"${SIGN[@]}" "$SPARKLE/Updater.app"
"${SIGN[@]}" "$FRAMEWORKS/Sparkle.framework"
"${SIGN[@]}" --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict "$APP"
echo "$APP"
