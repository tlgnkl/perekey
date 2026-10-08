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
clt=/Library/Developer/CommandLineTools
if [[ "$(xcode-select -p)" == "$clt" ]]; then
    plugin=$clt/usr/lib/swift/host/plugins/testing
    if [[ -d "$plugin" ]]; then
        extra+=(-Xswiftc -plugin-path -Xswiftc "$plugin")
    fi
    # Some Command Line Tools releases keep Testing.framework where SwiftPM
    # does not look. Find it and point the compiler and the linker there.
    framework="$(find "$clt" -maxdepth 6 -name Testing.framework -type d 2>/dev/null | head -n 1)"
    if [[ -n "$framework" ]]; then
        dir="$(dirname "$framework")"
        extra+=(-Xswiftc -F -Xswiftc "$dir" -Xlinker -rpath -Xlinker "$dir")
        # Testing.framework links @rpath/lib_TestingInterop.dylib.
        interop="$(find "$clt" -maxdepth 6 -name lib_TestingInterop.dylib 2>/dev/null | head -n 1)"
        if [[ -n "$interop" ]]; then
            extra+=(-Xlinker -rpath -Xlinker "$(dirname "$interop")")
        fi
    else
        echo "Swift Testing is not part of these Command Line Tools ($clt)." >&2
        echo "Install a newer Command Line Tools or Xcode to run the tests." >&2
        exit 1
    fi
fi

exec swift test ${extra[@]+"${extra[@]}"} "$@"
