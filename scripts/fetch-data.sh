#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Downloads third-party data for the Perekey model and the held-out corpus.
# Sources, licenses and the reasons for each choice: data/SOURCES.md.
# Downloaded files never go into git.
#
# Usage: scripts/fetch-data.sh [group...]
#
# Groups:
#   lexicon   word lists and frequencies for the model (~12 MB)
#   text      Wikipedia text for character n-grams (~360 MB)
#   model     lexicon + text (default)
#   heldout   held-out corpus sources, used only for evaluation (~130 MB)
#   heavy     large optional held-out source: ru.stackoverflow.com (~1 GB)
#   fallback  needs a legal decision before use: OpenCorpora dictionary
#   all       model + heldout
#
# Environment:
#   PEREKEY_DATA_CACHE    cache directory (default: .build/data-cache)
#   PEREKEY_DATA_REFRESH  1 = download rolling (unpinned) sources again
#
# Pinned files are checked against SHA-256 (one archive.org file only has
# SHA-1) and downloaded again on mismatch. Rolling sources have no stable
# versions. $PEREKEY_DATA_CACHE/MANIFEST.sha256 records the SHA-256 of every
# cached file, pinned or rolling. A second run downloads nothing.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="${PEREKEY_DATA_CACHE:-$ROOT/.build/data-cache}"
REFRESH="${PEREKEY_DATA_REFRESH:-0}"

# Pinned upstream revisions. Change them together with the hashes below.
WORDFREQ_REV=42233e6c36ce792031bcccfa17cdd0cec9af5fa7   # tag v3.2
LO_DICT_REV=32b006a2c22a4ac7e8ed3f03346f7b3d85a970a4    # LibreOffice/dictionaries, 2026-08-21
ESDB_REL=rel-2026.02.25                                 # en-wl/wordlist (SCOWL / ESDB)
ESDB_VER=2026.02.25
WIKI_REV=b04c8d1ceb2f5cd4588862100d08de323dccfbaa       # huggingface wikimedia/wikipedia
WIKI_SNAPSHOT=20231101

GH_RAW=https://raw.githubusercontent.com
HF_WIKI="https://huggingface.co/datasets/wikimedia/wikipedia/resolve/$WIKI_REV/$WIKI_SNAPSHOT"
IA_SE=https://archive.org/download/stackexchange

# group|path in cache|url|sha256 ("-" = rolling source, not pinned)
SOURCES="
lexicon|wordfreq/large_ru.msgpack.gz|$GH_RAW/rspeer/wordfreq/$WORDFREQ_REV/wordfreq/data/large_ru.msgpack.gz|0440613cc765c14a20fb9483225f2fec4d85e66672809076bcec9b29119f9b43
lexicon|wordfreq/large_en.msgpack.gz|$GH_RAW/rspeer/wordfreq/$WORDFREQ_REV/wordfreq/data/large_en.msgpack.gz|dffae8066b78dce0a6667cf5f58e567054f902674667090a7ac8a8a44628b05c
lexicon|wordfreq/LICENSE.txt|$GH_RAW/rspeer/wordfreq/$WORDFREQ_REV/LICENSE.txt|8990c551671a51765c4dfe9428f3e1d58dc327f49aca346a32d28cc0fcc7aa88
lexicon|wordfreq/README.md|$GH_RAW/rspeer/wordfreq/$WORDFREQ_REV/README.md|0f1db058e1df2e6bda2db5d0ea851a7111d2390ec16a9939d971ef53ea24f684
lexicon|hunspell-ru/ru_RU.dic|$GH_RAW/LibreOffice/dictionaries/$LO_DICT_REV/ru_RU/ru_RU.dic|f6047416a0204adbecf3a451b874ec8a97ee37e2cbc714466ef04d8dbcc0d6fc
lexicon|hunspell-ru/ru_RU.aff|$GH_RAW/LibreOffice/dictionaries/$LO_DICT_REV/ru_RU/ru_RU.aff|38ce7d4af78e211e9bafe4bf7e3d6a2c420591136cb738ec6648f8fdf6524cd7
lexicon|hunspell-ru/README_ru_RU.txt|$GH_RAW/LibreOffice/dictionaries/$LO_DICT_REV/ru_RU/README_ru_RU.txt|262af2f6ad70a61e5ee1332ff44fa8ee50edca819cf33207d8ad6ba6a0c9be52
lexicon|esdb/hunspell-en_US-large-$ESDB_VER.zip|https://github.com/en-wl/wordlist/releases/download/$ESDB_REL/hunspell-en_US-large-$ESDB_VER.zip|06ab5a2a12c29033f100988d3b0a5e53dcad40bf2473ccb78270619d1da99321
text|wikipedia/ru/train-00007-of-00021.parquet|$HF_WIKI.ru/train-00007-of-00021.parquet|39b59952cd92a148b301f4d2b3ae1fb71e4caab987c6abe278f0dbdf0b01bb88
text|wikipedia/en/train-00028-of-00041.parquet|$HF_WIKI.en/train-00028-of-00041.parquet|10589a39188af404fa458da252df7dcf22c6f6395a1501d9243ef56ce4c3c148
heldout|tatoeba/sentences_CC0.tar.bz2|https://downloads.tatoeba.org/exports/sentences_CC0.tar.bz2|-
heldout|tatoeba/rus_sentences.tsv.bz2|https://downloads.tatoeba.org/exports/per_language/rus/rus_sentences.tsv.bz2|-
heldout|tatoeba/eng_sentences.tsv.bz2|https://downloads.tatoeba.org/exports/per_language/eng/eng_sentences.tsv.bz2|-
heldout|stackexchange/russian.stackexchange.com.7z|$IA_SE/russian.stackexchange.com.7z|5508d4cb5978e216482225aef6f193dec31b7d67f16d0fa5ad0367931103348d
heldout|stackexchange/rus.stackexchange.com.7z|$IA_SE/rus.stackexchange.com.7z|f7ce56e7027f55ebc735c6206e712c75f47b9b508a0f851580f32a086590b930
heldout|stackexchange/license.txt|$IA_SE/license.txt|d36393108ad6b64f97a7b17dd873fe670ace6aa948975ef546a744481678e545
heldout|geonames/cities15000.zip|https://download.geonames.org/export/dump/cities15000.zip|-
heavy|stackexchange/ru.stackoverflow.com.7z|$IA_SE/ru.stackoverflow.com.7z|sha1:32a8897c021e9c943b93f8fd70dfafb180925451
fallback|opencorpora/dict.opcorpora.xml.bz2|https://opencorpora.org/files/export/dict/dict.opcorpora.xml.bz2|-
"

