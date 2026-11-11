// SPDX-License-Identifier: GPL-3.0-or-later
//
// Measures the classifier on the held-out corpus. scripts/eval.sh wraps it.
//
//   perekey-eval corpus --cache <dir> --code <dir> --out <file> [--words N] [--seed S] [--pair en-uk|en-be|en-kk]
//                       [--real-word-items N --model <file or dir>]
//   perekey-eval run --model <file> --corpus <file> --layouts <dir> [--pair en-uk|en-be|en-kk [--uk-layout <name>]]
//                    [--threshold T] [--sweep] [--errors N per category] [--json <file>]
//                    [--typo-score S] [--typo-margin M] [--typo-sweep]
//                    [--typo-context W] [--typo-context-sweep [--typo-weights 0,0.25,...]]
//                    [--real-words [--real-word-lift B] [--real-word-slack S] [--real-word-margin B] [--real-word-no-ending] [--real-word-swaps-only]]
//                    [--real-word-sweep [--real-word-lifts 4,5,6,...] [--real-word-slacks 0,16,32,...]]
//                    [--context-bonus B] [--context-decay D] [--context-sweep [--bonuses 3,4] [--decays 0,1]]
//                    [--prior-scale S] [--prior-limit L] [--prior-sweep]
//   perekey-eval word --model <file> --layouts <dir> --text <word> --language ru|en
//                     [--previous ru,en,...]
//   perekey-eval coverage --model <file> --language <code> [--cache <dir>]
//   perekey-eval cyrillic --model <dir> --layouts <dir> [--cache <dir>] [--words N] [--margin M] [--languages ru,uk,be]
//                         [--margin-sweep]
//   perekey-eval slash --model <file> --layouts <dir> --tokens <file> [--lead] [--list N]
//   perekey-eval hyphen --model <file> [--cache <dir>] [--list N] [--text <file> [--text-name <name>]]
//                       [--layouts <dir> --words <hyphen.txt>]
//   perekey-eval pairs --model <file or dir> --language ru|en [--cache <dir>] [--wiki <file>]
//                      [--tsv <file> --budgets 2,4,8,16]
//   perekey-eval realword --model <file or dir> --language ru|en --layouts <dir> [--cache <dir>] [--wiki <file>]
//                         [--every K] [--list N] [--real-word-lift B] [--real-word-slack S] [--real-word-margin B]
//                         [--off]
//   perekey-eval cases|play|case|selfcheck ...: the quality bench (docs/eval.md, PerekeyEvalKit)
//   perekey-eval replay check|words|compare <.pksession files> --model <dir> [--json <file>] [--show-words]
//                       [--candidate-model <dir>] [--candidate-options <json or file>]
//   perekey-eval personal --model <dir> --layouts <dir> [--cache <dir>] [--names N] [--seed S] [--corpus <file>]
//                         [--personal-rank R] [--personal-rank-sweep] [--json <file>]
//
// `--pair en-uk` builds and runs the corpus of the English and Ukrainian
// pair (`Corpus.buildUkrainian`) on ABC and Ukrainian-PC, or the layout
// `--uk-layout` names; `en-be` and `en-kk` do the same for Belarusian
// (Byelorussian) and Kazakh (Corpus.buildSmallPair); without it, the pair is
// ru and en.
// `--model` is a model file or a directory of them (`<language>.pklm`);
// `run` and `word` map ru and en from a directory.
// `cyrillic` types Russian and Ukrainian words on ABC with both Cyrillic
// layouts installed and counts the words that land in the other Cyrillic
// language (`CyrillicChoice`); exit status 1 when, with context, that is
// 0.5 % or more. `--margin-sweep` repeats it over `Options.readingMargin`.
// `coverage` prints the share of Tatoeba tokens of one language that its
// model knows as word forms: for a language without a word-form dictionary
// (uk, data/SOURCES.md).
// `word` explains one decision: both readings, their costs and ranks, typed
// in the word's own layout and in the other one, and what the typo corrector
// makes of the word in its own layout.
// `slash` judges every part of tokens such as "доходы/расходы" or "XP/бейджи"
// (one per line) on its own, as automatic switching does when a "/" ends a
// part: each part typed in the layout of its script, and then each part alone
// typed in the other layout. It prints the parts that switch typed right and
// the share that switch typed wrong. As in the app, a part of one or two
// keys or with a capital past its first letter stops the cutting: it and the
// parts after it are not judged. Context is the parts before; `--lead`
// also puts the first part's language before the token, as a sentence would.
// `hyphen` measures the hyphen step on the Russian Tatoeba sentences
// (`HyphenEvaluation`): every word with a hyphen typed merged and typed
// with a space, how many come back, and every change of the clean text; `--list` prints the N most
// frequent hyphenated words not on the list (default 30). `--text` measures
// a plain text file the same way, one or more sentences per line (the
// Wikipedia shard, docs/corrections.md, «Дефис»). Both count by the shape
// of the word too: по-, -то, a word twice, a prefix, -ка, -таки. A change of the
// clean text is reported, not an error: the corpus has typos of its own.
// With `--layouts` and `--words` every word of the list, typed merged on the
// Russian layout, must stay as it is for the typo step (`TypoCorrector`),
// which runs before the hyphen step: exit status 1 for any that it changes.
// `pairs` measures the pair table of a model (docs/classifier.md, «Пары слов»)
// on text it never saw: of the pairs of neighbouring known words in Tatoeba
// prose and chat and in a held-out Wikipedia file (`--wiki`, one article per
// line, scripts/wiki-text.py --held-out), how many have a lift in the table
// and how large it is. With `--tsv` (the counts of `perekey-model pairs`) it
// repeats the measure for each section size of `--budgets` in megabytes, from
// the counts, without a model: the curve that picks the size.
// `replay` runs recorded typing sessions through `InputMachine`
// (`ReplayCommand`, docs/classifier.md, «Замер на живых сессиях»): `check`
// replays them exactly and names the first answer that differs from the
// recording (exit status 1); `words` prints the labelled words by outcome;
// `compare` where a candidate model or `Classifier.Options` decides
// otherwise. Typed words are printed only with `--show-words`.
// `personal` measures the personal lexicon (`PersonalEvaluation`,
// docs/classifier.md, «Личный словарь»): N GeoNames names the model does not
// know (default 200, half Cyrillic, half Latin) are typed and kept on a
// schedule of days through `PersonalLexiconModel`, then judged in both
// layouts with the lexicon empty and full; three kinds of poison are typed
// ten times over five days and must never be accepted. With `--corpus` the
// corpus is judged with the lexicon empty and full too, and no category may
// get worse. Exit status 1 for a false switch or a correction of a personal
// word, poison accepted or a category worse; recall under 90 % is reported.
// `--personal-rank-sweep` repeats it for `Classifier.Options.personalRank`
// 0, 80, 96 and 128.
// `corpus` writes a TSV of words by category (about N words, default 50 000,
// plus a tenth of typos).
// `run` types every word in its own layout and in the other one and prints
// false switches and recall per category; `--sweep` repeats it over a range
// of thresholds (the ROC points) and names the lowest threshold that meets the
// plan's targets. Exit status 1 when the targets are missed at the threshold
// in use: false switches ≥ 0.1 % of all words, or recall < 95 % on prose and
// chat (names and mixed text are reported but not gated).
// Typo correction is measured on the same run: wrong corrections of right
// words and the share of typos fixed, with `--typo-score` and `--typo-margin`
// as `TypoCorrector.Options`; `--typo-sweep` prints the points over both.
// Its targets (wrong < 0.1 % of words, fixed ≥ 60 %) are reported, not gated:
// the feature ships off until they are met.
// `--typo-context` sets `TypoCorrector.Options.contextWeight`, how much the
// lift of a candidate after the word before it counts (the corpus names that
// word; docs/corrections.md, «Опечатки с контекстом»); `--typo-context-sweep`
// prints the wrong corrections of every category and the typos fixed over
// the weights of `--typo-weights` (0 to 1.5 by default).
// `--real-words` lets the corrector replace a word of the dictionary too: one swap
// or one neighbouring key away, where the pair table likes the other word far more
// after the word before and does not know the typed pair (`TypoCorrector.Options.
// realWordLift`, docs/classifier.md, «Опечатки-слова»). `corpus --real-word-items N`
// adds the category `realword` (Tatoeba words typed as other words) to the corpus,
// after every other word, so a corpus without it is the corpus as it was.
// `realword` runs the corrector over clean text (Tatoeba, a held-out Wikipedia
// file) and counts the dictionary words it changes: all of them wrong.
// `--context-sweep` runs the corpus over the weight of the previous word and
// how much each word before it counts (`Classifier.Options.contextBonus` and
// `contextDecay`); `--prior-sweep` over the app prior's scale and limit. Both
// print false switches, recall of prose and chat, mixed, and apps.

