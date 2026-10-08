#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Runs `swift test`. Extra arguments are passed through.
#
# Command Line Tools (without Xcode) ship the Swift Testing macro plugin outside
# the default search path, and `swift test` fails with "plugin for module
# 'TestingMacros' not found". Point the compiler at it in that case.
set -euo pipefail

cd "$(dirname "$0")/.."

extra=()
plugin=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
if [[ "$(xcode-select -p)" == /Library/Developer/CommandLineTools && -d "$plugin" ]]; then
    extra=(-Xswiftc -plugin-path -Xswiftc "$plugin")
fi

exec swift test ${extra[@]+"${extra[@]}"} "$@"
