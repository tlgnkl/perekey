#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Counts the words of the Wikipedia snapshot of a language into a wordfreq list.

Usage: scripts/wiki-freq.py [--cache <dir>] [--min-count N] be kk

wordfreq 3.2 has no Belarusian or Kazakh (data/SOURCES.md), so their
frequencies come from the pinned Wikipedia snapshot that scripts/fetch-data.sh
downloads (group `text`). The output is <cache>/wikifreq/large_<lang>.msgpack.gz
in the wordfreq "cB" format: perekey-model reads it as it reads wordfreq's
files. Deterministic: the same parquet files give the same bytes.

Needs pyarrow and msgpack (preparation step only, not the app):
    python3 -m venv .build/venv && .build/venv/bin/pip install pyarrow msgpack
"""
import argparse
import glob
import gzip
import math
import os
import re
import sys
import unicodedata
from collections import Counter

import msgpack
import pyarrow.parquet as pq

# Letters of each language: the alphabet of ModelBuild.alphabets without the joiners.
ALPHABETS = {
    "be": "абвгдеёжзійклмнопрстуўфхцчшыьэюя",
    "kk": "абвгғдеёжзийкқлмнңоөпрстуұүфхһцчшщъыіьэюяә",
}
# Apostrophes inside a word count as `'` ("аб'ём").
APOSTROPHES = "'’ʼ"
WORD = re.compile(r"[^\W\d_]+(?:[%s\-][^\W\d_]+)*" % APOSTROPHES)


def count_words(files, letters):
    allowed = set(letters) | {"'", "-"}
    counts = Counter()
    total = 0
    for path in files:
        for batch in pq.ParquetFile(path).iter_batches(columns=["text"], batch_size=1000):
            for text in batch.column("text").to_pylist():
                for token in WORD.findall(unicodedata.normalize("NFC", text).lower()):
                    total += 1
                    for mark in APOSTROPHES[1:]:
                        token = token.replace(mark, "'")
                    if all(c in allowed for c in token):
                        counts[token] += 1
    return counts, total


def write_list(counts, total, min_count, path):
    """Bucket i holds the words of frequency 10^(-i/100); Zipf = 9 - i/100."""
    buckets = {}
    for word, count in counts.items():
        if count < min_count:
            continue
        zipf = math.log10(count * 1e9 / total)
        buckets.setdefault(round((9 - zipf) * 100), []).append(word)
    last = max(buckets)
    lists = [[{"format": "cB", "version": 1}]] + [sorted(buckets.get(i, [])) for i in range(1, last + 1)]
    packed = msgpack.packb([lists[0][0]] + lists[1:], use_bin_type=True)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as raw, gzip.GzipFile(fileobj=raw, mode="wb", mtime=0, compresslevel=9) as out:
        out.write(packed)
    return sum(len(b) for b in lists[1:])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache", default=os.environ.get("PEREKEY_DATA_CACHE", ".build/data-cache"))
    parser.add_argument("--min-count", type=int, default=3)
    parser.add_argument("languages", nargs="+", choices=sorted(ALPHABETS))
    args = parser.parse_args()
    for language in args.languages:
        files = sorted(glob.glob(f"{args.cache}/wikipedia/{language}/*.parquet"))
        if not files:
            sys.exit(f"wiki-freq: no Wikipedia files for {language} in {args.cache}; run scripts/fetch-data.sh text")
        counts, total = count_words(files, ALPHABETS[language])
        path = f"{args.cache}/wikifreq/large_{language}.msgpack.gz"
        words = write_list(counts, total, args.min_count, path)
        print(f"{language}: {total} tokens, {len(counts)} distinct in the alphabet, {words} kept (count >= {args.min_count}) -> {path}")


if __name__ == "__main__":
    main()
