#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Runs the spike's tests. The Command Line Tools fixes are those of the root
# scripts/test.sh (Swift Testing plugin and framework outside the search path).
set -euo pipefail

cd "$(dirname "$0")/.."

extra=()
clt=/Library/Developer/CommandLineTools
if [[ "$(xcode-select -p)" == "$clt" ]]; then
    extra+=(-Xswiftc -plugin-path -Xswiftc "$clt/usr/lib/swift/host/plugins/testing")
    framework="$(find "$clt" -maxdepth 6 -name Testing.framework -type d 2>/dev/null | head -n 1)"
    dir="$(dirname "$framework")"
    extra+=(-Xswiftc -F -Xswiftc "$dir" -Xlinker -rpath -Xlinker "$dir")
    interop="$(find "$clt" -maxdepth 6 -name lib_TestingInterop.dylib 2>/dev/null | head -n 1)"
    [[ -n "$interop" ]] && extra+=(-Xlinker -rpath -Xlinker "$(dirname "$interop")")
fi
swift test "${extra[@]}" "$@"
