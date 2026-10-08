#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Local end-to-end check: types wrong-layout words into real apps, presses the
# retype shortcut (Option) and compares the text with the expected one.
# Not for CI: it needs Accessibility for the terminal and a logged-in session.
#
# Usage: scripts/e2e.sh [--dry-run] [--no-build] [--apps "TextEdit Safari ..."]
#   --dry-run   print the plan, build nothing, post nothing
#   --no-build  use the existing .build/app/Perekey.app and helper
#   --apps      subset of: TextEdit Safari Terminal Chrome Telegram VSCode
#
# Prerequisites:
#   - Layouts ABC and Russian are the only two enabled; Option = retype, Shift = switch.
#   - Perekey has Accessibility; the terminal running this script has it too.
#   - Safari: Develop > Developer Settings > Allow JavaScript from Apple Events.
#   - Chrome: View > Developer > Allow JavaScript from Apple Events.
#   - Telegram: open any chat first (the text goes into the message field,
#     nothing is sent). VS Code: open an empty file first.
#   - Do not touch keyboard or mouse while it runs.
set -euo pipefail

cd "$(dirname "$0")/.."

DRY=0
BUILD=1
APPS="TextEdit Safari Terminal Chrome Telegram VSCode"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY=1 ;;
        --no-build) BUILD=0 ;;
        --apps) APPS="$2"; shift ;;
        *) echo "unknown option: $1" >&2; exit 64 ;;
    esac
    shift
done

APP=".build/app/Perekey.app"
HELPER=".build/release/perekey-e2e"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR=".build/e2e"
RESULTS="$OUT_DIR/results-$STAMP.txt"
WORK="$OUT_DIR/work-$STAMP"
TERM_FILE="$PWD/$WORK/terminal.txt"
HTML_URL='data:text/html,<textarea id=t autofocus rows=6 cols=60></textarea>'

mkdir -p "$OUT_DIR" "$WORK"
: > "$RESULTS"

say() { echo "$*" | tee -a "$RESULTS"; }
run() { if [[ $DRY -eq 1 ]]; then echo "  [dry] $*"; else "$@"; fi; }
h() { if [[ $DRY -eq 1 ]]; then echo "  [dry] perekey-e2e $*"; else "$HELPER" "$@"; fi; }

# Scenarios: name | typed text | Option presses | typed right after | expected.
# "Right after" is typed with no pause, to catch letters lost to the old layout.
SCENARIOS=(
    "Option|ghbdtn|1||привет"
    "Option twice|ghbdtn|2||ghbdtn"
    "Option comma|,eltn|1||будет"
    "Fast typing|ghbdtn|1| vbh|привет мир"
)

# --- build and start --------------------------------------------------------
if [[ $BUILD -eq 1 ]]; then
    say "Building Perekey.app and the helper"
    run ~/.claude/bin/heavy-gate -- scripts/bundle.sh
    run ~/.claude/bin/heavy-gate -- swift build -c release --product perekey-e2e
fi
if [[ $DRY -eq 0 && ! -x "$HELPER" ]]; then
    echo "Helper $HELPER not found. Run without --no-build." >&2
    exit 1
fi

if [[ $DRY -eq 0 ]] && ! "$HELPER" check; then
    cat >&2 <<'MSG'
The terminal running this script may not post keystrokes.
  1. Open System Settings > Privacy & Security > Accessibility.
  2. Add the terminal app (Terminal, iTerm2, Orca) and switch it on.
  3. Do the same under Input Monitoring.
  4. Quit the terminal completely, open it again, run the script again.
MSG
    exit 1
fi

# `open`, never the binary: macOS ties permissions to the bundle.
run pkill -x Perekey 2>/dev/null || true
run open "$APP"
run sleep 2
if [[ $DRY -eq 0 ]] && ! pgrep -x Perekey >/dev/null; then
    echo "Perekey did not start." >&2
    exit 1
fi

# --- per-app drivers ---------------------------------------------------------
# For each app NAME: installed_NAME, setup_NAME, clear_NAME, read_NAME,
# teardown_NAME. read_NAME prints the text of the field.

osa() { if [[ $DRY -eq 1 ]]; then echo "  [dry] osascript: ${1:0:60}"; else osascript -e "$1"; fi; }
focus() { osa "tell application \"$1\" to activate"; sleep 1; }

read_clip() {
    # Select all, copy, read the clipboard. Overwrites the clipboard.
    h key cmd-a cmd-c
    sleep 0.3
    if [[ $DRY -eq 1 ]]; then echo ""; else pbpaste; fi
}
clear_keys() { h key cmd-a delete; sleep 0.2; }

installed_TextEdit() { [[ -d /System/Applications/TextEdit.app ]]; }
setup_TextEdit() {
    osa 'tell application "TextEdit" to make new document' >/dev/null
    focus TextEdit
}
read_TextEdit() { osa 'tell application "TextEdit" to get text of document 1'; }
clear_TextEdit() { clear_keys; }
teardown_TextEdit() {
    osa 'tell application "TextEdit" to close document 1 saving no' >/dev/null 2>&1 || true
}

