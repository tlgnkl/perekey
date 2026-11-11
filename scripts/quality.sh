#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The quality bench: builds the cases of the corpus suites, plays them on the
# machine, compares the run with one of a base commit and checks the bars of
# eval/gates.json (docs/eval.md).
#
# Usage: scripts/quality.sh [--full] [--self-check] [--report html] [--model <dir>]
#
#   --full        the `full` level of the suites (hundreds of thousands of tokens
#                 per scenario, all suites whose source is in the cache) instead
#                 of the `ci` level
#   --self-check  also play the mutants (a machine with corrupted options must
#                 move the counts it should); in CI this is always on
#   --report html also write the report of the run as HTML to .build/quality/report.html
#   --model       a directory of language models (default: builds them with
#                 scripts/build-model.sh)
#
# Environment:
#   QUALITY_BASE         a git ref to compare with, as BENCH_BASE of scripts/bench.sh.
#                        The base plays with the bench of this tree, so the difference
#                        comes from the core alone. Without it the bars `noWorse` are
#                        not checked
#   PEREKEY_DATA_CACHE   the data cache (default: .build/data-cache)
#
# Needs the held-out sources: scripts/fetch-data.sh lexicon wikifreq pairs heldout.
# Suites whose source is not in the cache are skipped with a line saying so; in CI
# (GITHUB_ACTIONS=true) the suites listed in CI_SUITES must be built, and a missing
# one is an error. Exit status: 0 the bars are taken, 1 a bar is not taken or the
# self-check failed, 2 no required source or the cases did not build.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
# The tool has no voice: build it in .build without PEREKEY_VOICE.
unset PEREKEY_VOICE

# The suites of the `ci` level. Their sources are what CI already downloads
# (`fetch-data.sh heldout`); tech.ruso needs a gigabyte and stays on `--full`, and
# lang.rus-se and lang.russian-se take its place. Every suite costs the time of
# reading its source (about 6 s each); the budget of the step is 5 minutes (RE9).
CI_SUITES=(prose.tatoeba chat.tatoeba lang.rus-se lang.russian-se mixed.uk-se prose.uk)
# The suites the self-check builds a second time on the `ci` level: their sources read fast.
REBUILD_SUITES=(lang.russian-se mixed.uk-se)

