#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Local end-to-end check of the dictation paste (TextPaster): pastes a line
# into real apps through the gated PasteE2ETests and checks that the text
# arrived and the pasteboard came back. Then a password field, a target that
# changed, and a lost ⌘V: nothing pasted, the pasteboard untouched or back.
# Not for CI: it needs Accessibility for the terminal, an unlocked screen, and
# hands off keyboard and mouse while it runs. The pasteboard is the user's
# again at the end of every step.
#
# Usage: scripts/e2e-paste.sh [--no-build] [--apps "TextEdit Safari ..."] [--strategy menu|accessibility]
#   --apps      subset of: TextEdit Safari Chrome Notes Terminal Zen Slack VSCode
#               (apps that are not installed are skipped)
#   CHROME_APP  path of a Chromium app, e.g. Google Chrome for Testing.app
#
# Notes gets a new note (emptied after) and Terminal a new window (closed after).
# Slack: the text goes into the first field of the window and ⌘Z takes it back.
set -euo pipefail

cd "$(dirname "$0")/.."

BUILD=1
APPS="TextEdit Safari Chrome Notes Terminal Zen Slack VSCode"
STRATEGY=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-build) BUILD=0 ;;
        --apps) APPS="$2"; shift ;;
        --strategy) STRATEGY="$2"; shift ;;
        *) echo "unknown option: $1" >&2; exit 64 ;;
    esac
    shift
done

