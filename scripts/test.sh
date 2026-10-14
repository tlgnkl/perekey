#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Runs `swift test`. Extra arguments are passed through. With PEREKEY_VOICE=1
# it tests the voice build, in .build/voice unless --scratch-path is given.
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

if [[ "${PEREKEY_VOICE:-}" == 1 ]]; then
    scripts/voice-pins.sh use
    [[ " $* " == *" --scratch-path "* ]] || extra+=(--scratch-path .build/voice)
fi

# PEREKEY_TEST_SCRIBBLE=1 fills freed memory with a pattern (MallocScribble),
# which makes a read of freed memory fail every time, not only under load.
if [[ "${PEREKEY_TEST_SCRIBBLE:-}" == 1 ]]; then
    export MallocScribble=1
fi

# Do not trust the exit code alone: a run that prints a failed summary but
# exits 0 would pass a gate. Keep the output (still streamed) and check it.
log="$(mktemp)"
trap 'rm -f "$log"' EXIT
status=0
swift test ${extra[@]+"${extra[@]}"} "$@" 2>&1 | tee "$log" || status=$?
if [[ $status -eq 0 ]] && grep -qE '^(✘|✗) Test run .* failed|^Test Suite .* failed|Executed [0-9]+ tests?, with [1-9][0-9]* failures?' "$log"; then
    echo "scripts/test.sh: swift test exited 0, but its output reports a failure." >&2
    status=1
fi
exit "$status"
