#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Checks that the Settings search index (Sources/Perekey/SettingsIndex.swift) and the panes agree:
# every row or group title written as a literal (PKRow(Text("…")), PKGroup(header: Text("…")),
# and the rows of GeneralPane's helpers) is in the index, every anchor of the index is on a row or
# group (`anchor:` or `.pkAnchor`), every anchor in the panes is in the index, and every index
# key is a title in the sources. A row that should stay out of the search gets `// search: skip`
# on its line or the line above.
#
#   scripts/check-settings-index.sh   check, exit 1 on a problem
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 scripts/check-settings-index.py "$@"
