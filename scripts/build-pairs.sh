#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Counts which word follows which in the training text, for the pair tables of
# the ru and en models (docs/classifier.md, «Пары слов»), from the data cache
# (scripts/fetch-data.sh pairs).
#
# Usage: scripts/build-pairs.sh [--if-missing] [ru] [en]
#
#   --if-missing  skip a language whose <cache>/pairs/<language>.tsv exists
#                 (scripts/build-model.sh runs it so)
#   ru en         the languages (default: both)
#
# Environment:
#   PEREKEY_DATA_CACHE   the data cache (default: .build/data-cache)
#
# Two steps. scripts/wiki-text.py reads the parquet files of the group `pairs`
# in .build/venv (pyarrow, pinned with hashes in scripts/wiki-freq.requirements.txt)
# and writes <cache>/pairs/<language>.txt, an article to a line. `perekey-model
# pairs` counts the neighbouring words against the dictionary of the model and
# writes <cache>/pairs/<language>.tsv: only fingerprints and numbers, sorted.
# It takes minutes, so the tsv is cached with the data; scripts/build-model.sh
# then adds the best pairs to the model in seconds. The text file is a
# by-product, large and not needed after the count; it is deleted.
set -euo pipefail

cd "$(dirname "$0")/.."
# The tool has no voice: build it in .build without PEREKEY_VOICE.
unset PEREKEY_VOICE

CACHE="${PEREKEY_DATA_CACHE:-$PWD/.build/data-cache}"
IF_MISSING=0
LANGUAGES=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --if-missing) IF_MISSING=1 ;;
        ru|en) LANGUAGES+=("$1") ;;
        -h|--help) sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "build-pairs: unknown argument $1" >&2; exit 2 ;;
    esac
    shift
done
[[ ${#LANGUAGES[@]} -gt 0 ]] || LANGUAGES=(ru en)

todo=()
for language in "${LANGUAGES[@]}"; do
    if [[ "$IF_MISSING" == 1 && -f "$CACHE/pairs/$language.tsv" ]]; then
        continue
    fi
    ls "$CACHE"/wikipedia-pairs/"$language"/*.parquet >/dev/null 2>&1 || {
        echo "build-pairs: no training files in $CACHE/wikipedia-pairs/$language; run scripts/fetch-data.sh pairs" >&2
        exit 1
    }
    todo+=("$language")
done
[[ ${#todo[@]} -gt 0 ]] || exit 0

venv="$PWD/.build/venv"
if [[ ! -x "$venv/bin/python" ]] || ! "$venv/bin/python" -c 'import pyarrow' 2>/dev/null; then
    python3 -m venv "$venv"
    # Exact versions and hashes: nothing unpinned runs in a build.
    "$venv/bin/pip" install --quiet --require-hashes --only-binary :all: \
        -r scripts/wiki-freq.requirements.txt
fi

swift build -c release --product perekey-model >/dev/null
bin="$(swift build -c release --show-bin-path)/perekey-model"
# The text file is large: it goes away when a step fails, too.
text=""
trap '[[ -z "$text" ]] || rm -f "$text"' EXIT
for language in "${todo[@]}"; do
    text="$CACHE/pairs/$language.txt"
    "$venv/bin/python" scripts/wiki-text.py --cache "$CACHE" "$language"
    "$bin" pairs --cache "$CACHE" --data "$PWD/data" --language "$language" --sources scripts/fetch-data.sh
    rm -f "$text"
done
text=""
