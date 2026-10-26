# SPDX-License-Identifier: GPL-3.0-or-later
"""Settings search index check, run by scripts/check-settings-index.sh."""
import glob
import re
import sys

INDEX = "Sources/Perekey/SettingsIndex.swift"
# Files whose rows are not in the Settings window.
SKIP = {"SettingsIndex.swift", "DebugSnapshot.swift", "DebugVoiceScenario.swift", "OnboardingView.swift", "ReportWordSheet.swift"}
# A row or a group title written as a literal. `Text(verbatim:)` and interpolations are dynamic: no entry.
TITLES = re.compile(
    r'(?:\bPKRow\(\s*|\bPKGroup\(\s*header:\s*|\b(?:correctionRow|soundRow)\(\s*)(?:Text|voiceText)\("((?:[^"\\]|\\.)*)"')
ENTRY = re.compile(r'\b(?:item|voiceItem)\(\.(\w+),\s*"((?:[^"\\]|\\.)*)",\s*"([^"]+)"(?:,\s*\.\w+)*\)')
SKIP_MARK = "search: skip"
# On an anchor's line: the title is a string of another file (TriggerText.swift names the shortcut rows).
ELSEWHERE_MARK = "search: title in"


def index_entries():
    src = open(INDEX, encoding="utf-8").read()
    return [(m.group(1), m.group(2), m.group(3)) for m in ENTRY.finditer(src)]


def main():
    entries = index_entries()
    if not entries:
        print(f"{INDEX}: no entries found")
        return 1
    keys = {key for _, key, _ in entries}
    anchors = [a for _, _, a in entries if a != "title"]
    prefixes = sorted({a.split(".")[0] for a in anchors})
    anchor_use = re.compile(r'"((?:%s)\.[a-z0-9-]+)"' % "|".join(prefixes))

    bad = 0
    counts = {}
    for a in anchors:
        counts[a] = counts.get(a, 0) + 1
    for a, n in sorted(counts.items()):
        if n > 1:
            bad += 1
            print(f"{INDEX}: anchor {a!r} is used by {n} entries")

    used = {}
    on_row = {}
    files = {}
    titles = 0
    text = ""
    for path in sorted(glob.glob("Sources/Perekey/**/*.swift", recursive=True)):
        if path.split("/")[-1] in SKIP:
            continue
        src = open(path, encoding="utf-8").read()
        text += src
        files[path] = src
        lines = src.split("\n")
        for m in TITLES.finditer(src):
            title = m.group(1)
            line = src.count("\n", 0, m.start())
            if "\\(" in title or SKIP_MARK in lines[line] or (line > 0 and SKIP_MARK in lines[line - 1]):
                continue
            titles += 1
            if title not in keys:
                bad += 1
                print(f"{path}:{line + 1}: \"{title}\" is not in {INDEX}; add it, or write `// {SKIP_MARK}` above")
        for m in anchor_use.finditer(src):
            used.setdefault(m.group(1), f"{path}:{src.count(chr(10), 0, m.start()) + 1}")
            line = lines[src.count("\n", 0, m.start())]
            on_row.setdefault(m.group(1), []).append((path, ELSEWHERE_MARK in line))

    for a in sorted(set(anchors) - used.keys()):
        bad += 1
        print(f"{INDEX}: anchor {a!r} is on no row or group")
    for a, where in sorted(used.items()):
        if a not in counts:
            bad += 1
            print(f"{where}: anchor {a!r} is not in {INDEX}")
    # The anchor sits in the file that has the row's title, not just anywhere.
    for _, key, anchor in entries:
        if anchor == "title":
            continue
        for path, elsewhere in on_row.get(anchor, []):
            if not elsewhere and f'"{key}"' not in files[path]:
                bad += 1
                print(f"{path}: anchor {anchor!r} is on a row, but \"{key}\" is not in this file")
    for key in sorted(keys):
        if f'"{key}"' not in text:
            bad += 1
            print(f"{INDEX}: \"{key}\" is the title of no row or group")

    print(f"{len(entries)} index entries, {titles} titles in Sources/Perekey, {bad} problems")
    return 1 if bad else 0


sys.exit(main())
