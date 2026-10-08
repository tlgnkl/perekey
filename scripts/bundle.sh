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
#   SIGN_IDENTITY  codesign identity; "-" signs ad hoc
#                  (default: "Perekey Dev" from scripts/dev-cert.sh if present, else -)
#   PEREKEY_BINARY a prebuilt executable (a universal one from build-universal.sh)
#                  to use instead of building the host product
#   SPARKLE_FRAMEWORK  Sparkle.framework to embed (default: next to the
#                  executable, where SwiftPM puts it)
#   SPARKLE_PUBLIC_ED_KEY  replaces SUPublicEDKey of Support/Info.plist
#   PEREKEY_MODEL  directory of the language model files (default:
#                  $SCRATCH_PATH/model, built by scripts/build-model.sh if missing)
#   PEREKEY_LANGUAGES  the model files to ship (default: "ru en"; uk.pklm is
#                  built and checked, but the app switches only ru and en yet)
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
SCRATCH_PATH="${SCRATCH_PATH:-.build}"
OUT="${OUT:-$SCRATCH_PATH/app}"
VERSION="${VERSION:-0.0.0}"
BUILD="${BUILD:-0}"
DEV_KEYCHAIN="$HOME/Library/Keychains/perekey-dev.keychain-db"
SIGN_ARGS=()
if [[ -z "${SIGN_IDENTITY:-}" && -f "$DEV_KEYCHAIN" ]]; then
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
LANGUAGES="${PEREKEY_LANGUAGES:-ru en}"
if [[ -e "$MODEL" && ! -d "$MODEL" ]]; then
    echo "error: PEREKEY_MODEL=$MODEL is a file; it names the directory of <language>.pklm now" >&2
    echo "       (the single perekey.model is gone, scripts/build-model.sh writes ru.pklm, en.pklm, uk.pklm)" >&2
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

# Sign inside out with one identity: Sparkle's helpers, the framework, the app.
# Library validation lets a hardened app load only libraries of its own team.
# The local "Perekey Dev" and ad hoc signatures have no team, so those builds
# get an entitlement that turns the check off; Developer ID builds do not.
SIGN=(codesign --force --options runtime ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} --sign "$SIGN_IDENTITY")
APP_ENTITLEMENTS=()
if [[ "$SIGN_IDENTITY" == "Developer ID Application"* ]]; then
    SIGN+=(--timestamp) # notarization needs a secure timestamp
else
    SIGN+=(--timestamp=none)
    APP_ENTITLEMENTS=(--entitlements Support/Dev.entitlements)
fi
SPARKLE="$FRAMEWORKS/Sparkle.framework/Versions/B"
"${SIGN[@]}" "$SPARKLE/Autoupdate"
"${SIGN[@]}" "$SPARKLE/Updater.app"
"${SIGN[@]}" "$FRAMEWORKS/Sparkle.framework"
"${SIGN[@]}" ${APP_ENTITLEMENTS[@]+"${APP_ENTITLEMENTS[@]}"} "$APP"
codesign --verify --deep --strict "$APP"
echo "$APP"
