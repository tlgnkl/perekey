#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Benchmarks InputMachine in a release build.
#
# With BENCH_BASE=<git ref>, also builds the benchmark at that commit and runs
# both in turns, so machine load affects them alike. Fails if the mean time per
# event grew more than 20 %. A base without the benchmark is skipped.
set -euo pipefail

cd "$(dirname "$0")/.."

ROUNDS="${BENCH_ROUNDS:-5}"
FIXTURES="$PWD/Tests/PerekeyCoreTests/Fixtures"
tmp="$(mktemp -d)"
base_tree=""
cleanup() {
    [[ -n "$base_tree" ]] && git worktree remove --force "$base_tree" >/dev/null 2>&1
    rm -rf "$tmp"
}
trap cleanup EXIT

swift build -c release --product perekey-bench >/dev/null
head_bin="$(swift build -c release --show-bin-path)/perekey-bench"
"$head_bin" "$FIXTURES" "$tmp/head-0.json"

[[ -z "${BENCH_BASE:-}" ]] && exit 0
if ! git rev-parse --verify --quiet "$BENCH_BASE^{commit}" >/dev/null; then
    echo "Base $BENCH_BASE is not a commit here, nothing to compare."
    exit 0
fi
base_tree="$tmp/base"
git worktree add --detach "$base_tree" "$BENCH_BASE" >/dev/null 2>&1
if [[ ! -d "$base_tree/Sources/perekey-bench" ]]; then
    echo "Base $BENCH_BASE has no benchmark, nothing to compare."
    exit 0
fi
(cd "$base_tree" && swift build -c release --product perekey-bench --scratch-path "$tmp/base-build" >/dev/null)
base_bin="$tmp/base-build/release/perekey-bench"

for round in $(seq 1 "$ROUNDS"); do
    "$base_bin" "$FIXTURES" "$tmp/base-$round.json" >/dev/null
    "$head_bin" "$FIXTURES" "$tmp/head-$round.json" >/dev/null
done

python3 - "$tmp" "$ROUNDS" <<'PY'
import json, sys
tmp, rounds = sys.argv[1], int(sys.argv[2])
best = lambda side: min(json.load(open(f"{tmp}/{side}-{i}.json"))["mean"] for i in range(1, rounds + 1))
base, head = best("base"), best("head")
change = head / base - 1
print(f"mean per event: base {base:.1f} ns, head {head:.1f} ns, change {change:+.1%}")
if change > 0.2:
    print("FAIL: mean time per event grew more than 20 %")
    sys.exit(1)
PY
