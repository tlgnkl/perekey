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
#   lexicon   word lists and frequencies for the model (~26 MB)
#   text      Wikipedia ru, en and uk, one file each, held out: the hyphen
#             step is measured on them, and nothing trains on them
#             (~0.5 GB). The n-grams come from wordfreq, not from here
#   pairs     Wikipedia ru and en, other files of the same snapshot, to count
#             which word follows which (~0.8 GB). Training text: no file of
#             `text`, `wikifreq` or `heldout` is in it (perekey-model pairs
#             checks it). Lands in wikipedia-pairs/, apart from `text`
#   wikifreq  Wikipedia be and kk, the word counts of their models: CI builds
#             and checks every model file, shipped or not
#   model     lexicon + text + wikifreq (default)
#   heldout   held-out corpus sources, used only for evaluation (~141 MB)
#   bench     small sources of the quality bench (`perekey-eval`, docs/eval.md):
#             the Wikipedia list of common misspellings. Evaluation only, not
#             in CI's default fetch (~0.1 MB)
#   heavy     large optional held-out source: ru.stackoverflow.com (~1 GB)
#   fallback  needs a legal decision before use: OpenCorpora (ru), Wiktionary
#             forms (uk, ~300 MB)
#   speech    FLEURS (Google, CC BY 4.0), ru and en, the dev split: 50 recordings
#             with their reference text per language, for `perekey-voice-probe
#             score`. Local measure only, not in CI, not in the app (~360 MB)
#   all       model + pairs + heldout
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
FLEURS_REV=70bb2e84b976b7e960aa89f1c648e09c59f894dd     # huggingface google/fleurs, CC BY 4.0
SPEECH_COUNT=50                                         # recordings kept per language
WM_REV=1199637275                                       # en.wikipedia.org, Wikipedia:Lists of common misspellings/For machines, 2024-01-27, CC BY-SA 4.0

GH_RAW=https://raw.githubusercontent.com
HF_WIKI="https://huggingface.co/datasets/wikimedia/wikipedia/resolve/$WIKI_REV/$WIKI_SNAPSHOT"
IA_SE=https://archive.org/download/stackexchange
HF_FLEURS="https://huggingface.co/datasets/google/fleurs/resolve/$FLEURS_REV/data"
WM_RAW="https://en.wikipedia.org/w/index.php?title=Wikipedia:Lists_of_common_misspellings/For_machines&oldid=$WM_REV&action=raw"

