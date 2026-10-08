#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Creates a self-signed code signing identity "Perekey Dev" in its own keychain,
# ~/Library/Keychains/perekey-dev.keychain-db. scripts/bundle.sh picks it up
# automatically.
#
# Why: macOS ties Accessibility and Input Monitoring grants to the code
# signature. An ad-hoc signature changes on every build, so macOS forgets the
# grant after each rebuild. A stable local identity keeps it.
#
# The keychain has a fixed, public password: it holds only this throwaway
# development key, and a separate keychain lets codesign run without GUI
# prompts. Never put a real Developer ID key in it.
set -euo pipefail

NAME="Perekey Dev"
KEYCHAIN="$HOME/Library/Keychains/perekey-dev.keychain-db"
PASSWORD="perekey-dev"

if [[ -f "$KEYCHAIN" ]]; then
    echo "$KEYCHAIN already exists."
    exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null

# macOS `security import` does not read the OpenSSL 3 default PKCS#12 encryption.
openssl pkcs12 -export -legacy -name "$NAME" -passout pass:perekey \
    -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -out "$tmp/identity.p12"

security create-keychain -p "$PASSWORD" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN" # no auto-lock timeout
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
security import "$tmp/identity.p12" -k "$KEYCHAIN" -P perekey -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null

echo "Created \"$NAME\" in $KEYCHAIN."
echo "Rebuild with scripts/bundle.sh and grant permissions once more."
