#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds the language model files, one per language (ru.pklm, en.pklm,
# uk.pklm), from the data cache (scripts/fetch-data.sh lexicon) and checks
# each file's hash against data/model.sha256.
#
# Usage: scripts/build-model.sh [--write] [--out <dir>]
#
#   --write   record the hashes of this build in data/model.sha256 instead of
#             checking them (after a deliberate change of the builder or data)
#   --out     the directory for the files (default: .build/model)
#
# Environment:
#   PEREKEY_DATA_CACHE   the data cache (default: .build/data-cache)
#
# The model is not committed: the build takes seconds, so CI rebuilds it and
# compares the hashes. data/model.sha256 has one `shasum -a 256` line per
# file, so a change in one language's data names that file only.
# docs/classifier.md explains the decision.
set -euo pipefail

cd "$(dirname "$0")/.."

CACHE="${PEREKEY_DATA_CACHE:-$PWD/.build/data-cache}"
OUT="$PWD/.build/model"
WRITE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --write) WRITE=1 ;;
        --out) OUT="$2"; shift ;;
        -h|--help) sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "build-model: unknown argument $1" >&2; exit 2 ;;
    esac
    shift
done

[[ -f "$CACHE/wordfreq/large_ru.msgpack.gz" ]] || {
    echo "build-model: no data cache in $CACHE; run scripts/fetch-data.sh lexicon" >&2
    exit 1
}

swift build -c release --product perekey-model >/dev/null
bin="$(swift build -c release --show-bin-path)/perekey-model"
mkdir -p "$OUT"
log="$(mktemp)"
trap 'rm -f "$log"' EXIT
"$bin" --cache "$CACHE" --data "$PWD/data" --out "$OUT" | tee "$log"
hashes="$(sed -n 's/^sha256 //p' "$log" | LC_ALL=C sort -k2)"

if [[ "$WRITE" == 1 ]]; then
    echo "$hashes" > data/model.sha256
    echo "recorded the hashes in data/model.sha256"
elif [[ -f data/model.sha256 ]]; then
    if ! diff <(cat data/model.sha256) <(echo "$hashes") >&2; then
        echo "FAIL: model hashes differ from data/model.sha256 (< recorded, > this build)." >&2
        echo "      Builder or data changed? Run scripts/build-model.sh --write and commit." >&2
        exit 1
    fi
    echo "hashes match data/model.sha256"
fi
