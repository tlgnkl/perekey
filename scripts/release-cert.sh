#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Creates the self-signed code signing identity "Perekey Release", which signs
# releases while there is no Developer ID (docs/release.md, "Signing").
#
# Usage: scripts/release-cert.sh <directory>
#
# Writes four files into <directory>, a new or empty directory outside the
# repository:
#   perekey-release.p12           the key and the certificate, encrypted
#   perekey-release.p12.password  the random password of the .p12
#   perekey-release.p12.base64    the .p12 as the GitHub secret takes it
#   perekey-release.cer           the certificate alone; it is public
# Nothing goes to GitHub: the owner adds the secrets by hand.
#
# Why: macOS ties Accessibility, Input Monitoring and microphone grants to the
# designated requirement of the code signature. An ad hoc signature changes on
# every build, so after each update macOS forgets the grants. Every build
# signed with this identity has the same requirement,
#   identifier "app.perekey.Perekey" and certificate leaf = H"<SHA-1 of the certificate>"
# so the grants survive updates. Gatekeeper still blocks the first launch: only
# Apple's certificates count for it.
#
# Create the identity once. A new one changes the requirement, and every user
# grants the permissions once more. Nobody can revoke it: anyone with the key
# can sign a program that macOS treats as Perekey, with all of Perekey's
# permissions. So the key lives in two places only, the GitHub environment
# "release" and an offline copy, and never in git.
set -euo pipefail

NAME="Perekey Release"
DAYS=36500 # 100 years: the certificate must outlive every installed copy

dir="${1:?usage: scripts/release-cert.sh <directory>}"
if [[ -e "$dir" && -n "$(ls -A "$dir")" ]]; then
    echo "error: $dir is not empty; the script never overwrites a key" >&2
    exit 1
fi
mkdir -p "$dir"
if git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "error: $dir is inside a git work tree; keep the key out of every repository" >&2
    rmdir "$dir" 2>/dev/null || true
    exit 1
fi
umask 077

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

openssl req -x509 -newkey rsa:3072 -nodes -days "$DAYS" -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null

password="$(openssl rand -base64 32)"
printf '%s' "$password" > "$tmp/password"
# macOS `security import` does not read the OpenSSL 3 default PKCS#12 encryption.
openssl pkcs12 -export -legacy -name "$NAME" -passout "file:$tmp/password" \
    -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -out "$dir/perekey-release.p12"
mv "$tmp/password" "$dir/perekey-release.p12.password"
base64 -i "$dir/perekey-release.p12" | tr -d '\n' > "$dir/perekey-release.p12.base64"
openssl x509 -in "$tmp/cert.pem" -outform der -out "$dir/perekey-release.cer"
chmod 644 "$dir/perekey-release.cer"

hash="$(openssl x509 -in "$tmp/cert.pem" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d : | tr 'A-F' 'a-f')"
until="$(openssl x509 -in "$tmp/cert.pem" -noout -enddate | cut -d= -f2)"

cat <<EOF
Created "$NAME" in $dir (valid until $until).
Designated requirement of every build it signs:
  identifier "app.perekey.Perekey" and certificate leaf = H"$hash"

Next, by hand:
1. GitHub → Settings → Environments → "release" (required reviewer: you).
   Add two environment secrets there, not repository secrets:
     PEREKEY_RELEASE_CERT_P12       the contents of perekey-release.p12.base64
     PEREKEY_RELEASE_CERT_PASSWORD  the contents of perekey-release.p12.password
2. Copy perekey-release.p12 and perekey-release.p12.password to offline
   storage (an encrypted USB drive or a password manager). Losing the key costs
   every user their permissions once more; a leak cannot be undone.
3. Delete $dir from this Mac.
EOF
