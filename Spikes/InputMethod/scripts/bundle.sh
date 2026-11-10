#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds PerekeyIMSpike.app: the input method bundle, no Xcode.
#
# Environment:
#   PEREKEY_MODEL  directory with en.pklm and ru.pklm (checked against data/model.sha256)
#   OUT            where the bundle goes (default: .build/app)
#   SIGN_IDENTITY  codesign identity (default: "Perekey Dev" if its keychain exists, else ad hoc)
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(cd ../.. && pwd)"
OUT="${OUT:-.build/app}"
MODEL="${PEREKEY_MODEL:?PEREKEY_MODEL must name the directory of en.pklm and ru.pklm}"

swift build -c release --product PerekeyIMSpike
BIN="$(swift build -c release --show-bin-path)/PerekeyIMSpike"

APP="$OUT/PerekeyIMSpike.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PerekeyIMSpike"
sed "s/__BUILD__/$(date +%s)/" Support/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
sips -s format tiff -z 16 16 "$ROOT/Support/AppIcon.icns" --out "$APP/Contents/Resources/Spike.tiff" >/dev/null
for language in en ru; do
    want="$(awk -v name="$language.pklm" '$2 == name { print $1 }' "$ROOT/data/model.sha256")"
    have="$(shasum -a 256 "$MODEL/$language.pklm" | cut -d' ' -f1)"
    [[ "$have" == "$want" ]] || { echo "error: $MODEL/$language.pklm does not match data/model.sha256" >&2; exit 1; }
    cp "$MODEL/$language.pklm" "$APP/Contents/Resources/"
done

DEV_KEYCHAIN="$HOME/Library/Keychains/perekey-dev.keychain-db"
SIGN=(codesign --force --options runtime --timestamp=none)
if [[ -z "${SIGN_IDENTITY:-}" && -f "$DEV_KEYCHAIN" ]]; then
    security unlock-keychain -p perekey-dev "$DEV_KEYCHAIN"
    SIGN+=(--keychain "$DEV_KEYCHAIN" --sign "Perekey Dev")
else
    SIGN+=(--sign "${SIGN_IDENTITY:--}")
fi
"${SIGN[@]}" "$APP"
codesign --verify --strict "$APP"
echo "$APP"