import Foundation
import PerekeyCore
import PerekeyEvalKit
import PerekeyModelKit

// The quality bench (docs/eval.md): cases, play, case, selfcheck.
if let first = CommandLine.arguments.dropFirst().first, EvalCommands.names.contains(first) {
    exit(EvalCommands.run(Array(CommandLine.arguments.dropFirst())))
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("perekey-eval: \(message)\n".utf8))
    exit(2)
}

// `replay` takes files as well as flags: PerekeyModelKit's `ReplayCommand` parses its own.
if CommandLine.arguments.dropFirst().first == "replay" {
    exit(ReplayCommand.run(Array(CommandLine.arguments.dropFirst(2))) { print($0) })
}

var arguments = CommandLine.arguments.dropFirst().makeIterator()
guard let command = arguments.next(),
      ["corpus", "run", "word", "coverage", "cyrillic", "slash", "hyphen", "pairs", "realword", "personal"]
          .contains(command)
else {
    fail("usage: perekey-eval corpus|run|word|coverage|cyrillic|slash|hyphen|pairs|realword|personal|replay ... (see the source header)")
}
var flags: [String: String] = [:]
while let argument = arguments.next() {
    guard argument.hasPrefix("--") else { fail("unexpected argument \(argument)") }
    if ["--sweep", "--typo-sweep", "--typo-context-sweep", "--context-sweep", "--prior-sweep", "--margin-sweep",
        "--lead", "--real-words", "--real-word-sweep", "--off", "--real-word-no-ending", "--real-word-swaps-only",
        "--personal-rank-sweep"].contains(argument) {
        flags[argument] = "1"
    } else {
        flags[argument] = arguments.next() ?? ""
    }
}

/// The `--real-word-*` flags, parsed strictly: a wrong value stops the run, it never falls back to the default.
@MainActor func applyRealWordFlags(to typoOptions: inout TypoCorrector.Options) {
    if let text = flags["--real-word-lift"] {
        guard let lift = Double(text), lift.isFinite, lift >= 0 else {
            fail("--real-word-lift: \"\(text)\" is not a number of bits (0 up, e.g. 6)")
        }
        typoOptions.realWordLift = lift
    }
    if let text = flags["--real-word-slack"] {
        guard let slack = Int(text), slack >= 0 else { fail("--real-word-slack: \"\(text)\" is not a number (0 up)") }
        typoOptions.realWordSlack = slack
    }
    if flags["--real-word-no-ending"] != nil { typoOptions.realWordEnding = false }
    if flags["--real-word-swaps-only"] != nil { typoOptions.realWordKeys = false }
    if let text = flags["--real-word-margin"] {
        guard let margin = Double(text), margin.isFinite, margin >= 0 else {
            fail("--real-word-margin: \"\(text)\" is not a number of bits (0 up, e.g. 1)")
        }
        typoOptions.realWordMargin = margin
    }
}

