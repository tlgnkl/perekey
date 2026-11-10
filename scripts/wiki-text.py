#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Writes the text of the Wikipedia training files as plain text, an article to a line.

Usage: scripts/wiki-text.py [--cache <dir>] [--held-out] ru en

The training text of the word pairs (data/SOURCES.md, group `pairs` of
scripts/fetch-data.sh) is in parquet, which only Python reads here. This script
takes the column `text` of every <cache>/wikipedia-pairs/<lang>/*.parquet, in
the order of the file names, and writes <cache>/pairs/<lang>.txt: one article
per line, a tab where a paragraph ends (the pair counts end a sentence there),
nothing else changed. With --held-out it reads the held-out files of the group
`text` (<cache>/wikipedia/<lang>) instead and writes <cache>/pairs/<lang>.heldout.txt,
the text `perekey-eval pairs --wiki` measures on. It counts no words: `perekey-model pairs` does, so
the parsing of words has one source (docs/classifier.md, «Пары слов»).
The same parquet files give the same bytes.

Needs pyarrow (preparation step only, not the app), pinned with hashes in
scripts/wiki-freq.requirements.txt; scripts/build-pairs.sh installs it into
.build/venv with pip --require-hashes.
"""
import argparse
import glob
import os
import re
import sys

import pyarrow.parquet as pq

# A line end or another control character inside an article is a paragraph break.
BREAKS = re.compile("[\x00-\x1f\x7f\x85\u2028\u2029]+")


def article_line(text):
    return BREAKS.sub("\t", text.strip()).strip("\t")


def write_text(files, path):
    articles = 0
    os.makedirs(os.path.dirname(path), exist_ok=True)
    part = path + ".part"
    try:
        with open(part, "w", encoding="utf-8", newline="\n") as out:
            for source in files:
                for batch in pq.ParquetFile(source).iter_batches(columns=["text"], batch_size=1000):
                    for text in batch.column("text").to_pylist():
                        line = article_line(text or "")
                        if line:
                            out.write(line + "\n")
                            articles += 1
        os.replace(part, path)
    finally:
        # After a failure (not after the replace) the half-written file goes away.
        if os.path.exists(part):
            os.remove(part)
    return articles


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache", default=os.environ.get("PEREKEY_DATA_CACHE", ".build/data-cache"))
    parser.add_argument("--held-out", action="store_true")
    parser.add_argument("languages", nargs="+", choices=["ru", "en"])
    args = parser.parse_args()
    for language in args.languages:
        directory = "wikipedia" if args.held_out else "wikipedia-pairs"
        files = sorted(glob.glob(f"{args.cache}/{directory}/{language}/*.parquet"))
        if not files:
            sys.exit(f"wiki-text: no files in {args.cache}/{directory}/{language}; "
                     f"run scripts/fetch-data.sh {'text' if args.held_out else 'pairs'}")
        path = f"{args.cache}/pairs/{language}.{'heldout.' if args.held_out else ''}txt"
        articles = write_text(files, path)
        print(f"{language}: {articles} articles from {len(files)} files -> {path}")


if __name__ == "__main__":
    main()