CACHE="${PEREKEY_DATA_CACHE:-$PWD/.build/data-cache}"
TIER=ci
SELF_CHECK=0
REPORT=""
MODEL=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --full) TIER=full ;;
        --self-check) SELF_CHECK=1 ;;
        --report)
            [[ $# -ge 2 && "$2" == html ]] || { echo "quality: --report html" >&2; exit 2; }
            REPORT=html; shift ;;
        --model)
            [[ $# -ge 2 ]] || { echo "quality: --model needs a directory" >&2; exit 2; }
            MODEL="$2"; shift ;;
        -h|--help) sed -n '3,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "quality: unknown argument $1" >&2; exit 2 ;;
    esac
    shift
done
[[ "${GITHUB_ACTIONS:-}" == true ]] && SELF_CHECK=1

join() { local IFS=,; echo "$*"; }

OUT="$ROOT/.build/quality"
CASES="$OUT/cases/$TIER"
mkdir -p "$OUT"
tmp="$(mktemp -d)"
base_tree=""
cleanup() {
    [[ -n "$base_tree" ]] && git worktree remove --force "$base_tree" >/dev/null 2>&1
    rm -rf "$tmp"
}
trap cleanup EXIT

started=$SECONDS
stage() { echo "quality: $1 ($((SECONDS - started)) s since the start)"; }

[[ -f "$CACHE/tatoeba/rus_sentences.tsv.bz2" ]] || {
    echo "quality: no held-out sources in $CACHE; run scripts/fetch-data.sh lexicon wikifreq pairs heldout" >&2
    exit 2
}

stage "build perekey-eval"
swift build -c release --product perekey-eval >/dev/null
bin="$(swift build -c release --show-bin-path)/perekey-eval"
if [[ -z "$MODEL" ]]; then
    PEREKEY_DATA_CACHE="$CACHE" scripts/build-model.sh >/dev/null
    MODEL="$ROOT/.build/model"
fi

stage "build the cases ($TIER)"
mkdir -p "$CASES"
rm -f "$CASES"/*.jsonl "$CASES/build.json"
only=()
if [[ "$TIER" == ci ]]; then only=(--only "$(join "${CI_SUITES[@]}")"); fi
"$bin" cases build --tier "$TIER" --cache "$CACHE" --skip-missing ${only[@]+"${only[@]}"} --out "$CASES" \
    | tee "$OUT/build.txt" || { echo "quality: the cases did not build" >&2; exit 2; }
if [[ "${GITHUB_ACTIONS:-}" == true && "$TIER" == ci ]]; then
    for suite in "${CI_SUITES[@]}"; do
        [[ -s "$CASES/$suite.jsonl" ]] || { echo "quality: the required suite $suite is missing (no source)" >&2; exit 2; }
    done
fi
ls "$CASES"/*.jsonl >/dev/null 2>&1 || { echo "quality: no suite was built: no source in $CACHE" >&2; exit 2; }

failed=0

stage "self-check"
selfargs=(selfcheck --cases eval/cases "$CASES" --split dev --model "$MODEL" --cache "$CACHE"
          --suites eval/suites --tier "$TIER" --built "$CASES" --skip-missing)
if [[ "$TIER" == ci ]]; then selfargs+=(--rebuild "$(join "${REBUILD_SUITES[@]}")"); fi
if [[ "$SELF_CHECK" == 1 ]]; then selfargs+=(--mutants); fi
"$bin" "${selfargs[@]}" | tee "$OUT/selfcheck.txt" || failed=1

stage "play the head"
"$bin" play --cases eval/cases "$CASES" --model "$MODEL" --cache "$CACHE" --out "$OUT/run-head" >"$OUT/play-head.txt"

# The base: a worktree of QUALITY_BASE with the bench of this tree over it.
base_run=""
base_note="QUALITY_BASE is not set: the bars noWorse are not checked."
if [[ -n "${QUALITY_BASE:-}" ]]; then
    if ! git rev-parse --verify --quiet "$QUALITY_BASE^{commit}" >/dev/null; then
        base_note="Base $QUALITY_BASE is not a commit here: nothing to compare with."
    else
        base_tree="$tmp/base"
        git worktree add --detach "$base_tree" "$QUALITY_BASE" >/dev/null 2>&1
        if [[ ! -d "$base_tree/Sources/PerekeyEvalKit" ]]; then
            base_note="Base $QUALITY_BASE has no bench: nothing to compare with."
        else
            stage "build the base ${QUALITY_BASE:0:9}"
            for dir in Sources/PerekeyEvalKit Sources/PerekeyDesk Sources/perekey-eval eval; do
                rsync -a --delete "$dir/" "$base_tree/$dir/"
            done
            grep -q 'PerekeyEvalKit' "$base_tree/Package.swift" || cp Package.swift "$base_tree/Package.swift"
            base_stand="the bench of this tree"
            if ! (cd "$base_tree" && swift build -c release --product perekey-eval --scratch-path "$tmp/base-build" >/dev/null); then
                echo "quality: the base does not build with this bench; building it with its own"
                git -C "$base_tree" checkout -q -- .
                git -C "$base_tree" clean -fdq
                base_stand="the bench of the base"
                (cd "$base_tree" && swift build -c release --product perekey-eval --scratch-path "$tmp/base-build" >/dev/null) \
                    || { echo "quality: the base does not build" >&2; exit 1; }
            fi
            # One model when nothing that makes it differs; the base's own otherwise.
            base_model="$MODEL"
            if ! git diff --quiet "$QUALITY_BASE" -- data scripts/build-model.sh scripts/fetch-data.sh scripts/wiki-freq.py \
                scripts/build-pairs.sh scripts/wiki-text.py Sources/perekey-model Sources/PerekeyModelKit Sources/PerekeyCore/ModelFormat.swift; then
                stage "build the model of the base"
                (cd "$base_tree" && PEREKEY_DATA_CACHE="$CACHE" scripts/build-model.sh --out "$tmp/base-model" >/dev/null)
                base_model="$tmp/base-model"
            fi
            stage "play the base"
            (cd "$base_tree" && "$tmp/base-build/release/perekey-eval" play --cases "$ROOT/eval/cases" "$CASES" \
                --model "$base_model" --cache "$CACHE" --data "$ROOT/data" --noise "$ROOT/eval/noise" \
                --layouts "$ROOT/eval/layouts" --lexicon "$OUT" --out "$OUT/run-base" >"$OUT/play-base.txt")
            base_run="$OUT/run-base"
            base_note="Compared with ${QUALITY_BASE:0:9}, played with $base_stand."
        fi
    fi
fi

# A pull request that changes the stand and not the core: noWorse is shown, not a bar.
changed="$(git diff --name-only "${QUALITY_BASE:-HEAD}" 2>/dev/null || true)"
gate_args=()
if grep -qE '^(Sources/PerekeyEvalKit/|Sources/PerekeyDesk/|eval/)' <<<"$changed" \
    && ! grep -qE '^(Sources/PerekeyCore/|Sources/PerekeyInput/|Sources/Perekey/|Sources/PerekeyModelKit/|Sources/perekey-model/|data/|scripts/build-model\.sh|scripts/fetch-data\.sh)' <<<"$changed"; then
    gate_args+=(--stand-pr)
fi

stage "bars"
echo "$base_note"
status=0
"$bin" gate "$OUT/run-head" ${base_run:+"$base_run"} ${gate_args[@]+"${gate_args[@]}"} | tee "$OUT/gate.txt" || status=$?
[[ "$status" == 0 ]] || failed=1
if [[ -n "$base_run" ]]; then
    "$bin" diff "$base_run" "$OUT/run-head" --list 40 | tee "$OUT/diff.txt"
fi
if [[ "$REPORT" == html ]]; then
    "$bin" report "$OUT/run-head" --format html --out "$OUT/report.html"
    echo "quality: $OUT/report.html"
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
        echo "# Quality bench ($TIER)"
        echo
        echo "$base_note"
        echo
        "$bin" gate "$OUT/run-head" ${base_run:+"$base_run"} ${gate_args[@]+"${gate_args[@]}"} --format md || true
        if [[ -n "$base_run" ]]; then
            echo
            "$bin" diff "$base_run" "$OUT/run-head" --list 40 --format md
        fi
        echo
        echo '## Self-check'
        echo
        echo '```'
        cat "$OUT/selfcheck.txt"
        echo '```'
        echo
        echo '## Report'
        echo
        "$bin" report "$OUT/run-head" --format md --words 20
    } >>"$GITHUB_STEP_SUMMARY"
fi

stage "done"
exit "$failed"
