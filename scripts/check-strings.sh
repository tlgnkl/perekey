#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Checks that every localizable string literal in Sources/Perekey has a key in
# Support/en.lproj and Support/ru.lproj, and that no key is unused.
#
# Literals counted as keys: String(localized: "…"), and the first argument of
# Text, Label, Button, Section, Picker, TextField, Toggle, .help,
# .accessibilityLabel, plus `title:` / `lead:` / `text:` arguments (the
# LocalizedStringKey parameters). `Text(verbatim:)` is not a key.
# Interpolations (\(…)) match any format specifier (%@, %lld) in the key.
#
#   scripts/check-strings.sh          check, exit 1 on a problem
#   scripts/check-strings.sh --list   print the keys found in the sources
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 scripts/check-strings.py "$@"
