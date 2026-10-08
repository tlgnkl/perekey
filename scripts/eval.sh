#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Measures the classifier on the held-out corpus (docs/classifier.md).
#
# Usage: scripts/eval.sh [--full] [--sweep] [--typo-sweep] [--model <file>]
#
#   --full    the full corpus (about 1 M words) instead of the 50 k CI sample
#   --sweep   print the ROC points over thresholds too
#   --typo-sweep  print the typo correction points over minRank and margin too
#   --model   a model file (default: builds one with scripts/build-model.sh)
#
# Needs the held-out sources: scripts/fetch-data.sh lexicon heldout. The corpus
# is built once per size into .build/eval/ and reused. Exit status 1 when the
# plan's targets are missed: false switches < 0.1 % of words, recall ≥ 95 %.
set -euo pipefail

cd "$(dirname "$0")/.."

CACHE="${PEREKEY_DATA_CACHE:-$PWD/.build/data-cache}"
WORDS=50000
SWEEP=()
MODEL=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --full) WORDS=1000000 ;;
        --sweep) SWEEP+=(--sweep) ;;
        --typo-sweep) SWEEP+=(--typo-sweep) ;;
        --model) MODEL="$2"; shift ;;
        -h|--help) sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "eval: unknown argument $1" >&2; exit 2 ;;
    esac
    shift
done

[[ -f "$CACHE/tatoeba/rus_sentences.tsv.bz2" ]] || {
    echo "eval: no held-out sources in $CACHE; run scripts/fetch-data.sh heldout" >&2
    exit 1
}

if [[ -z "$MODEL" ]]; then
    PEREKEY_DATA_CACHE="$CACHE" scripts/build-model.sh >/dev/null
    MODEL="$PWD/.build/model/perekey.model"
fi

swift build -c release --product perekey-eval >/dev/null
bin="$(swift build -c release --show-bin-path)/perekey-eval"
mkdir -p .build/eval
corpus=".build/eval/corpus-$WORDS-seed1-typos.tsv"
if [[ ! -f "$corpus" ]]; then
    "$bin" corpus --cache "$CACHE" --code "$PWD/Sources" --out "$corpus" --words "$WORDS" --seed 1
fi
"$bin" run --model "$MODEL" --corpus "$corpus" --layouts "$PWD/Tests/PerekeyCoreTests/Fixtures" \
    --json ".build/eval/result-$WORDS.json" ${SWEEP[@]+"${SWEEP[@]}"}
