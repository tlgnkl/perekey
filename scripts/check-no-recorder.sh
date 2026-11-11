#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Checks that a Perekey build has no typing recorder in it. The recorder
# (PerekeyInput/SessionRecorder.swift) is built only with PEREKEY_RECORD=1, for
# the live measure on a developer's Mac (CONTRIBUTING.md, «Recording typing for
# the measure»); a release must never carry it. The recorder names its queue
# with a marker string, and the marker is in every binary that has the recorder.
#
# Usage: scripts/check-no-recorder.sh [path/to/Perekey.app or path/to/binary]
#        (default: .build/voice-universal/app/Perekey.app)
#
# Exit status 1 when the marker is found, 2 when there is no binary to check.
# CI runs it on the release build (release-build, release.yml) and on the app
# of the build job, and runs it on a PEREKEY_RECORD=1 build expecting it to fail.
set -euo pipefail

cd "$(dirname "$0")/.."

MARKER="app.perekey.session-recorder"
TARGET="${1:-.build/voice-universal/app/Perekey.app}"
if [[ -d "$TARGET" ]]; then
    BIN="$TARGET/Contents/MacOS/Perekey"
else
    BIN="$TARGET"
fi
[[ -f "$BIN" ]] || { echo "error: no binary at $BIN" >&2; exit 2; }

# strings reads every slice of a universal binary. -a: the whole file, not
# only the data sections, so a marker moved elsewhere is still found. No
# grep -q: it would stop at the first match, strings would die of SIGPIPE, and
# pipefail would turn the find into a pass.
if strings -a "$BIN" | grep -F "$MARKER" >/dev/null; then
    echo "error: $BIN has the typing recorder ($MARKER): it was built with PEREKEY_RECORD=1" >&2
    exit 1
fi
echo "ok: $BIN has no typing recorder"
