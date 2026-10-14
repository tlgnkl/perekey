#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Fails when the sources call a model loader of FluidAudio or WhisperKit.
# Speech models come only from the app's own store, with checksums. Those
# loaders fetch on their own, and FluidAudio's wipe a model folder that fails
# to load and fetch it again. CI runs this in the voice job.
#
# Usage: scripts/check-voice-loaders.sh [dir]   (default: Sources)
# Exit status: 0 clean, 1 a loader found, 2 the check itself failed.
set -euo pipefail

cd "$(dirname "$0")/.."

DIR="${1:-Sources}"
[[ -d "$DIR" ]] || { echo "error: no directory $DIR" >&2; exit 2; }
found=0

hits="$(mktemp)"
kept="$(mktemp)"
trap 'rm -f "$hits" "$kept"' EXIT

# grep -r over DIR into $hits; 1 (nothing found) is fine, above it is an error.
search() {
    local rc=0
    grep -rn "$@" "$DIR" > "$hits" || rc=$?
    if ((rc > 1)); then
        echo "error: grep failed ($rc)" >&2
        exit 2
    fi
}

report() {
    [[ -s "$2" ]] || return 0
    echo "$1:" >&2
    cat "$2" >&2
    found=1
}

# The loaders by name. A tokenizer `from(pretrained:` comes from the Hub, and
# ModelUtilities.loadTokenizer falls back to it.
loaders='downloadAndLoad|downloadAndPreload|downloadIfNeeded|downloadVariant|[A-Za-z]*Models\.download\b|ModelHub\.download|fetchFile|DownloadUtils|WhisperKit\.download|fetchAvailableModels|fetchModelSupportConfig|HubApi|ModelDownloader|from\(pretrained:|ModelUtilities\.loadTokenizer'
search -E "$loaders"
report "Model loaders of FluidAudio or WhisperKit" "$hits"

# ModelHub only for ModelHub.offlineMode: its other members download.
search -oE 'ModelHub\.[A-Za-z_]+'
rc=0
grep -vE ':ModelHub\.offlineMode$' "$hits" > "$kept" || rc=$?
((rc <= 1)) || { echo "error: grep failed ($rc)" >&2; exit 2; }
report "ModelHub other than ModelHub.offlineMode" "$kept"

# Calls whose arguments must name what they load from: VadManager without a
# loaded model, and WhisperKitConfig with its default download: true, load
# through the hub. The arguments may span lines.
calls() {
    local call="$1" need="$2" file
    : > "$hits"
    while IFS= read -r -d '' file; do
        awk -v call="$call" -v need="$need" '
            { text = text $0 "\n" }
            END {
                from = 1
                while ((i = index(substr(text, from), call)) > 0) {
                    start = from + i - 1
                    p = start + length(call)
                    depth = 1
                    while (depth > 0 && p <= length(text)) {
                        c = substr(text, p, 1)
                        if (c == "(") depth++
                        else if (c == ")") depth--
                        p++
                    }
                    args = substr(text, start + length(call), p - start - length(call))
                    if (args !~ need) {
                        before = substr(text, 1, start)
                        print FILENAME ":" gsub(/\n/, "", before) + 1 ": " call "...)"
                    }
                    from = p
                }
            }' "$file" >> "$hits" || { echo "error: awk failed on $file" >&2; exit 2; }
    done < <(find "$DIR" -name '*.swift' -print0)
}
calls 'VadManager(' 'vadModel:'
report "VadManager( without a vadModel: argument" "$hits"
calls 'WhisperKitConfig(' 'download:[[:space:]]*false'
report "WhisperKitConfig( without download: false as an argument" "$hits"

if ((found)); then
    echo "error: models load only from the app's own store (see the lines above)" >&2
    exit 1
fi