# group|path in cache|url|sha256 ("-" = rolling source, not pinned)
SOURCES="
lexicon|wordfreq/large_ru.msgpack.gz|$GH_RAW/rspeer/wordfreq/$WORDFREQ_REV/wordfreq/data/large_ru.msgpack.gz|0440613cc765c14a20fb9483225f2fec4d85e66672809076bcec9b29119f9b43
lexicon|wordfreq/large_en.msgpack.gz|$GH_RAW/rspeer/wordfreq/$WORDFREQ_REV/wordfreq/data/large_en.msgpack.gz|dffae8066b78dce0a6667cf5f58e567054f902674667090a7ac8a8a44628b05c
lexicon|wordfreq/large_uk.msgpack.gz|$GH_RAW/rspeer/wordfreq/$WORDFREQ_REV/wordfreq/data/large_uk.msgpack.gz|0a7d525ef5b9d2c84cd3ccd1064b02eb6a07232e5d1e465df40cc00168fdaac2
lexicon|wordfreq/LICENSE.txt|$GH_RAW/rspeer/wordfreq/$WORDFREQ_REV/LICENSE.txt|8990c551671a51765c4dfe9428f3e1d58dc327f49aca346a32d28cc0fcc7aa88
lexicon|wordfreq/README.md|$GH_RAW/rspeer/wordfreq/$WORDFREQ_REV/README.md|0f1db058e1df2e6bda2db5d0ea851a7111d2390ec16a9939d971ef53ea24f684
lexicon|hunspell-ru/ru_RU.dic|$GH_RAW/LibreOffice/dictionaries/$LO_DICT_REV/ru_RU/ru_RU.dic|f6047416a0204adbecf3a451b874ec8a97ee37e2cbc714466ef04d8dbcc0d6fc
lexicon|hunspell-ru/ru_RU.aff|$GH_RAW/LibreOffice/dictionaries/$LO_DICT_REV/ru_RU/ru_RU.aff|38ce7d4af78e211e9bafe4bf7e3d6a2c420591136cb738ec6648f8fdf6524cd7
lexicon|hunspell-ru/README_ru_RU.txt|$GH_RAW/LibreOffice/dictionaries/$LO_DICT_REV/ru_RU/README_ru_RU.txt|262af2f6ad70a61e5ee1332ff44fa8ee50edca819cf33207d8ad6ba6a0c9be52
lexicon|hunspell-be/be-official.dic|$GH_RAW/LibreOffice/dictionaries/$LO_DICT_REV/be_BY/be-official.dic|86237db80ddf5dc68d4319abed4de709a2096835042b332cf323207c13e869cd
lexicon|hunspell-be/be-official.aff|$GH_RAW/LibreOffice/dictionaries/$LO_DICT_REV/be_BY/be-official.aff|0a7f8246a352e7eea61f88d44a200a277a8a5dd5b06f1d7725f16138d1b751c1
lexicon|hunspell-be/README_be_BY.txt|$GH_RAW/LibreOffice/dictionaries/$LO_DICT_REV/be_BY/README_be_BY.txt|8e11338bf07f3fc3eea1add0a091c3da4e1e0504a63f909790dabeef27de1ec3
lexicon|esdb/hunspell-en_US-large-$ESDB_VER.zip|https://github.com/en-wl/wordlist/releases/download/$ESDB_REL/hunspell-en_US-large-$ESDB_VER.zip|06ab5a2a12c29033f100988d3b0a5e53dcad40bf2473ccb78270619d1da99321
text|wikipedia/ru/train-00007-of-00021.parquet|$HF_WIKI.ru/train-00007-of-00021.parquet|39b59952cd92a148b301f4d2b3ae1fb71e4caab987c6abe278f0dbdf0b01bb88
text|wikipedia/en/train-00028-of-00041.parquet|$HF_WIKI.en/train-00028-of-00041.parquet|10589a39188af404fa458da252df7dcf22c6f6395a1501d9243ef56ce4c3c148
text|wikipedia/uk/train-00002-of-00010.parquet|$HF_WIKI.uk/train-00002-of-00010.parquet|11f25bf916b71e9030626104542acbe298b0ee1bfc394444928253d91a4095a2
pairs|wikipedia-pairs/ru/train-00010-of-00021.parquet|$HF_WIKI.ru/train-00010-of-00021.parquet|f480c34cd725c63ce276a322ac2f06aa97c3b356c4574a94fb5a273a1501857b
pairs|wikipedia-pairs/ru/train-00011-of-00021.parquet|$HF_WIKI.ru/train-00011-of-00021.parquet|30a2bd638e0556d1d09d459fd5ef5a4a7accbd54a7cc452798770bd80481dc5f
pairs|wikipedia-pairs/en/train-00022-of-00041.parquet|$HF_WIKI.en/train-00022-of-00041.parquet|50ba80435bf2fd0b818533a1ca3118454a3ae275dc2250e0b68dc852dd03f3d2
pairs|wikipedia-pairs/en/train-00023-of-00041.parquet|$HF_WIKI.en/train-00023-of-00041.parquet|b722b7e4039c65382286b6aa5a35f9a4c5d3536b758c346a94af7a2a692cc6bb
wikifreq|wikipedia/be/train-00000-of-00002.parquet|$HF_WIKI.be/train-00000-of-00002.parquet|68048674aca99df6826cb3cc212a0c14eedd70ddf66aedd3833fb55aca7a8b39
wikifreq|wikipedia/be/train-00001-of-00002.parquet|$HF_WIKI.be/train-00001-of-00002.parquet|d7930469968c695b232d005bbfb7857db3b0c14245887acf0fab374312d97d6f
wikifreq|wikipedia/kk/train-00000-of-00001.parquet|$HF_WIKI.kk/train-00000-of-00001.parquet|7ecd6679b1635942941a67744eca1f677ec01fca9b60406253bda128ebf80dc4
heldout|tatoeba/sentences_CC0.tar.bz2|https://downloads.tatoeba.org/exports/sentences_CC0.tar.bz2|-
heldout|tatoeba/rus_sentences.tsv.bz2|https://downloads.tatoeba.org/exports/per_language/rus/rus_sentences.tsv.bz2|-
heldout|tatoeba/eng_sentences.tsv.bz2|https://downloads.tatoeba.org/exports/per_language/eng/eng_sentences.tsv.bz2|-
heldout|tatoeba/ukr_sentences.tsv.bz2|https://downloads.tatoeba.org/exports/per_language/ukr/ukr_sentences.tsv.bz2|-
heldout|tatoeba/bel_sentences.tsv.bz2|https://downloads.tatoeba.org/exports/per_language/bel/bel_sentences.tsv.bz2|-
heldout|tatoeba/kaz_sentences.tsv.bz2|https://downloads.tatoeba.org/exports/per_language/kaz/kaz_sentences.tsv.bz2|-
heldout|stackexchange/russian.stackexchange.com.7z|$IA_SE/russian.stackexchange.com.7z|5508d4cb5978e216482225aef6f193dec31b7d67f16d0fa5ad0367931103348d
heldout|stackexchange/rus.stackexchange.com.7z|$IA_SE/rus.stackexchange.com.7z|f7ce56e7027f55ebc735c6206e712c75f47b9b508a0f851580f32a086590b930
heldout|stackexchange/ukrainian.stackexchange.com.7z|$IA_SE/ukrainian.stackexchange.com.7z|8cf51f9d9e69ed9e05870002a440628cccc99074ebc842aeec7439b7ec21636c
heldout|stackexchange/license.txt|$IA_SE/license.txt|d36393108ad6b64f97a7b17dd873fe670ace6aa948975ef546a744481678e545
heldout|geonames/cities15000.zip|https://download.geonames.org/export/dump/cities15000.zip|-
speech|fleurs/ru_ru.dev.tsv|$HF_FLEURS/ru_ru/dev.tsv|25d9dc88a7533fc0f303354a8e6d3c8186c557229c9a0024487090a11226171e
speech|fleurs/en_us.dev.tsv|$HF_FLEURS/en_us/dev.tsv|9d57ee7e91e9d4c92edb39f6bbea668ef8dc2a3ff96eb510d5580b2ad05d17ec
speech|fleurs/ru_ru.dev.tar.gz|$HF_FLEURS/ru_ru/audio/dev.tar.gz|4dc533cd0f312f749bd6d0fe968f3183288d938e07ed97dc141d9f10570457f9
speech|fleurs/en_us.dev.tar.gz|$HF_FLEURS/en_us/audio/dev.tar.gz|2658fda72f199e12676ecac9415094667a4e14e149b146e568ea00b2a2f0954c
bench|wikipedia-misspellings/for-machines.txt|$WM_RAW|3b6a9290e5aaad968da7ec769a5174adb45247688ef7ae097fd2dd80237a3050
heavy|stackexchange/ru.stackoverflow.com.7z|$IA_SE/ru.stackoverflow.com.7z|sha1:32a8897c021e9c943b93f8fd70dfafb180925451
fallback|opencorpora/dict.opcorpora.xml.bz2|https://opencorpora.org/files/export/dict/dict.opcorpora.xml.bz2|-
fallback|wiktionary/kaikki-uk.jsonl|https://kaikki.org/dictionary/Ukrainian/kaikki.org-dictionary-Ukrainian.jsonl|-
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

