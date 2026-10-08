# SPDX-License-Identifier: GPL-3.0-or-later
"""Localization check, run by scripts/check-strings.sh."""
import glob
import plistlib
import re
import sys

LANGS = ["en", "ru"]
SKIP = {"DebugSnapshot.swift"}  # debug-only fixtures, never shown to users
OPENERS = re.compile(
    r'(?:String\(localized:\s*|LocalizedStringResource\(\s*|\b(?:Text|Label|Button|Section|Picker|TextField|Toggle)\(\s*'
    r'|\.(?:help|accessibilityLabel)\(\s*|\b(?:title|lead|text):\s*)"')


def read_literal(src, i):
    """src[i] is just after the opening quote. Returns (key, end); \\(…) becomes %@."""
    out = []
    while i < len(src):
        c = src[i]
        if c == "\\" and src[i + 1] == "(":
            depth, i = 1, i + 2
            while depth:
                depth += {"(": 1, ")": -1}.get(src[i], 0)
                i += 1
            out.append("%@")
        elif c == "\\":
            out.append({"n": "\n", "t": "\t"}.get(src[i + 1], src[i + 1]))
            i += 2
        elif c == '"':
            return "".join(out), i + 1
        else:
            out.append(c)
            i += 1
    raise SystemExit("unterminated string literal")


def source_keys():
    keys = {}
    paths = glob.glob("Sources/Perekey/**/*.swift", recursive=True) + glob.glob("Sources/PerekeyInput/*.swift")
    for path in sorted(paths):
        if path.split("/")[-1] in SKIP:
            continue
        src = open(path, encoding="utf-8").read()
        for m in OPENERS.finditer(src):
            key, _ = read_literal(src, m.end())
            if key:
                line = src.count("\n", 0, m.start()) + 1
                keys.setdefault(key, f"{path}:{line}")
    return keys


def norm(key):
    return re.sub(r"%(?:\d+\$)?(?:lld|ld|d|u|@|f)", "%@", key)


SPEC = re.compile(r"%(?:(\d+)\$)?[-+ 0#]*\d*(?:\.\d+)?(lld|ld|llu|lu|d|u|@|f|s|c|x)")


def specs(text):
    """The format specifiers of a string, as (position or None, type); %% is no specifier."""
    return [(int(m.group(1)) if m.group(1) else None, m.group(2)) for m in SPEC.finditer(text.replace("%%", ""))]


def spec_problem(key, value):
    """Why `value` cannot be formatted with the arguments `key` takes, or None.
    Same count and types; the order too, unless the value numbers its specifiers (%1$lld)."""
    want, have = [t for _, t in specs(key)], specs(value)
    if sorted(want) != sorted(t for _, t in have):
        return f"specifiers {[t for _, t in have]} do not match the key's {want}"
    if all(p is not None for p, _ in have):
        if any(p < 1 or p > len(want) or want[p - 1] != t for p, t in have):
            return f"positional specifiers {[(p, t) for p, t in have]} do not match the key's {want}"
    elif any(p is not None for p, _ in have):
        return "mixes positional and plain specifiers"
    elif [t for _, t in have] != want:
        return f"specifiers {[t for _, t in have]} are in another order than the key's {want}; number them (%1$@)"
    return None


def unescape(s):
    return re.sub(r"\\(.)", lambda m: {"n": "\n", "t": "\t"}.get(m.group(1), m.group(1)), s)


def file_keys(lang):
    pairs = {}
    try:
        text = open(f"Support/{lang}.lproj/Localizable.strings", encoding="utf-8").read()
    except FileNotFoundError:
        return pairs
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    for m in re.finditer(r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', text):
        pairs[unescape(m.group(1))] = unescape(m.group(2))
    for path in glob.glob(f"Support/{lang}.lproj/Localizable.stringsdict"):
        with open(path, "rb") as f:
            for key in plistlib.load(f):
                pairs.setdefault(key, key)
    return pairs


def check_stringsdict(lang):
    """Each plural entry: its variables' value types must be the key's specifiers; the formats
    inside (one, few, other…) must keep that one specifier."""
    bad = 0
    for path in glob.glob(f"Support/{lang}.lproj/Localizable.stringsdict"):
        with open(path, "rb") as f:
            entries = plistlib.load(f)
        for key, entry in entries.items():
            fmt = entry.get("NSStringLocalizedFormatKey", "")
            variables = [name for name in re.findall(r"%#@(\w+)@", fmt)]
            want = [t for _, t in specs(key)]
            got = []
            for name in variables:
                variable = entry.get(name, {})
                got.append(variable.get("NSStringFormatValueTypeKey", ""))
                for form, text in variable.items():
                    if form in ("one", "two", "few", "many", "other", "zero"):
                        inner = [t for _, t in specs(text)]
                        if len(inner) > 1:
                            bad += 1
                            print(f"{lang}: stringsdict {key!r}, {name}.{form}: more than one specifier")
            if sorted(want) != sorted(got):
                bad += 1
                print(f"{lang}: stringsdict {key!r}: the key takes {want} but the variables are {got}")
    return bad


def main():
    found = source_keys()
    if "--list" in sys.argv:
        for key, where in found.items():
            print(f"{where}\t{key}")
        return 0

    wanted = {norm(k): (k, w) for k, w in found.items()}
    bad = 0
    for lang in LANGS:
        have = file_keys(lang)
        have_n = {norm(k): k for k in have}
        for n, (k, where) in wanted.items():
            if n not in have_n:
                bad += 1
                print(f"{lang}: missing key used at {where}\n  \"{k}\" = \"{k}\";")
        for n, k in have_n.items():
            if n not in wanted:
                bad += 1
                print(f"{lang}: unused key {k!r}")
        for k, v in have.items():
            problem = spec_problem(k, v)
            if problem:
                bad += 1
                print(f"{lang}: {k!r}: {problem}")
        bad += check_stringsdict(lang)
        if lang != LANGS[0]:
            first = {norm(k) for k in file_keys(LANGS[0])}
            for n, k in have_n.items():
                if n not in first:
                    bad += 1
                    print(f"{lang}: key {k!r} is not in {LANGS[0]}")
    print(f"{len(found)} strings found in Sources/Perekey, {len(LANGS)} languages, {bad} problems")
    return 1 if bad else 0


sys.exit(main())
