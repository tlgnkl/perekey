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
#   --check-base  only resolve QUALITY_BASE, say what it is and stop (the tests use it)
#
# Environment:
#   QUALITY_BASE         a git ref to compare with, as BENCH_BASE of scripts/bench.sh.
#                        The base plays with the bench of this tree, so the difference
#                        comes from the core alone. Without it the bars `noWorse` are
#                        not checked. A ref that is not a commit is an error (exit 2)
#                        in a pull request (GITHUB_EVENT_NAME=pull_request), a note on
#                        a push (the `before` of a first push is all zeros)
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
# (`fetch-data.sh heldout bench`); tech.ruso needs a gigabyte and stays on `--full`, and
# lang.rus-se and lang.russian-se take its place. Every suite costs the time of
# reading its source (about 6 s each); the budget of the step is 5 minutes (RE9).
CI_SUITES=(prose.tatoeba chat.tatoeba lang.rus-se lang.russian-se mixed.uk-se prose.uk
           typos.none typos.real.en typos.synth.equal typos.synth.neighbor typos.synth.swap hyphen yo doublecap
           class.frequent class.short class.collision class.names class.cli class.code
           protect.url protect.captcha protect.numbers protect.password)
# Suites that read the ru.stackoverflow corpus (`fetch-data.sh heavy`, a gigabyte): built when the
# cache has it, skipped without an error when it does not, never required.
OPTIONAL_SUITES=(class.oov class.brands)
# The suites the self-check plays on the `ci` level (with the hand-written cases): enough for
# the invariants and for every mutant, and a fifth of the cost of all of them.
SELF_SUITES=(flow.basics incidents prose.tatoeba lang.russian-se mixed.uk-se typos.synth.equal hyphen yo)
# The suites the self-check builds a second time on the `ci` level: their sources read fast.
REBUILD_SUITES=(lang.russian-se mixed.uk-se)