curl_get() { # url dest
    curl --fail --location --silent --show-error \
        --retry 3 --retry-delay 2 --connect-timeout 30 \
        --output "$2" "$1"
}

# archive.org sends /download/ to one storage node, and a sick node answers 500.
# The item metadata lists the replicas; each serves the same file at
# https://<server><dir>/<file>. The caller checks the hash as for any source,
# so a replica cannot swap the content.
archive_replicas() { # url -> replica urls, one per line
    local rest="${1#https://archive.org/download/}" item file meta
    item="${rest%%/*}"
    file="${rest#*/}"
    meta="$(curl --fail --location --silent --show-error --retry 3 --retry-delay 2 \
        --connect-timeout 30 "https://archive.org/metadata/$item")" || return 0
    printf '%s' "$meta" | python3 -I -c '
import json, sys
item, file = sys.argv[1], sys.argv[2]
try:
    m = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
servers = list(m.get("workable_servers") or [])
servers += [m[k] for k in ("d1", "d2") if m.get(k)]
d = m.get("dir")
if not d:
    sys.exit(0)
seen = set()
for s in servers:
    if s not in seen:
        seen.add(s)
        print("https://%s%s/%s" % (s, d, file))
' "$item" "$file" 2>/dev/null || true
}

download() { # url dest
    curl_get "$1" "$2" && return 0
    [[ "$1" == https://archive.org/download/*/* ]] || return 1
    echo "retry   $1 failed, trying archive.org replicas" >&2
    local replica
    while IFS= read -r replica; do
        [[ -z "$replica" ]] && continue
        echo "retry   $replica" >&2
        rm -f "$2"
        curl_get "$replica" "$2" && return 0
    done < <(archive_replicas "$1")
    return 1
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
    GROUPS_WANTED=(lexicon text pairs wikifreq)
fi
for arg in "$@"; do
    case "$arg" in
        lexicon|text|pairs|wikifreq|heldout|speech|bench|heavy|fallback) GROUPS_WANTED+=("$arg") ;;
        model) GROUPS_WANTED+=(lexicon text pairs wikifreq) ;;
        all) GROUPS_WANTED+=(lexicon text pairs wikifreq heldout) ;;
        -h|--help) sed -n '3,41p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown group: $arg (lexicon, text, pairs, wikifreq, model, heldout, speech, bench, heavy, fallback, all)" ;;
    esac
