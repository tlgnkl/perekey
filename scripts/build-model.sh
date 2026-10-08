#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds the language model from the data cache (scripts/fetch-data.sh lexicon)
# and checks its hash against data/model.sha256.
#
# Usage: scripts/build-model.sh [--write] [--out <file>]
#
#   --write   record the hash of this build in data/model.sha256 instead of
#             checking it (after a deliberate change of the builder or data)
#
# Environment:
#   PEREKEY_DATA_CACHE   the data cache (default: .build/data-cache)
#
# The model is not committed: the build takes seconds, so CI rebuilds it and
# compares the hash. docs/classifier.md explains the decision.
set -euo pipefail

cd "$(dirname "$0")/.."

CACHE="${PEREKEY_DATA_CACHE:-$PWD/.build/data-cache}"
OUT="$PWD/.build/model/perekey.model"
WRITE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --write) WRITE=1 ;;
        --out) OUT="$2"; shift ;;
        -h|--help) sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
mkdir -p "$(dirname "$OUT")"
"$bin" --cache "$CACHE" --data "$PWD/data" --out "$OUT" | tee "$OUT.log"
hash="$(sed -n 's/^sha256 //p' "$OUT.log")"
rm -f "$OUT.log"

if [[ "$WRITE" == 1 ]]; then
    echo "$hash" > data/model.sha256
    echo "recorded $hash in data/model.sha256"
elif [[ -f data/model.sha256 ]]; then
    want="$(cat data/model.sha256)"
    if [[ "$hash" != "$want" ]]; then
        echo "FAIL: model hash $hash differs from data/model.sha256 ($want)." >&2
        echo "      Builder or data changed? Run scripts/build-model.sh --write and commit." >&2
        exit 1
    fi
    echo "hash matches data/model.sha256"
fi
