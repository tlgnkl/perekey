#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Regenerates Support/AppIcon.icns from scripts/make-icon.swift. The .icns is
# committed; run this only after changing the drawing.
#
#   scripts/make-icon.sh [iconset dir]   (default: a temp dir, PNGs kept for a look)
set -euo pipefail
cd "$(dirname "$0")/.."
SET="${1:-${TMPDIR:-/tmp}/perekey-icon/AppIcon.iconset}"
rm -rf "$SET"
swift scripts/make-icon.swift "$SET"
iconutil --convert icns --output Support/AppIcon.icns "$SET"
echo "Support/AppIcon.icns (PNGs in $SET)"