CACHE="${PEREKEY_DATA_CACHE:-$PWD/.build/data-cache}"
TIER=ci
SELF_CHECK=0
CHECK_BASE=0
REPORT=""
MODEL=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --full) TIER=full ;;
        --self-check) SELF_CHECK=1 ;;
        --check-base) CHECK_BASE=1 ;;
        --report)
            [[ $# -ge 2 && "$2" == html ]] || { echo "quality: --report html" >&2; exit 2; }
            REPORT=html; shift ;;
        --model)
            [[ $# -ge 2 ]] || { echo "quality: --model needs a directory" >&2; exit 2; }
            MODEL="$(cd "$2" && pwd)"; shift ;;
        -h|--help) sed -n '3,34p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "quality: unknown argument $1" >&2; exit 2 ;;
    esac
    shift
done
[[ "${GITHUB_ACTIONS:-}" == true ]] && SELF_CHECK=1

# The base to compare with: a commit of this repository, or nothing. Decided before anything is built.
base_ref=""
base_note="QUALITY_BASE is not set: the bars noWorse are not checked."
if [[ -n "${QUALITY_BASE:-}" ]]; then
    if git rev-parse --verify --quiet "$QUALITY_BASE^{commit}" >/dev/null; then
        base_ref="$QUALITY_BASE"
    elif [[ "${GITHUB_EVENT_NAME:-}" == pull_request ]]; then
        # A pull request always has its base; a base that is gone would pass every bar of noWorse unread.
        echo "quality: the base $QUALITY_BASE of this pull request is not a commit here (fetch-depth: 0?); the bars noWorse cannot be read" >&2
        exit 2
    else
        base_note="Base $QUALITY_BASE is not a commit here: nothing to compare with."
    fi
fi
if [[ "$CHECK_BASE" == 1 ]]; then
    echo "base: ${base_ref:-none}"
    echo "$base_note"
    exit 0
fi

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
# The seconds of every part, for the table at the end (RE9: the step has 300 s). Parts run side by side,
# so the sum is more than the step; `lap <name> <SECONDS at the start>` is safe from background jobs.
timings="$OUT/timings.tsv"
: >"$timings"
lap() { printf '%s\t%s\n' "$1" "$((SECONDS - $2))" >>"$timings"; }

[[ -f "$CACHE/tatoeba/rus_sentences.tsv.bz2" ]] || {
    echo "quality: no held-out sources in $CACHE; run scripts/fetch-data.sh lexicon wikifreq pairs heldout" >&2
    exit 2
}

stage "build perekey-eval"
t=$SECONDS
swift build -c release --product perekey-eval >/dev/null
lap "head: build perekey-eval" "$t"
bin="$(swift build -c release --show-bin-path)/perekey-eval"
if [[ -z "$MODEL" ]]; then
    t=$SECONDS
    PEREKEY_DATA_CACHE="$CACHE" scripts/build-model.sh >/dev/null
    lap "head: build model" "$t"
    MODEL="$ROOT/.build/model"
fi

# The base builds in the background from the start, while the cases are built and the head is checked and played.
base_run=""
base_pid=""
if [[ -n "$base_ref" ]]; then
    base_tree="$tmp/base"
    git worktree add --detach "$base_tree" "$base_ref" >/dev/null 2>&1
    if [[ ! -d "$base_tree/Sources/PerekeyEvalKit" ]]; then
        base_note="Base $base_ref has no bench: nothing to compare with."
    else
        (
            t_base=$SECONDS
            t=$SECONDS
            # The bench of this tree over the base, so that only the core differs.
            for dir in Sources/PerekeyEvalKit Sources/PerekeyDesk Sources/perekey-eval eval; do
                rsync -a --delete "$dir/" "$base_tree/$dir/"
            done
            grep -q 'PerekeyEvalKit' "$base_tree/Package.swift" || cp Package.swift "$base_tree/Package.swift"
            lap "base: worktree and bench" "$t"
            t=$SECONDS
            stand="the bench of this tree"
            if ! (cd "$base_tree" && swift build -c release --product perekey-eval --scratch-path "$tmp/base-build" >/dev/null); then
                echo "quality: the base does not build with this bench; building it with its own"
                git -C "$base_tree" checkout -q -- .
                git -C "$base_tree" clean -fdq
                stand="the bench of the base"
                (cd "$base_tree" && swift build -c release --product perekey-eval --scratch-path "$tmp/base-build" >/dev/null) \
                    || { echo "quality: the base does not build" >&2; exit 1; }
            fi
            lap "base: build perekey-eval" "$t"
            t=$SECONDS
            base_model="$MODEL"
            # One model when nothing that makes it differs; the base's own otherwise.
            if ! git diff --quiet "$base_ref" -- data scripts/build-model.sh scripts/fetch-data.sh scripts/wiki-freq.py \
                scripts/build-pairs.sh scripts/wiki-text.py Sources/perekey-model Sources/PerekeyModelKit Sources/PerekeyCore/ModelFormat.swift; then
                (cd "$base_tree" && PEREKEY_DATA_CACHE="$CACHE" scripts/build-model.sh --out "$tmp/base-model" >/dev/null)
                base_model="$tmp/base-model"
            fi
            lap "base: build model" "$t"
            lap "base: all" "$t_base"
            echo "$base_model" >"$tmp/base-model-path"
            echo "Compared with ${base_ref:0:9}, played with $stand." >"$tmp/base-note"
        ) &
        base_pid=$!
    fi
fi

stage "build the cases ($TIER)"
mkdir -p "$CASES" "$OUT/parts/$TIER"
rm -f "$CASES"/*.jsonl "$CASES/build.json"
if [[ "$TIER" == ci ]]; then
    suites=("${CI_SUITES[@]}" "${OPTIONAL_SUITES[@]}")
else
    suites=()
    for manifest in eval/suites/*.suite.json; do
        name="$(basename "$manifest" .suite.json)"
        suites+=("$name")
    done
fi
# One process per suite: reading a source takes most of the time, and the suites are independent.
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 2)"
build_suite() {
    local t=$SECONDS
    local part="$OUT/parts/$TIER/$1"
    rm -f "$part"/*.jsonl "$part/build.json" "$part/failed"
    mkdir -p "$part"
    "$bin" cases build --tier "$TIER" --cache "$CACHE" --skip-missing --only "$1" --out "$part" >"$part/log.txt" 2>&1 \
        || touch "$part/failed"
    lap "case: $1" "$t"
}
t_cases=$SECONDS
build_pids=()
for suite in "${suites[@]}"; do
    while [[ "$(jobs -r | wc -l)" -ge "$JOBS" ]]; do sleep 0.5; done
    build_suite "$suite" &
    build_pids+=($!)
done
# Only the case builds: a bare `wait` would also reap the base build, which is awaited later.
wait "${build_pids[@]}"
lap "cases: all ($JOBS at a time)" "$t_cases"
: >"$OUT/build.txt"
for suite in "${suites[@]}"; do
    part="$OUT/parts/$TIER/$suite"
    tee -a "$OUT/build.txt" <"$part/log.txt"
    if [[ -e "$part/failed" ]]; then
        if [[ " ${OPTIONAL_SUITES[*]} " == *" $suite "* ]] && grep -q "no source file" "$part/log.txt"; then
            echo "$suite: пропущен, нет источника (heavy)"
            continue
        fi
        echo "quality: the cases of $suite did not build" >&2; exit 2
    fi
    [[ ! -f "$part/$suite.jsonl" ]] || mv "$part/$suite.jsonl" "$CASES/$suite.jsonl"
done
python3 - "$OUT/parts/$TIER" "$CASES" "${suites[@]}" <<'PY'
import json, os, sys
parts, out, names = sys.argv[1], sys.argv[2], sys.argv[3:]
merged = {"tier": None, "suites": []}
for name in names:
    path = os.path.join(parts, name, "build.json")
    if os.path.exists(path):
        data = json.load(open(path))
        merged["tier"] = data["tier"]
        merged["suites"] += data["suites"]
json.dump(merged, open(os.path.join(out, "build.json"), "w"), separators=(",", ":"))
PY
if [[ "${GITHUB_ACTIONS:-}" == true && "$TIER" == ci ]]; then
    for suite in "${CI_SUITES[@]}"; do
        [[ -s "$CASES/$suite.jsonl" ]] || { echo "quality: the required suite $suite is missing (no source)" >&2; exit 2; }
    done
fi
ls "$CASES"/*.jsonl >/dev/null 2>&1 || { echo "quality: no suite was built: no source in $CACHE" >&2; exit 2; }

failed=0


stage "self-check and the head, together"
selfargs=(selfcheck --cases eval/cases "$CASES" --split dev --model "$MODEL" --cache "$CACHE"
          --suites eval/suites --tier "$TIER" --built "$CASES" --skip-missing)
if [[ "$TIER" == ci ]]; then selfargs+=(--only "$(join "${SELF_SUITES[@]}")" --rebuild "$(join "${REBUILD_SUITES[@]}")"); fi
if [[ "$SELF_CHECK" == 1 ]]; then selfargs+=(--mutants); fi
(
    t=$SECONDS
    status=0
    "$bin" "${selfargs[@]}" >"$OUT/selfcheck.txt" 2>&1 || status=$?
    lap "selfcheck" "$t"
    exit "$status"
) &
self_pid=$!
t=$SECONDS
"$bin" play --cases eval/cases "$CASES" --model "$MODEL" --cache "$CACHE" --out "$OUT/run-head" >"$OUT/play-head.txt"
lap "head: play" "$t"
stage "head played"
wait "$self_pid" || failed=1
cat "$OUT/selfcheck.txt"

if [[ -n "$base_pid" ]]; then
    wait "$base_pid" || { echo "quality: the base did not build" >&2; exit 1; }
    stage "play the base"
    base_model="$(cat "$tmp/base-model-path")"
    t=$SECONDS
    (cd "$base_tree" && "$tmp/base-build/release/perekey-eval" play --cases "$ROOT/eval/cases" "$CASES" \
        --model "$base_model" --cache "$CACHE" --data "$ROOT/data" --noise "$ROOT/eval/noise" \
        --layouts "$ROOT/eval/layouts" --lexicon "$OUT" --out "$OUT/run-base" >"$OUT/play-base.txt")
    lap "base: play" "$t"
    base_run="$OUT/run-base"
    base_note="$(cat "$tmp/base-note")"
fi

# A pull request that changes the stand and not the core: noWorse is shown, not a bar. The gate decides
# by the white list of StandChange (docs/eval.md, «Планки»): every changed file must lie in the stand.
git diff --name-only "${base_ref:-HEAD}" >"$OUT/changed.txt" 2>/dev/null || : >"$OUT/changed.txt"
gate_args=(--changed "$OUT/changed.txt")

stage "bars"
t_bars=$SECONDS
echo "$base_note"
status=0
"$bin" gate "$OUT/run-head" ${base_run:+"$base_run"} "${gate_args[@]}" | tee "$OUT/gate.txt" || status=$?
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
        "$bin" gate "$OUT/run-head" ${base_run:+"$base_run"} "${gate_args[@]}" --format md || true
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

lap "bars, diff, summary" "$t_bars"
stage "done"
echo "quality: seconds of the parts (they overlap)"
sort -t$'\t' -k2,2 -n -r "$timings" | awk -F'\t' '$1 !~ /^case: / { printf "  %5d s  %s\n", $2, $1 }'
echo "quality: the slowest case builds"
sort -t$'\t' -k2,2 -n -r "$timings" | awk -F'\t' '$1 ~ /^case: / { printf "  %5d s  %s\n", $2, $1 }' | head -8
exit "$failed"
