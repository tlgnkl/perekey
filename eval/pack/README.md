# {{name}}

A set of typing cases for keyboard layout switchers: what a person's fingers do, and the text the person meant.
It is made by the quality bench of [Perekey](https://github.com/tlgnkl/perekey) (`perekey-eval`, `docs/eval.md`
in its repository), tier `{{tier}}`. Any switcher can be measured with it: a case is played on the subject, and
only the final text of the field is scored.

The pack holds the cases and nothing else: no program, no model, no text of the sources apart from the sentences
and words the cases are made of. The text of each case is under the license of its source, not under one license
for the whole pack: `ATTRIBUTION.md` names every source and its license, and for Stack Exchange `attribution-se.tsv`
gives the post, its author and its license, one row for each post. `LICENSE` (CC BY-SA 4.0) is for our annotation
only: the choice of the cases, the scenarios, the tokens and the marks. What the pack was made of, with the SHA-256
of every source file: `pack.json`.

## Contents

```
{{name}}/
  cases/<set>.jsonl     the cases, one line each
  pack.json             counts, hashes of the cases, of the source files and of the layouts
  ATTRIBUTION.md        sources, their licenses, how to find the authors
  attribution-se.tsv    one row for each Stack Exchange post: id, type, site, link, author, license
                        (only in a pack that holds such posts)
  LICENSE               CC BY-SA 4.0, for our annotation (not for the text of the sources)
  README.md             this file
```

{{contents}}
A set is cases of one origin and one class. The share of `dev` is set for each set (the columns above); `test` is
the rest. A unit is a sentence or a word, and all scenarios of a unit are in one part.

## Play

```
tar -xf {{file}}
perekey-eval play --cases {{name}}/cases --model <model directory> --layouts <layouts> --out run
perekey-eval report run
```

`--layouts` is the directory of the layout snapshots the cases are typed on (`eval/layouts` of Perekey). The hashes
of the files the pack was made with are in `pack.json` (`layouts`). `play` needs no data cache and no lexicon; with
`--cache` and `--lexicon` it also marks disputed and silent results. Without `--model`, `--system null` plays the
cases on a field with no switcher (the baseline) and `--system oracle` on a perfect one.

Words of the `test` part are not printed by the reports; `--reveal-test` prints them, and the report then says so.
Use `dev` to look at examples and `test` for numbers you publish.

## The case

One line of a `.jsonl` file is one case: UTF-8, keys sorted, no spaces (so that the bytes are stable).

| Field | Meaning |
|---|---|
| `v` | Format version, `1` |
| `id` | `<set>/<scenario>/<12 hex>`, a hash of the content of the case |
| `suite`, `scenario`, `split`, `epoch` | The set; the scenario (below); `dev` or `test`; the number of the sample |
| `layouts`, `start` | The layouts installed, in the order of the system; the one active at the start |
| `env` | The program, the mode and the settings the case runs with (`app`, `mode`, `settings`, `field`, `pace`, `lag`, …) |
| `warmup` | Steps before the measured part; their tokens are not counted |
| `script` | The steps of the person: `type` (press the keys that type this text **in layout** `on`; the active layout may be another one: that is the error), `layout` (the person chooses a layout), `hotkey`, `key`, `click`, `focus`, `mode`, `capsLock`, `select`, `wait`, `pace`, `undo` |
| `want` | The text the person meant, whole, with the `warmup` |
| `tokens` | One object for each token of the measured part: `t` (text), `lang`, `err` (the error the maker put in: `none`, `layout`, `typo`, `caps`, `doublecap`, `hyphen`, `yo`, `abbrev`), `accept` (other correct forms), `tags`, `w` (weight) |

Scenarios of the corpus sets: `clean.cold` and `clean.warm` (the layout is right; harm of a switcher that
changes it), `slip.cold` and `slip.warm` (the person types in the wrong layout, with no context or after a sentence
of the other language), `stuck` (the person never changes the layout), `clean.toggle` (the person changes the
layout with a key). Correction sets: `fix`, `fix.merged`, `fix.spaced`, `keep`.

## The score

The score reads only the case and the final text. A **token** is a piece of text between whitespace. The bench aligns
the tokens of the output with the tokens of `want` (a merge or a split costs less than a miss), and compares every
token with the same token typed with **no switcher** (Null, a field that prints the keys in the active layout):

| Null | Subject | Outcome |
|---|---|---|
| right | right | `ok` |
| right | wrong | `harm`: the switcher spoiled a right word |
| wrong | right | `fixed`: the error of the person is gone |
| wrong | wrong, same output | `miss`: the error stayed |
| wrong | wrong, other output | `botched`: a wrong word became another wrong word |

`disputed` stands instead of `harm` in the corpus sets when the switcher corrected a typo of the source text (the
word of `want` is not in the lexicon, the output is, and they differ by one edit); it needs the lexicon.
`spill` is a token of `warmup` that came out wrong. A case is `exact` when all tokens are right.

Rates are per 1000 words (tokens with at least one letter): harm = `harm` / words; miss of the layout = `miss` of
tokens with `err: layout` / those tokens; remainder = wrong tokens of the subject / words. Intervals are
Wilson's at 95 %. The full definitions, with the alignment and the profiles, are in `docs/eval.md` of Perekey.

## Reproducing the pack

`perekey-eval cases pack --tier {{tier}} --out {{file}}` builds this archive from the sources named in `pack.json`.
The archive is deterministic: the same sources give the same tar, and with the same version of zstd the same
`.tar.zst`. The `.tar.zst` of this pack was made with zstd {{zstd}} (level 19, one thread); another version may
give other bytes of the archive from the same tar. The SHA-256 of the uncompressed tar does not depend on zstd: the
command prints it and writes it beside the archive (`<file>.tar.sha256`; it cannot be inside the tar), and
`zstd -dc {{file}} | shasum -a 256` gives the same value.