installed_Safari() {
    [[ -d /Applications/Safari.app || -d /System/Cryptexes/App/System/Applications/Safari.app ]]
}
setup_Safari() {
    osa "tell application \"Safari\" to make new document with properties {URL:\"$HTML_URL\"}" >/dev/null
    focus Safari
}
read_Safari() {
    osa 'tell application "Safari" to do JavaScript "document.getElementById(\"t\").value" in document 1' \
        || { echo "(JavaScript from Apple Events is off; reading via clipboard)" >&2; read_clip; }
}
clear_Safari() { clear_keys; }
teardown_Safari() { osa 'tell application "Safari" to close document 1' >/dev/null 2>&1 || true; }

installed_Chrome() { [[ -d "/Applications/Google Chrome.app" ]]; }
setup_Chrome() {
    osa 'tell application "Google Chrome" to make new window' >/dev/null
    osa "tell application \"Google Chrome\" to set URL of active tab of front window to \"$HTML_URL\"" >/dev/null
    focus "Google Chrome"
}
read_Chrome() {
    osa 'tell application "Google Chrome" to execute active tab of front window javascript "document.getElementById(\"t\").value"' \
        || { echo "(JavaScript from Apple Events is off; reading via clipboard)" >&2; read_clip; }
}
clear_Chrome() { clear_keys; }
teardown_Chrome() { osa 'tell application "Google Chrome" to close front window' >/dev/null 2>&1 || true; }

installed_Terminal() { true; }
setup_Terminal() {
    rm -f "$TERM_FILE"
    osa "tell application \"Terminal\" to do script \"cat > '$TERM_FILE'\"" >/dev/null
    focus Terminal
}
# One scenario = one line: Return ends it, cat writes it, the last line is the result.
read_Terminal() { h key return; sleep 0.5; tail -n 1 "$TERM_FILE" 2>/dev/null || true; }
clear_Terminal() { :; }
teardown_Terminal() {
    h key ctrl-d
    osa 'tell application "Terminal" to close front window' >/dev/null 2>&1 || true
}

installed_Telegram() { [[ -d /Applications/Telegram.app ]]; }
setup_Telegram() { focus Telegram; }
read_Telegram() { read_clip; }
clear_Telegram() { clear_keys; }
teardown_Telegram() { :; }

installed_VSCode() { [[ -d "/Applications/Visual Studio Code.app" ]]; }
setup_VSCode() { focus "Visual Studio Code"; }
read_VSCode() { read_clip; }
clear_VSCode() { clear_keys; }
teardown_VSCode() { :; }

# --- run ----------------------------------------------------------------------
ensure_abc() {
    [[ $DRY -eq 1 ]] && return 0
    local layout
    layout="$("$HELPER" layout)"
    if [[ "$layout" != *ABC* && "$layout" != *US* ]]; then
        "$HELPER" shift
        sleep 0.4
    fi
}

run_scenario() {
    local app="$1" spec="$2" name typed presses after expected got status i
    IFS='|' read -r name typed presses after expected <<<"$spec"
    "clear_$app"
    ensure_abc
    h type "$typed"
    h sleep-ms 400
    for ((i = 0; i < presses; i++)); do
        h option
        # Between two presses wait for the retype to finish; before typing, do not.
        if ((i + 1 < presses)); then h sleep-ms 500; fi
    done
    if [[ -n "$after" ]]; then h type --delay-ms 5 "$after"; fi
    h sleep-ms 700
    if [[ $DRY -eq 1 ]]; then
        got="(dry run)"; status="DRY"
    else
        got="$("read_$app" | tr -d '\r' | sed -e 's/[[:space:]]*$//')"
        if [[ "$got" == "$expected" ]]; then status="PASS"; else status="FAIL"; fi
    fi
    say "$(printf '%-10s | %-13s | %-4s | want "%s" got "%s"' "$app" "$name" "$status" "$expected" "$got")"
}

say "Perekey e2e $STAMP, macOS $(sw_vers -productVersion 2>/dev/null || echo '?')"
for app in $APPS; do
    if ! "installed_$app"; then
        say "$(printf '%-10s | SKIP | not installed' "$app")"
        continue
    fi
    say "== $app"
    "setup_$app"
    for spec in "${SCENARIOS[@]}"; do
        run_scenario "$app" "$spec"
    done
    "teardown_$app"
done

if [[ $DRY -eq 1 ]]; then
    echo "Dry run done; nothing was posted."
    exit 0
fi

FAILS="$(grep -c ' | FAIL ' "$RESULTS" || true)"
say ""
say "Failures: $FAILS. Results saved to $RESULTS"
[[ "$FAILS" -eq 0 ]]
