#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Prints the GitHub release notes for one version: its section of
# CHANGELOG.md, then how to download and install it. Fails if CHANGELOG.md has
# no section for the version, so a release never goes out without notes.
#
# Usage: scripts/release-notes.sh <version>      (e.g. 0.1.0, no "v")
# Environment:
#   SIGNED   "true" if the DMG is Developer ID signed and notarized; otherwise
#            the notes explain how to open an unsigned build
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${1:?usage: scripts/release-notes.sh <version>}"
REPO="https://github.com/tlgnkl/perekey"

# The section runs from "## [<version>]" to the next "## [" or the link list.
section="$(awk -v v="$VERSION" '
    index($0, "## [" v "]") == 1 { on = 1; next }
    on && (/^## \[/ || /^\[[^]]+\]: /) { exit }
    on { print }
' CHANGELOG.md)"
# Trim blank lines at both ends.
section="$(printf '%s\n' "$section" | sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}')"
if [[ -z "$section" ]]; then
    echo "error: CHANGELOG.md has no \"## [$VERSION]\" section" >&2
    exit 1
fi

printf '%s\n\n' "$section"
cat <<EOF
## Install

**[Download Perekey-$VERSION.dmg]($REPO/releases/download/v$VERSION/Perekey-$VERSION.dmg)**
· macOS 14 or later · Apple Silicon and Intel

1. Open the DMG and drag Perekey to Applications.
2. Start Perekey from Applications.
3. Allow Accessibility and Input Monitoring when Perekey asks: without them it
   cannot see keystrokes or replace a word.
EOF

if [[ "${SIGNED:-false}" != "true" ]]; then
    cat <<'EOF'

> [!IMPORTANT]
> This build is not signed by Apple yet, so macOS blocks the first launch.
> - **macOS 15 and later:** open Perekey once, close the warning, then go to
>   System Settings → Privacy & Security and click **Open Anyway**.
> - **macOS 14:** Control-click Perekey in Applications, choose **Open**, then
>   **Open** again.
EOF
fi

cat <<EOF

Check the download: \`shasum -a 256 -c Perekey-$VERSION.dmg.sha256\` in the
folder with both files. All changes: [CHANGELOG.md]($REPO/blob/main/CHANGELOG.md).
EOF
