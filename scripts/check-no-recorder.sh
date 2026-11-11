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
# Exit status 1 when a marker is found, 2 when there is no binary to check or
# strings has nothing to say about it; if strings itself fails, its status.
# CI runs it on the release build (release-build, release.yml) and on the app
# of the build job, and runs it on a PEREKEY_RECORD=1 build, debug and
# optimized (-c release), expecting it to fail.
set -euo pipefail

cd "$(dirname "$0")/.."

# One marker on each side: the recorder's queue (PerekeyInput) and the badge in
# the menu bar (Perekey). A binary with either has the recorder.
MARKERS=(
    "app.perekey.session-recorder"
    "app.perekey.recording-badge"
)
TARGET="${1:-.build/voice-universal/app/Perekey.app}"
if [[ -d "$TARGET" ]]; then
    BIN="$TARGET/Contents/MacOS/Perekey"
else
    BIN="$TARGET"
fi
[[ -f "$BIN" ]] || { echo "error: no binary at $BIN" >&2; exit 2; }

# strings reads every slice of a universal binary. -a: the whole file, not
# only the data sections, so a marker moved elsewhere is still found. The
# output is taken apart from the search: in `if strings | grep`, a strings that
# died would look like «no marker» and pass the check. Here a failure of
# strings stops the script (set -e) with its status. No grep -q on a pipe:
# it would stop at the first match and strings would die of SIGPIPE.
out="$(strings -a "$BIN")"
# A binary of any size has printable strings. None means strings saw nothing
# of it, and an empty haystack finds no marker.
[[ -n "$out" ]] || { echo "error: strings found nothing in $BIN: cannot check it" >&2; exit 2; }

for marker in "${MARKERS[@]}"; do
    if grep -qF -- "$marker" <<<"$out"; then
        echo "error: $BIN has the typing recorder ($marker): it was built with PEREKEY_RECORD=1" >&2
        exit 1
    fi
done
echo "ok: $BIN has no typing recorder"