/// The Cyrillic language of `--pair en-<code>`, nil for the ru ↔ en corpus.
var pairLanguage: String? {
    guard let pair = flags["--pair"], pair.hasPrefix("en-") else { return nil }
    return String(pair.dropFirst(3))
}

func layout(_ name: String, in directory: String) -> LayoutMap {
    let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).json")
    do {
        return try JSONDecoder().decode(LayoutMap.self, from: Data(contentsOf: url))
    } catch {
        fail("cannot read layout \(url.path): \(error)")
    }
}

do {
    switch command {
    case "personal":
        guard let modelPath = flags["--model"], let layouts = flags["--layouts"] else {
            fail("--model and --layouts are required")
        }
        let cache = flags["--cache"] ?? ProcessInfo.processInfo.environment["PEREKEY_DATA_CACHE"] ?? ".build/data-cache"
        let model = try ModelFile.load(modelPath, languages: ["ru", "en"])
        let seed = UInt64(flags["--seed"] ?? "1") ?? 1
        var options = Classifier.Options()
        if let text = flags["--personal-rank"] {
            guard let rank = UInt8(text) else { fail("--personal-rank: \"\(text)\" is not a rank 0…255") }
            options.personalRank = rank
        }
        let names = try PersonalEvaluation.names(cache: cache, model: model, options: options,
                                                 count: Int(flags["--names"] ?? "200") ?? 200, seed: seed)
        let corpus = try flags["--corpus"].map(Corpus.read)
        let evaluation = PersonalEvaluation(model: model, layouts: [
            "ru": layout("Russian", in: layouts), "en": layout("ABC", in: layouts),
        ], options: options, seed: seed)
        let results = try evaluation.run(names: names, cache: cache, corpus: corpus)
        print(PersonalEvaluation.report(results), terminator: "")
        var json = PersonalEvaluation.json(results)
        if flags["--personal-rank-sweep"] != nil {
            let points = try evaluation.sweep(ranks: [0, 80, 96, 128], names: names, cache: cache, corpus: corpus)
            print("\npersonal rank sweep: rank, accepted, recall, false switches, wrong corrections of accepted, "
                + "poison accepted, corpus: false switches, recall, wrong corrections")
            for point in points {
                let poison = point.poisons.reduce(0) { $0 + $1.accepted }
                let corpus = point.corpus.map { corpus in
                    String(format: "  %6.3f%%  %6.2f%%  %6.3f%%", corpus.full.total.falseRate * 100,
                           corpus.full.total.recall * 100, corpus.full.total.wrongCorrectionRate * 100)
                } ?? ""
                print(String(format: "  %3d  %4d  %6.2f%%  %3d  %3d  %3d", Int(point.personalRank), point.accepted,
                             point.recall * 100, point.full.all.falseSwitches, point.full.accepted.wrongCorrections,
                             poison) + corpus)
            }
            json["sweep"] = points.map(PersonalEvaluation.json)
        }
        if let path = flags["--json"] {
            try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: path))
        }
        if !results.failures.isEmpty { exit(1) }

    case "corpus":
        let cache = flags["--cache"] ?? ProcessInfo.processInfo.environment["PEREKEY_DATA_CACHE"] ?? ".build/data-cache"
        let code = flags["--code"] ?? "Sources"
        guard let out = flags["--out"] else { fail("--out is required") }
        let words = Int(flags["--words"] ?? "50000") ?? 50000
        let seed = UInt64(flags["--seed"] ?? "1") ?? 1
        let items: [CorpusItem]
        switch pairLanguage {
        case "uk": items = try Corpus.buildUkrainian(cache: cache, words: words, seed: seed)
        case let language?: items = try Corpus.buildSmallPair(language: language, cache: cache, words: words, seed: seed)
        case nil:
            var realWords: (count: Int, isWord: (String, String) -> Bool)?
            if let text = flags["--real-word-items"] {
                guard let count = Int(text), count > 0, let modelPath = flags["--model"] else {
                    fail("--real-word-items needs a number above 0 and --model")
                }
                let model = try ModelFile.load(modelPath, languages: ["ru", "en"])
                realWords = (count, { language, word in
                    model.language(language)?.rank(of: ModelFormat.Fingerprint.of(word.unicodeScalars, folded: true)) != nil
                })
            }
            items = try Corpus.build(cache: cache, code: code, words: words, seed: seed, realWords: realWords)
        }
        try Corpus.write(items, to: out)
        var counts: [String: Int] = [:]
        for item in items { counts[item.category, default: 0] += 1 }
        print("wrote \(out): \(items.count) words")
        // `personal` comes from `perekey-eval personal`, never from here.
        for category in Corpus.categories where category != "personal" && (category != "realword" || counts[category] != nil) {
            print(String(format: "  %-9@ %7d", category as NSString, counts[category] ?? 0))
        }

    case "run":
        guard let modelPath = flags["--model"], let corpusPath = flags["--corpus"], let layouts = flags["--layouts"] else {
            fail("--model, --corpus and --layouts are required")
        }
        let cyrillicCode = pairLanguage ?? "ru"
        let model = try ModelFile.load(modelPath, languages: [cyrillicCode, "en"])
        let items = try Corpus.read(corpusPath)
        var options = Classifier.Options()
        if let threshold = flags["--threshold"].flatMap(Double.init) { options.threshold = threshold }
        if let bonus = flags["--context-bonus"].flatMap(Double.init) { options.contextBonus = bonus }
        if let decay = flags["--context-decay"].flatMap(Double.init) { options.contextDecay = decay }
        if let scale = flags["--prior-scale"].flatMap(Double.init) { options.priorScale = scale }
        if let limit = flags["--prior-limit"].flatMap(Double.init) { options.priorLimit = limit }
        var typoOptions = TypoCorrector.Options()
        if let score = flags["--typo-score"].flatMap(Int.init) { typoOptions.minScore = score }
        if let margin = flags["--typo-margin"].flatMap(Int.init) { typoOptions.margin = margin }
        if let text = flags["--typo-context"] {
            guard let weight = Double(text), weight.isFinite, weight >= 0 else {
                fail("--typo-context: \"\(text)\" is not a weight (a number from 0 up, e.g. 0.5)")
            }
            typoOptions.contextWeight = weight
        }
        applyRealWordFlags(to: &typoOptions)
        let cyrillic = (cyrillicCode, flags["--uk-layout"] ?? [
            "uk": "Ukrainian-PC", "be": "Byelorussian", "kk": "Kazakh",
        ][cyrillicCode] ?? "Russian")
        var evaluation = Evaluation(model: model, layouts: [
            cyrillic.0: layout(cyrillic.1, in: layouts), "en": layout("ABC", in: layouts),
        ], options: options, typoOptions: typoOptions)
        evaluation.realWords = flags["--real-words"] != nil

        let results = evaluation.run(items, maxErrors: Int(flags["--errors"] ?? "12") ?? 12)
        print(Evaluation.report(results))
        if !results.errors.isEmpty {
            print("examples of errors:")
            for error in results.errors {
                let expected = error.expectSwitch ? "switch" : "keep"
                var line = "  \(error.item.category) \(error.item.language) \"\(error.item.text)\" typed in \(error.typed): "
                if let correction = error.correction {
                    line += "corrected to \(correction)" + (error.item.expected.map { ", meant \($0)" } ?? "")
                } else {
                    line += "expected \(expected), got \(error.decision.verdict) \(error.decision.reason) "
                        + String(format: "%.1f", error.decision.score)
                }
                print(line)
            }
        }

        var json: [String: Any] = [
            "threshold": results.threshold,
            "falseRate": results.total.falseRate,
            "recall": results.total.recall,
            "textRecall": results.textRecall,
            "punctuationRecall": results.total.punctuationRecall,
            "typoScore": results.typoOptions.minScore,
            "typoMargin": results.typoOptions.margin,
            "wrongCorrectionRate": results.total.wrongCorrectionRate,
            "typosFixed": results.total.fixedShare,
            "categories": results.categories.map { category -> [String: Any] in
                var entry: [String: Any] = [
                    "name": category.name, "keepWords": category.keepWords, "falseSwitches": category.falseSwitches,
                    "switchWords": category.switchWords, "switches": category.switches,
                    "checkedWords": category.checkedWords, "wrongCorrections": category.wrongCorrections,
                    "typoWords": category.typoWords, "typosFixed": category.typosFixed,
                ]
                // Only the category of words that are words has these: a corpus without it writes the file it always wrote.
                if category.name == "realword" {
                    entry["realWordWords"] = category.realWordWords
                    entry["realWordsFixed"] = category.realWordsFixed
                    entry["realWordsWrong"] = category.realWordsWrong
                }
                if evaluation.realWords { entry["realWordChanges"] = category.realWordChanges }
                return entry
            },
        ]
        // Only a run that uses the word before says so: a run without it writes the file it always wrote.
        if typoOptions.contextWeight != 0 { json["typoContextWeight"] = typoOptions.contextWeight }
        if evaluation.realWords {
            json["realWords"] = true
            json["realWordLift"] = typoOptions.realWordLift
            json["realWordSlack"] = typoOptions.realWordSlack
            json["realWordMargin"] = typoOptions.realWordMargin
        }
        if flags["--real-word-sweep"] != nil {
            func list<T>(_ key: String, _ fallback: [T], _ parse: (Substring) -> T?) -> [T] {
                guard let text = flags[key] else { return fallback }
                return text.split(separator: ",").map { part in
                    guard let value = parse(part) else { fail("\(key): \"\(part)\" is not a number") }
                    return value
                }
            }
            let lifts = list("--real-word-lifts", [4.0, 5, 6, 7, 8, 9, 10, 12], { Double($0) })
            let slacks = list("--real-word-slacks", [0, 16, 32, 64], { Int($0) })
            let points = evaluation.realWordSweep(items, lifts: lifts, slacks: slacks)
            let names = ["prose", "chat", "mixed", "names", "code", "url", "password", "captcha", "typos", "apps"]
            print("\nreal word sweep: lift, slack, dictionary words changed per category ("
                + names.joined(separator: " ") + "), all, typos fixed, realword fixed / wrong")
            for point in points {
                let counts = names.map { name in
                    String(format: "%5d", point.categories.first { $0.name == name }?.realWordChanges ?? 0)
                }.joined(separator: " ")
                let category = point.categories.first { $0.name == "realword" }
                print(String(format: "  %5.1f %4d  %@ %6d  %6.2f%%  %6.2f%% / %d", point.typoOptions.realWordLift,
                             point.typoOptions.realWordSlack, counts as NSString, point.total.realWordChanges,
                             point.total.fixedShare * 100, (category?.realWordShare ?? 0) * 100,
                             category?.realWordsWrong ?? 0))
            }
            json["realWordSweep"] = points.map { point -> [String: Any] in
                ["lift": point.typoOptions.realWordLift, "slack": point.typoOptions.realWordSlack,
                 "typosFixed": point.total.fixedShare, "realWordChanges": point.total.realWordChanges,
                 "categories": point.categories.map { category -> [String: Any] in
                     ["name": category.name, "realWordChanges": category.realWordChanges,
                      "realWordWords": category.realWordWords, "realWordsFixed": category.realWordsFixed,
                      "realWordsWrong": category.realWordsWrong]
                 }]
            }
        }
        if flags["--typo-context-sweep"] != nil {
            let weights = flags["--typo-weights"].map { list in
                list.split(separator: ",").map { part in
                    guard let weight = Double(part), weight.isFinite, weight >= 0 else {
                        fail("--typo-weights: \"\(part)\" is not a weight (a number from 0 up, e.g. 0,0.5,1)")
                    }
                    return weight
                }
            } ?? [0, 0.25, 0.5, 0.75, 1, 1.25, 1.5]
            let points = evaluation.typoContextSweep(items, weights: weights)
            let names = ["prose", "chat", "mixed", "names", "code", "url", "password", "captcha", "typos", "apps"]
            print("\ntypo context sweep: weight, wrong corrections per category (" + names.joined(separator: " ")
                + "), all, rate, typos fixed")
            for point in points {
                let counts = names.map { name in
                    String(format: "%5d", point.categories.first { $0.name == name }?.wrongCorrections ?? 0)
                }.joined(separator: " ")
                print(String(format: "  %4.2f  %@ %6d  %7.3f%%  %6.2f%%", point.typoOptions.contextWeight,
                             counts as NSString, point.total.wrongCorrections, point.total.wrongCorrectionRate * 100,
                             point.total.fixedShare * 100))
            }
            json["typoContextSweep"] = points.map { point -> [String: Any] in
                ["weight": point.typoOptions.contextWeight, "wrongCorrectionRate": point.total.wrongCorrectionRate,
                 "typosFixed": point.total.fixedShare,
                 "categories": point.categories.map { category -> [String: Any] in
                     ["name": category.name, "wrongCorrections": category.wrongCorrections,
                      "typosFixed": category.typosFixed, "typoWords": category.typoWords]
                 }]
            }
        }
        if flags["--typo-sweep"] != nil {
            let scores = [48, 56, 64, 72, 80, 96, 112, 128]
            let margins = [16, 32, 40, 48, 56, 64]
            let points = evaluation.typoSweep(items, scores: scores, margins: margins)
            print("\ntypo sweep: minScore, margin, wrong corrections, typos fixed")
            var best: Evaluation.Results?
            for point in points {
                let total = point.total
                print(String(format: "  %3d  %3d  %7.3f%%  %6.2f%%", point.typoOptions.minScore, point.typoOptions.margin,
                             total.wrongCorrectionRate * 100, total.fixedShare * 100))
                if point.typoTargetsMet, best.map({ total.fixedShare > $0.total.fixedShare }) ?? true { best = point }
            }
            if let best {
                print(String(format: "most typos fixed within the targets: minScore %d, margin %d",
                             best.typoOptions.minScore, best.typoOptions.margin))
            } else {
                print("no point meets both typo targets (wrong corrections < 0.1 %, fixed ≥ 60 %)")
            }
            json["typoSweep"] = points.map {
                ["minScore": $0.typoOptions.minScore, "margin": $0.typoOptions.margin,
                 "wrongCorrectionRate": $0.total.wrongCorrectionRate, "typosFixed": $0.total.fixedShare]
            }
        }
        /// One line of a context or prior sweep: what the plan's targets look at.
        func sweepLine(_ label: String, _ point: Evaluation.Results) -> String {
            func recall(_ name: String) -> Double { point.categories.first { $0.name == name }?.recall ?? 0 }
            func falseRate(_ name: String) -> Double { point.categories.first { $0.name == name }?.falseRate ?? 0 }
            return String(format: "  %@  false %6.3f%%  prose+chat %6.2f%%  mixed %6.2f%%  apps %6.2f%% (false %6.3f%%)",
                          label as NSString, point.total.falseRate * 100, point.textRecall * 100,
                          recall("mixed") * 100, recall("apps") * 100, falseRate("apps") * 100)
        }
        if flags["--context-sweep"] != nil {
            func list(_ flag: String, _ fallback: [Double]) -> [Double] {
                flags[flag].map { $0.split(separator: ",").compactMap { Double($0) } } ?? fallback
            }
            let points = evaluation.contextSweep(items, bonuses: list("--bonuses", [3, 4, 5]),
                                                 decays: list("--decays", [0, 0.25, 0.5, 0.75, 1]))
            print("\ncontext sweep: bonus, decay")
            for point in points {
                print(sweepLine(String(format: "%3.1f  %4.2f", point.options.contextBonus, point.options.contextDecay),
                                point))
            }
            json["contextSweep"] = points.map {
                ["bonus": $0.options.contextBonus, "decay": $0.options.contextDecay, "falseRate": $0.total.falseRate,
                 "textRecall": $0.textRecall,
                 "categories": $0.categories.map { ["name": $0.name, "recall": $0.recall, "falseRate": $0.falseRate] }]
            }
        }
        if flags["--prior-sweep"] != nil {
            let points = evaluation.priorSweep(items, scales: [0, 0.5, 1, 1.5, 2], limits: [1, 2])
            print("\nprior sweep: scale, limit")
            for point in points {
                print(sweepLine(String(format: "%4.2f  %3.1f", point.options.priorScale, point.options.priorLimit),
                                point))
            }
            json["priorSweep"] = points.map {
                ["scale": $0.options.priorScale, "limit": $0.options.priorLimit, "falseRate": $0.total.falseRate,
                 "textRecall": $0.textRecall,
                 "categories": $0.categories.map { ["name": $0.name, "recall": $0.recall, "falseRate": $0.falseRate] }]
            }
        }
        if flags["--sweep"] != nil {
            let thresholds = stride(from: 0.0, through: 30.0, by: 1.0).map { $0 }
            let points = evaluation.sweep(items, thresholds: thresholds)
            print("\nROC sweep: threshold, false switches, recall")
            var best: Evaluation.Results?
            for point in points {
                let total = point.total
                print(String(format: "  %5.1f  %7.3f%%  %6.2f%% (prose+chat %6.2f%%)", point.threshold,
                             total.falseRate * 100, total.recall * 100, point.textRecall * 100))
                if best == nil, total.falseRate < 0.001, point.textRecall >= 0.95 { best = point }
            }
            if let best {
                print(String(format: "lowest threshold meeting the targets: %.1f", best.threshold))
            } else {
                print("no threshold meets both targets (false switches < 0.1 %, recall ≥ 95 %)")
            }
            json["sweep"] = points.map { ["threshold": $0.threshold, "falseRate": $0.total.falseRate, "recall": $0.total.recall] }
        }
        if let path = flags["--json"] {
            try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: path))
        }
        let total = results.total
        print(String(format: "typo correction: wrong corrections %.3f%% of words, %.2f%% of typos fixed: targets %@",
                     total.wrongCorrectionRate * 100, total.fixedShare * 100,
                     (results.typoTargetsMet ? "met" : "missed (wrong < 0.1 %, fixed ≥ 60 %)") as NSString))
        print(String(format: "false switches %.3f%% of all words, recall %.2f%% on prose and chat",
                     total.falseRate * 100, results.textRecall * 100))
        if total.falseRate >= 0.001 || results.textRecall < 0.95 {
            print("FAIL: targets are false switches < 0.1 % and recall ≥ 95 % on prose and chat")
            exit(1)
        }

    case "cyrillic":
        guard let modelPath = flags["--model"], let layouts = flags["--layouts"] else {
            fail("--model and --layouts are required")
        }
        let cache = flags["--cache"] ?? ProcessInfo.processInfo.environment["PEREKEY_DATA_CACHE"] ?? ".build/data-cache"
        let languages = (flags["--languages"] ?? "ru,uk").split(separator: ",").map(String.init)
        let model = try ModelFile.load(modelPath, languages: ["en"] + languages)
        let items = try CyrillicChoice.build(cache: cache, words: Int(flags["--words"] ?? "20000") ?? 20000, seed: 1,
                                             languages: languages)
        let abc = layout("ABC", in: layouts)
        let names = ["ru": "Russian", "uk": "Ukrainian-PC", "be": "Byelorussian"]
        var maps: [String: LayoutMap] = [:]
        for code in languages { maps[code] = layout(names[code] ?? code, in: layouts) }
        var options = Classifier.Options()
        if let margin = flags["--margin"].flatMap(Double.init) { options.readingMargin = margin }
        let margins = flags["--margin-sweep"] != nil ? Array(stride(from: 0.0, through: 30.0, by: 5.0))
            : [options.readingMargin]
        var met = true
        for margin in margins {
            options.readingMargin = margin
            let rows = CyrillicChoice.run(items, classifier: Classifier(model: model, options: options), abc: abc,
                                          layouts: maps, languages: languages)
            print("readingMargin \(margin)")
            print(CyrillicChoice.report(rows))
            met = met && CyrillicChoice.targetsMet(rows)
        }
        if flags["--margin-sweep"] == nil {
            print(CyrillicChoice.report(CyrillicChoice.recover(items, classifier: Classifier(model: model, options: options),
                                                              abc: abc, layouts: maps, languages: languages)))
        }
        if flags["--margin-sweep"] == nil, !met {
            print("FAIL: target is a wrong Cyrillic language < 0.5 % with context")
            exit(1)
        }

    case "coverage":
        guard let modelPath = flags["--model"], let code = flags["--language"] else {
            fail("--model and --language are required")
        }
        let cache = flags["--cache"] ?? ProcessInfo.processInfo.environment["PEREKEY_DATA_CACHE"] ?? ".build/data-cache"
        let model = try ModelFile.load(modelPath, languages: [code])
        guard let language = model.language(code) else { fail("no \(code) in \(modelPath)") }
        print(try Coverage.measure(language, cache: cache).report)

    case "hyphen":
        guard let modelPath = flags["--model"] else { fail("--model is required") }
        let cache = flags["--cache"] ?? ProcessInfo.processInfo.environment["PEREKEY_DATA_CACHE"] ?? ".build/data-cache"
        let model = try ModelFile.load(modelPath, languages: ["ru"])
        let result = try HyphenEvaluation.measure(model, cache: cache)
        print(result.report(list: Int(flags["--list"] ?? "30") ?? 30))
        if let text = flags["--text"] {
            let lines = try String(contentsOfFile: text, encoding: .utf8).split(separator: "\n")
            let other = HyphenEvaluation.measure(model, sentences: lines, name: flags["--text-name"] ?? text)
            print(other.report(list: Int(flags["--list"] ?? "30") ?? 30))
        }
        if let layouts = flags["--layouts"], let list = flags["--words"] {
            let words = try String(contentsOfFile: list, encoding: .utf8).split(separator: "\n")
                .map { $0.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                    .split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)[0]
                    .trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let clashes = HyphenEvaluation.typoClashes(words, model: model, layout: layout("Russian", in: layouts))
            print("typo step on the \(words.count) merged words of the list: \(clashes.count) changed")
            for clash in clashes { print("  typo: \(clash)") }
            if !clashes.isEmpty { exit(1) }
        }

    case "pairs":
        guard let modelPath = flags["--model"], let code = flags["--language"] else {
            fail("--model and --language are required")
        }
        let cache = flags["--cache"] ?? ProcessInfo.processInfo.environment["PEREKEY_DATA_CACHE"] ?? ".build/data-cache"
        let model = try ModelFile.load(modelPath, languages: [code])
        guard let language = model.language(code) else { fail("no \(code) in \(modelPath)") }
        let texts = try PairEvaluation.tatoeba(language: code, cache: cache)
        var corpora = [("Tatoeba prose", texts.prose), ("Tatoeba chat", texts.chat)]
        if let wiki = flags["--wiki"] {
            var articles: [String] = []
            try TextLines.forEach(path: wiki) { articles.append(String(decoding: $0, as: UTF8.self)) }
            corpora.append(("Wikipedia (held out)", articles))
        }
        let known = Classifier.Options().knownRank
        let isKnown: (UInt64) -> Bool = { fingerprint in
            language.rank(of: fingerprint).map { $0 == 0 || $0 >= known } ?? false
        }
        func report(_ title: String, _ lift: @escaping (UInt64, UInt64) -> UInt8?) {
            print(title)
            for (name, sentences) in corpora {
                print(PairEvaluation.measure(sentences, name: name, isKnown: isKnown, lift: lift).report)
            }
        }
        report("\(code) pairs, model \(modelPath): table \(language.hasPairTable ? "present" : "absent")") {
            language.pairLift(previous: $0, word: $1)
        }
        if let tsv = flags["--tsv"] {
            let table = try PairTable.read(tsv)
            for megabytes in (flags["--budgets"] ?? "2,4,8,16").split(separator: ",").compactMap({ Int($0) }) {
                let chosen = table.chosen(budget: megabytes << 20)
                var lifts: [UInt64: UInt8] = [:]
                for pair in chosen {
                    lifts[ModelFormat.pairKey(previous: pair.entry.previous, word: pair.entry.word)] = pair.lift
                }
                let size = ModelBuilder.pairSectionSize(count: chosen.count)
                report("\(code) pairs, counts \(tsv), budget \(megabytes) MB: \(chosen.count) of \(table.entries.count) pairs, section \(String(format: "%.2f", Double(size) / 1_048_576)) MB") {
                    lifts[ModelFormat.pairKey(previous: $0, word: $1)]
                }
            }
        }

    case "realword":
        guard let modelPath = flags["--model"], let code = flags["--language"], let layouts = flags["--layouts"],
              code == "ru" || code == "en"
        else { fail("--model, --language ru|en and --layouts are required") }
        let cache = flags["--cache"] ?? ProcessInfo.processInfo.environment["PEREKEY_DATA_CACHE"] ?? ".build/data-cache"
        let model = try ModelFile.load(modelPath, languages: [code])
        guard let language = model.language(code) else { fail("no \(code) in \(modelPath)") }
        var typoOptions = TypoCorrector.Options()
        applyRealWordFlags(to: &typoOptions)
        let corrector = TypoCorrector(model: model, options: typoOptions)
        let map = layout(code == "ru" ? "Russian" : "ABC", in: layouts)
        let realWords = flags["--off"] == nil
        let texts = try PairEvaluation.tatoeba(language: code, cache: cache)
        var corpora = [("Tatoeba prose", texts.prose), ("Tatoeba chat", texts.chat)]
        if let wiki = flags["--wiki"] {
            let every = flags["--every"].map { text in
                guard let n = Int(text), n >= 1 else { fail("--every: \"\(text)\" is not a number (1 up)") }
                return n
            } ?? 1
            var articles: [String] = []
            var index = 0
            try TextLines.forEach(path: wiki) { line in
                if index % every == 0 { articles.append(String(decoding: line, as: UTF8.self)) }
                index += 1
            }
            corpora.append(("Wikipedia (held out)" + (every > 1 ? ", every \(every)th article" : ""), articles))
        }
        print(String(format: "%@ words that are words: lift from %.1f bits, rank slack %d, margin %.1f bits, model %@, %@",
                     code as NSString, typoOptions.realWordLift, typoOptions.realWordSlack, typoOptions.realWordMargin,
                     modelPath as NSString, (realWords ? "on" : "off") as NSString))
        for (name, sentences) in corpora {
            let result = RealWordEvaluation.measure(sentences, name: name, corrector: corrector, layout: map,
                                                    language: language, realWords: realWords)
            print(result.report)
            for line in result.top(Int(flags["--list"] ?? "12") ?? 12) { print("      \(line)") }
        }

    case "word":
        guard let modelPath = flags["--model"], let layouts = flags["--layouts"], let text = flags["--text"],
              let language = flags["--language"], language == "ru" || language == "en"
        else { fail("--model, --layouts, --text and --language are required") }
        let model = try ModelFile.load(modelPath, languages: ["ru", "en"])
        let maps = ["ru": layout("Russian", in: layouts), "en": layout("ABC", in: layouts)]
        let own = maps[language]!
        let other = maps[language == "ru" ? "en" : "ru"]!
        let strokes = text.map { character -> KeyStroke in
            guard let stroke = own.stroke(for: character) else { fail("\(own.id) cannot type \(character)") }
            return stroke
        }
        let classifier = Classifier(model: model)
        let recent = flags["--previous"].map { list in
            RecentLanguages(list.split(separator: ",").map { $0 == "-" ? nil : String($0) })
        } ?? RecentLanguages()
        let context = Classifier.Context(recent: recent)
        for (typed, alternative) in [(own, other), (other, own)] {
            let reading = strokes.map { typed.text(for: $0) ?? "?" }.joined()
            let decision = classifier.classify(strokes, typed: typed, other: alternative, context: context)
            print("typed in \(typed.id): \"\(reading)\" -> \(decision.verdict) \(decision.reason) "
                + String(format: "score %.1f", decision.score) + " language \(decision.language ?? "-")"
                + (decision.punctuationKeys > 0 ? ", last \(decision.punctuationKeys) key(s) kept as marks" : ""))
            // A switch inside the word (`WordJudge.insideWord`) comes before the word's end.
            if let early = [3, 4].first(where: {
                strokes.count > $0 && classifier.impossiblePrefix(strokes.prefix($0), typed: typed, other: alternative)
            }) {
                print("  switches inside the word after \(early) keys")
            }
            for (map, code) in [(typed, typed.language!), (alternative, alternative.language!)] {
                let word = strokes.map { map.text(for: $0) ?? "?" }.joined()
                guard let table = model.language(code) else { continue }
                let letters = word.unicodeScalars.filter { table.isLetter($0.value) }.map { table.symbol($0.value) }
                let cost = letters.withUnsafeBufferPointer { table.cost($0) }
                let rank = table.rank(of: ModelFormat.Fingerprint.of(word.unicodeScalars, folded: true))
                print(String(format: "  %@ \"%@\": cost %.1f bits, rank %@", code as NSString, word as NSString, cost,
                             rank.map(String.init) ?? "-"))
            }
        }
        let corrector = TypoCorrector(model: model)
        let fix = corrector.correct(strokes, in: own, sentenceStart: flags["--previous"] == nil)
        print("typo correction in \(own.id): " + (fix.map { "\($0.text) (rank \($0.rank))" } ?? "-"))

    case "slash":
        guard let modelPath = flags["--model"], let layouts = flags["--layouts"], let tokensPath = flags["--tokens"]
        else { fail("--model, --layouts and --tokens are required") }
        let model = try ModelFile.load(modelPath, languages: ["ru", "en"])
        let maps = ["ru": layout("Russian", in: layouts), "en": layout("ABC", in: layouts)]
        let classifier = Classifier(model: model)
        let lead = flags["--lead"] != nil
        var tokens = 0, skipped = 0, parts = 0, falseSwitches = 0, brokenTokens = 0, wrongParts = 0, fixed = 0
        var falseList: [String] = []
        var missedList: [String] = []
        for token in try String(contentsOfFile: tokensPath, encoding: .utf8).split(separator: "\n") {
            let words = token.split(separator: "/").map(String.init)
            let languages = words.map { word in
                word.unicodeScalars.contains { (0x400...0x4FF).contains($0.value) } ? "ru" : "en"
            }
            var strokes: [[KeyStroke]] = []
            for (word, language) in zip(words, languages) {
                let typed = word.compactMap { maps[language]!.stroke(for: $0) }
                guard typed.count == word.count else { break }
                strokes.append(typed)
            }
            guard strokes.count == words.count, !words.isEmpty else {
                skipped += 1
                continue
            }
            tokens += 1
            var broken = false
            // A part with a capital past its first letter is not judged at its
            // "/" (it may be a password), and the token stays whole from there:
            // the parts after it are not judged on their own either.
            let judgedParts = (words.indices.first { index in
                index < words.count - 1
                    && (words[index].count < 3 || words[index].dropFirst().contains(where: \.isUppercase))
            }).map { words.indices.prefix($0) } ?? words.indices[...]
            for index in judgedParts {
                var before = languages[..<index].reversed().map { Optional($0) }
                if lead { before.append(languages[0]) }
                let context = Classifier.Context(recent: RecentLanguages(before))
                let own = maps[languages[index]]!
                let other = maps[languages[index] == "ru" ? "en" : "ru"]!
                parts += 1
                let right = classifier.classify(strokes[index], typed: own, other: other, context: context)
                if case .switch = right.verdict {
                    falseSwitches += 1
                    broken = true
                    falseList.append("\(token) [\(words[index])] \(right.reason)")
                }
                // This part typed in the other layout, the others right.
                guard strokes[index].allSatisfy({ other.text(for: $0) != nil }) else { continue }
                wrongParts += 1
                let wrong = classifier.classify(strokes[index], typed: other, other: own, context: context)
                if wrong.verdict == .switch(to: own.id) {
                    fixed += 1
                } else {
                    let reading = strokes[index].map { other.text(for: $0) ?? "?" }.joined()
                    missedList.append("\(token) [\(reading)] \(wrong.verdict) \(wrong.reason)")
                }
            }
            if broken { brokenTokens += 1 }
        }
        print("tokens \(tokens) (skipped \(skipped)), parts \(parts)")
        print(String(format: "false switches: %d parts (%.3f %%), %d tokens (%.3f %%)", falseSwitches,
                     100 * Double(falseSwitches) / Double(max(parts, 1)), brokenTokens,
                     100 * Double(brokenTokens) / Double(max(tokens, 1))))
        print(String(format: "fixed: %d of %d parts typed in the other layout (%.1f %%)", fixed, wrongParts,
                     100 * Double(fixed) / Double(max(wrongParts, 1))))
        let limit = Int(flags["--list"] ?? "0") ?? 0
        if limit > 0 {
            print("-- false switches")
            for line in falseList.prefix(limit) { print("  \(line)") }
            print("-- missed")
            for line in missedList.prefix(limit) { print("  \(line)") }
        }

    default:
        fail("unknown command \(command)")
    }
} catch {
    fail("\(error)")
}