done

mkdir -p "$CACHE"
echo "cache   $CACHE"

while IFS='|' read -r group path url sha; do
    [[ -z "$group" ]] && continue
    want_group "$group" || continue
    fetch "$path" "$url" "$sha"
done <<< "$SOURCES"

# The cache counts as whole only if every file named in `refs.tsv` is there.
speech_cache_whole() { # folder
    [[ -s "$1/refs.tsv" ]] || return 1
    local file
    while IFS=$'\t' read -r file _; do
        [[ -s "$1/$file" ]] || return 1
    done < "$1/refs.tsv"
}

# The speech set: the first SPEECH_COUNT recordings of different sentences, in
# the order of the split's table, with their reference text. The audio stays
# in $CACHE/speech/<ru|en>/; `refs.tsv` there is "file<TAB>reference".
# Extraction goes to a side folder that replaces the cache in one `mv`, with
# `refs.tsv` written last: a failed `tar` leaves no half-filled cache.
extract_speech() { # language code (ru, en), fleurs name (ru_ru, en_us)
    local lang="$1" name="$2" out="$CACHE/speech/$1"
    local table="$CACHE/fleurs/$name.dev.tsv" archive="$CACHE/fleurs/$name.dev.tar.gz"
    if speech_cache_whole "$out"; then
        echo "ok      speech/$lang ($(wc -l < "$out/refs.tsv" | tr -d ' ') recordings)"
        return
    fi
    local side="$out.new"
    rm -rf "$out" "$side" "$side.refs" "$side.list"
    mkdir -p "$side"
    # Column 1 is the sentence id, 2 the file, 3 the reference as written.
    awk -F'\t' -v n="$SPEECH_COUNT" '!seen[$1]++ { print $2 "\t" $3; if (++k == n) exit }' "$table" > "$side.refs"
    # The archive holds dev/<file>; --strip-components=1 drops "dev/" (bsdtar and GNU tar alike).
    cut -f1 "$side.refs" | sed 's|^|dev/|' > "$side.list"
    if ! tar -xzf "$archive" -C "$side" --strip-components=1 -T "$side.list"; then
        rm -rf "$side" "$side.list" "$side.refs"
        echo "FAILED  speech/$lang: tar could not extract $archive" >&2
        return 1
    fi
    mv "$side.refs" "$side/refs.tsv"
    rm -f "$side.list"
    if ! speech_cache_whole "$side"; then
        rm -rf "$side"
        echo "FAILED  speech/$lang: files named in the table are missing from $archive" >&2
        return 1
    fi
    mv "$side" "$out"
    echo "get     speech/$lang ($(wc -l < "$out/refs.tsv" | tr -d ' ') recordings)"
}
if want_group speech; then
    extract_speech ru ru_ru
    extract_speech en en_us
fi

# Hashes of everything in the cache, pinned and rolling, for the model builder.
(
    cd "$CACHE"
    find . -type f ! -name '*.part' ! -name MANIFEST.sha256 | LC_ALL=C sort |
        while read -r f; do
            printf '%s  %s\n' "$(sha256_of "$f")" "${f#./}"
        done
) > "$CACHE/MANIFEST.sha256"
echo "wrote   $CACHE/MANIFEST.sha256"
