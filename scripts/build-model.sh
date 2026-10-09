#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds the language model files, one per language (ru.pklm, en.pklm,
# uk.pklm, be.pklm), from the data cache (scripts/fetch-data.sh lexicon wikifreq) and checks
# each file's hash against data/model.sha256.
#
# Usage: scripts/build-model.sh [--write] [--out <dir>] [--languages ru,en,uk,be]
#
#   --write   record the hashes of this build in data/model.sha256 instead of
#             checking them (after a deliberate change of the builder or data)
#   --out     the directory for the files (default: .build/model)
#   --languages  the languages to build (default: ru,en,uk,be). be and kk
#             count their words with scripts/wiki-freq.py, run here in
#             .build/venv (pip install pyarrow msgpack) when the list is
#             missing; kk also needs scripts/fetch-data.sh text. The hashes
#             are checked and recorded for the built languages only
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
LANGUAGES=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --write) WRITE=1 ;;
        --out) OUT="$2"; shift ;;
        --languages) LANGUAGES="$2"; shift ;;
        -h|--help) sed -n '3,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "build-model: unknown argument $1" >&2; exit 2 ;;
    esac
    shift
done

[[ -f "$CACHE/wordfreq/large_ru.msgpack.gz" ]] || {
    echo "build-model: no data cache in $CACHE; run scripts/fetch-data.sh lexicon wikifreq" >&2
    exit 1
}

# Languages wordfreq lacks: the word counts of the Wikipedia snapshot.
for language in $(tr , ' ' <<< "${LANGUAGES:-ru,en,uk,be}"); do
    [[ "$language" == be || "$language" == kk ]] || continue
    [[ -f "$CACHE/wikifreq/large_$language.msgpack.gz" ]] && continue
    venv="$PWD/.build/venv"
    if [[ ! -x "$venv/bin/python" ]] || ! "$venv/bin/python" -c 'import pyarrow, msgpack' 2>/dev/null; then
        python3 -m venv "$venv"
        "$venv/bin/pip" install --quiet pyarrow msgpack
    fi
    "$venv/bin/python" scripts/wiki-freq.py --cache "$CACHE" "$language"
done

swift build -c release --product perekey-model >/dev/null
bin="$(swift build -c release --show-bin-path)/perekey-model"
mkdir -p "$OUT"
log="$(mktemp)"
trap 'rm -f "$log"' EXIT
args=(--cache "$CACHE" --data "$PWD/data" --out "$OUT")
[[ -n "$LANGUAGES" ]] && args+=(--languages "$LANGUAGES")
"$bin" "${args[@]}" | tee "$log"
hashes="$(sed -n 's/^sha256 //p' "$log" | LC_ALL=C sort -k2)"
# The recorded lines of the languages built now; the others stay as they are.
built="$(awk '{ print $2 }' <<< "$hashes" | paste -sd, -)"
recorded() { # keep|drop
    [[ -f data/model.sha256 ]] || return 0
    awk -v mode="$1" -v built="$built" 'BEGIN { n = split(built, a, ","); for (i = 1; i <= n; i++) b[a[i]] = 1 }
        { if ((mode == "keep") == ($2 in b)) print }' data/model.sha256
}

if [[ "$WRITE" == 1 ]]; then
    { recorded drop; echo "$hashes"; } | LC_ALL=C sort -k2 > data/model.sha256.new
    mv data/model.sha256.new data/model.sha256
    echo "recorded the hashes in data/model.sha256"
elif [[ -f data/model.sha256 ]]; then
    if ! diff <(recorded keep) <(echo "$hashes") >&2; then
        echo "FAIL: model hashes differ from data/model.sha256 (< recorded, > this build)." >&2
        echo "      Builder or data changed? Run scripts/build-model.sh --write and commit." >&2
        exit 1
    fi
    echo "hashes match data/model.sha256"
fi