die() { echo "fetch-data: $*" >&2; exit 1; }

sha256_of() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        sha256sum "$1" | cut -d' ' -f1
    fi
}

# Checks a file against "<sha256>" or "sha1:<sha1>".
hash_ok() { # file want
    case "$2" in
        sha1:*)
            if command -v shasum >/dev/null 2>&1; then
                [[ "$(shasum -a 1 "$1" | cut -d' ' -f1)" == "${2#sha1:}" ]]
            else
                [[ "$(sha1sum "$1" | cut -d' ' -f1)" == "${2#sha1:}" ]]
            fi ;;
        *) [[ "$(sha256_of "$1")" == "$2" ]] ;;
    esac
}

download() { # url dest
    curl --fail --location --silent --show-error \
        --retry 3 --retry-delay 2 --connect-timeout 30 \
        --output "$2" "$1"
}

fetch() { # path url sha256
    local path="$1" url="$2" want="$3"
    local dest="$CACHE/$path"
    mkdir -p "$(dirname "$dest")"

    if [[ -f "$dest" ]]; then
        if [[ "$want" == "-" ]]; then
            if [[ "$REFRESH" != "1" ]]; then
                echo "ok      $path (rolling, cached)"
                return
            fi
        elif hash_ok "$dest" "$want"; then
            echo "ok      $path"
            return
        else
            echo "stale   $path: hash mismatch, downloading again"
        fi
    fi

    echo "get     $path"
    local part="$dest.part"
    rm -f "$part"
    download "$url" "$part" || { rm -f "$part"; die "download failed: $url"; }
    if [[ "$want" != "-" ]] && ! hash_ok "$part" "$want"; then
        local got
        got="$(sha256_of "$part")"
        rm -f "$part"
        die "hash mismatch for $path: want $want, got sha256 $got"
    fi
    mv "$part" "$dest"
}

want_group() { # group
    local g
    for g in "${GROUPS_WANTED[@]}"; do
        [[ "$g" == "$1" ]] && return 0
    done
    return 1
}

GROUPS_WANTED=()
if [[ $# -eq 0 ]]; then
    GROUPS_WANTED=(lexicon text)
fi
for arg in "$@"; do
    case "$arg" in
        lexicon|text|heldout|heavy|fallback) GROUPS_WANTED+=("$arg") ;;
        model) GROUPS_WANTED+=(lexicon text) ;;
        all) GROUPS_WANTED+=(lexicon text heldout) ;;
        -h|--help) sed -n '3,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown group: $arg (lexicon, text, model, heldout, heavy, fallback, all)" ;;
    esac
done

mkdir -p "$CACHE"
echo "cache   $CACHE"

while IFS='|' read -r group path url sha; do
    [[ -z "$group" ]] && continue
    want_group "$group" || continue
    fetch "$path" "$url" "$sha"
done <<< "$SOURCES"

# Hashes of everything in the cache, pinned and rolling, for the model builder.
(
    cd "$CACHE"
    find . -type f ! -name '*.part' ! -name MANIFEST.sha256 | LC_ALL=C sort |
        while read -r f; do
            printf '%s  %s\n' "$(sha256_of "$f")" "${f#./}"
        done
) > "$CACHE/MANIFEST.sha256"
echo "wrote   $CACHE/MANIFEST.sha256"
