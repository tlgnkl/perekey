#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The package pins of the voice build (PEREKEY_VOICE=1, Package.swift).
#
# They live in Support/voice/Package.resolved, not at the package root: SwiftPM
# fetches every pin of a root Package.resolved, so builds without the flag (CI,
# releases) would clone FluidAudio and WhisperKit for nothing. The root file is
# ignored by git; the flagged scripts copy the pins there before they build.
#
# Usage: scripts/voice-pins.sh use | update | check
#   use     copy the pins to the package root
#   update  PEREKEY_VOICE=1 swift package update, then keep the new pins
#   check   resolve with the flag and fail if the pins differ from the kept ones
#           (compares the pins only: originHash and the file format change
#           between SwiftPM versions)
# Environment:
#   SCRATCH_PATH  SwiftPM build directory (default: .build/voice)
set -euo pipefail

cd "$(dirname "$0")/.."

PINS=Support/voice/Package.resolved
SCRATCH_PATH="${SCRATCH_PATH:-.build/voice}"

pins() {
    jq -S '[.pins[] | {identity, location, state}] | sort_by(.identity)' "$1"
}

case "${1:-}" in
    use)
        cp "$PINS" Package.resolved
        ;;
    update)
        cp "$PINS" Package.resolved
        PEREKEY_VOICE=1 swift package update --scratch-path "$SCRATCH_PATH"
        cp Package.resolved "$PINS"
        echo "Updated $PINS; commit it." >&2
        ;;
    check)
        swift --version
        cp "$PINS" Package.resolved
        PEREKEY_VOICE=1 swift package resolve --scratch-path "$SCRATCH_PATH"
        if ! diff -u <(pins "$PINS") <(pins Package.resolved); then
            echo "error: $PINS does not match Package.swift. Run scripts/voice-pins.sh update and commit it." >&2
            exit 1
        fi
        ;;
    *)
        echo "usage: scripts/voice-pins.sh use | update | check" >&2
        exit 2
        ;;
esac