CHROME_APP="${CHROME_APP:-/Applications/Google Chrome.app}"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/perekey-paste.XXXXXX")
LOG="$TMP/log.txt"
CHROME_PID=""
cleanup() {
    [[ -n "$CHROME_PID" ]] && kill "$CHROME_PID" 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT

cat >"$TMP/field.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>perekey paste</title>
<textarea id="dictation" autofocus style="width:90vw;height:40vh"></textarea>
HTML
cat >"$TMP/password.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>perekey password</title>
<input type="password" autofocus>
HTML

# The field is replaced by a copy every 150 ms, as a re-rendering web app
# does: a new AX object each time, the same page.
cat >"$TMP/rerender.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>perekey rerender</title>
<textarea id="dictation" autofocus style="width:90vw;height:40vh"></textarea>
<script>
setInterval(() => {
    const old = document.getElementById("dictation");
    const copy = old.cloneNode();
    copy.value = old.value;
    const [start, end] = [old.selectionStart, old.selectionEnd];
    old.replaceWith(copy);
    copy.focus();
    copy.setSelectionRange(start, end);
}, 150);
</script>
HTML

# A locked screen: loginwindow holds Secure Input (System Events still names Finder).
secure_pid=$(ioreg -n Root -d1 | grep -oE '"kCGSSessionSecureInputPID"=[0-9]+' | head -1 | cut -d= -f2 || true)
if ioreg -n Root -d1 | grep -q '"CGSSessionScreenIsLocked"=Yes' \
    || { [[ -n "$secure_pid" ]] && ps -p "$secure_pid" -o comm= 2>/dev/null | grep -q loginwindow; }; then
    echo "The screen is locked: unlock it first (loginwindow holds Secure Input)." >&2
    exit 1
fi
# test.sh finds Swift Testing under Command Line Tools; the gated test itself is skipped here.
if [[ $BUILD == 1 ]]; then scripts/test.sh --filter PasteE2ETests >/dev/null; fi
.build/debug/perekey-e2e check || { echo "The terminal needs Accessibility." >&2; exit 1; }

# Apps are driven by `open -a` and keystrokes through System Events only:
# an Apple event to TextEdit or Notes would need an Automation consent first.
osa() { osascript "$@" >/dev/null; }
press() { osa -e "tell application \"System Events\" to keystroke \"$1\" using ${2:-command} down"; }
keycode() { osa -e "tell application \"System Events\" to key code $1${2:+ using $2 down}"; }
installed() { [[ -d "/Applications/$1.app" || -d "/System/Applications/$1.app" ]]; }
# A new empty TextEdit document in front.
textedit() { open -a TextEdit; sleep 1.5; press n; sleep 1; }
# Close the front TextEdit document without saving (⌘⌫ is "Delete" / "Don't Save").
textedit_close() { press w; sleep 0.7; keycode 51 command; }

FAILED=0
# run MODE [VAR=value ...]: one gated test against the frontmost app.
run() {
    local mode="$1"; shift
    local text="perekey e2e $(date +%s) Привет, мир"
    if env "$@" PEREKEY_E2E_PASTE="$text" PEREKEY_E2E_MODE="$mode" PEREKEY_E2E_STRATEGY="$STRATEGY" \
        swift test --skip-build --filter PasteE2ETests >"$TMP/run.txt" 2>&1; then
        grep 'PASTE-E2E' "$TMP/run.txt" | tee -a "$LOG"
    else
        FAILED=1
        grep -E 'PASTE-E2E|✘' "$TMP/run.txt" | tee -a "$LOG"
    fi
}

step() {
    local app="$1"
    case "$app" in
        TextEdit)
            textedit; run paste; textedit_close ;;
        Safari)
            open -a Safari "$TMP/field.html"; sleep 2; run paste PEREKEY_E2E_FOCUS=web; press w ;;
        Chrome)
            if [[ ! -d "$CHROME_APP" ]]; then echo "skip Chrome: $CHROME_APP not found"; return; fi
            local binary
            binary=$(find "$CHROME_APP/Contents/MacOS" -maxdepth 1 -type f -perm -u+x | head -1)
            # Chromium builds the web part of its AX tree only for assistive
            # apps it recognizes; the flag stands in for that here.
            "$binary" --user-data-dir="$TMP/chrome" --force-renderer-accessibility \
                --no-first-run --no-default-browser-check \
                "file://$TMP/field.html" >/dev/null 2>&1 &
            CHROME_PID=$!
            sleep 4
            osa -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $CHROME_PID) to true"
            sleep 1; run paste PEREKEY_E2E_FOCUS=web
            # The same field rebuilt between the capture and the paste.
            press l; sleep 0.3
            osa -e "tell application \"System Events\" to keystroke \"file://$TMP/rerender.html\""
            keycode 36; sleep 2; run paste PEREKEY_E2E_FOCUS=web
            kill "$CHROME_PID" 2>/dev/null || true; CHROME_PID="" ;;
        Notes)
            # ⌘Z takes the paste back; Notes drops the empty note by itself.
            open -a Notes; sleep 1.5; press n; sleep 1.5; run paste
            press z ;;
        Terminal)
            open -a Terminal; sleep 1; press n; sleep 1.5; run paste
            press u control
            # Another tab of the same window: text areas without identifiers.
            run changed PEREKEY_E2E_SWITCH_KEY=17
            press w; sleep 0.5; press w ;;
        Zen)
            if ! installed Zen; then echo "skip Zen"; return; fi
            open -a Zen "$TMP/field.html"; sleep 4; run paste PEREKEY_E2E_FOCUS=web; press w ;;
        Slack)
            if ! installed Slack; then echo "skip Slack"; return; fi
            # The first field of the page: the message box, or the sign-in form.
            open -a Slack; sleep 5; run paste PEREKEY_E2E_FOCUS=web; press z ;;
        VSCode)
            if ! installed "Visual Studio Code"; then echo "skip VS Code"; return; fi
            open -a "Visual Studio Code"; sleep 2; press n; sleep 1; run paste
            press z; press w ;;
        *) echo "unknown app: $app" >&2; exit 64 ;;
    esac
}

for app in $APPS; do step "$app"; done

# A password field: the subrole stops the paste.
open -a Safari "$TMP/password.html"; sleep 2; run secure PEREKEY_E2E_FOCUS=web; press w
# The user moved to another app before the paste.
textedit; run changed PEREKEY_E2E_SWITCH_TO=com.apple.finder
open -a TextEdit; sleep 0.7; textedit_close
# ⌘V lost on the way: the pasteboard still comes back. Only ⌘V can be lost.
if [[ -z "$STRATEGY" || "$STRATEGY" == commandV ]]; then textedit; run lost; textedit_close; fi

echo
if [[ $FAILED == 0 ]]; then echo "e2e-paste: all passed"; else echo "e2e-paste: FAILED (see above)"; exit 1; fi
