#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Installs the bundle of scripts/bundle.sh into ~/Library/Input Methods and
# registers it with TIS. Replaces the files of an installed copy in place:
# macOS forgets an input source whose bundle directory goes away.
#   scripts/install.sh            install and register
#   scripts/install.sh --remove   disable, quit and delete
set -euo pipefail

cd "$(dirname "$0")/.."
DEST="$HOME/Library/Input Methods/PerekeyIMSpike.app"
if [[ "${1:-}" == --remove ]]; then
    [[ -d "$DEST" ]] && "$DEST/Contents/MacOS/PerekeyIMSpike" disable || true
    pkill -x PerekeyIMSpike || true
    rm -rf "$DEST"
    exit 0
fi
mkdir -p "$DEST"
rsync -a --delete .build/app/PerekeyIMSpike.app/ "$DEST/"
pkill -x PerekeyIMSpike || true
"$DEST/Contents/MacOS/PerekeyIMSpike" register
"$DEST/Contents/MacOS/PerekeyIMSpike" status
