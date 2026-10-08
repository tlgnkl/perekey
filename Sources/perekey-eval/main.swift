// SPDX-License-Identifier: GPL-3.0-or-later
//
// Measures the classifier on the held-out corpus. scripts/eval.sh wraps it.
//
//   perekey-eval corpus --cache <dir> --code <dir> --out <file> [--words N] [--seed S]
//   perekey-eval run --model <file> --corpus <file> --layouts <dir>
//                    [--threshold T] [--sweep] [--errors N per category] [--json <file>]
//                    [--typo-score S] [--typo-margin M] [--typo-sweep]
//                    [--context-bonus B] [--context-decay D] [--context-sweep [--bonuses 3,4] [--decays 0,1]]
//   perekey-eval word --model <file> --layouts <dir> --text <word> --language ru|en
//                     [--previous ru,en,...]
//
// `word` explains one decision: both readings, their costs and ranks, typed
// in the word's own layout and in the other one, and what the typo corrector
// makes of the word in its own layout.
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
// `--context-sweep` runs the corpus over the weight of the previous word and
// how much each word before it counts (`Classifier.Options.contextBonus` and
// `contextDecay`), and prints false switches and the recall of prose and
// chat and of mixed text.

import Foundation
import PerekeyCore
import PerekeyModelKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("perekey-eval: \(message)\n".utf8))
    exit(2)
}

var arguments = CommandLine.arguments.dropFirst().makeIterator()
guard let command = arguments.next(), ["corpus", "run", "word"].contains(command) else {
    fail("usage: perekey-eval corpus|run|word ... (see the source header)")
}
var flags: [String: String] = [:]
while let argument = arguments.next() {
    guard argument.hasPrefix("--") else { fail("unexpected argument \(argument)") }
    if ["--sweep", "--typo-sweep", "--context-sweep"].contains(argument) {
        flags[argument] = "1"
    } else {
        flags[argument] = arguments.next() ?? ""
    }
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
    case "corpus":
        let cache = flags["--cache"] ?? ProcessInfo.processInfo.environment["PEREKEY_DATA_CACHE"] ?? ".build/data-cache"
        let code = flags["--code"] ?? "Sources"
        guard let out = flags["--out"] else { fail("--out is required") }
        let words = Int(flags["--words"] ?? "50000") ?? 50000
        let seed = UInt64(flags["--seed"] ?? "1") ?? 1
        let items = try Corpus.build(cache: cache, code: code, words: words, seed: seed)
        try Corpus.write(items, to: out)
        var counts: [String: Int] = [:]
        for item in items { counts[item.category, default: 0] += 1 }
        print("wrote \(out): \(items.count) words")
        for category in Corpus.categories { print(String(format: "  %-9@ %7d", category as NSString, counts[category] ?? 0)) }

    case "run":
        guard let modelPath = flags["--model"], let corpusPath = flags["--corpus"], let layouts = flags["--layouts"] else {
            fail("--model, --corpus and --layouts are required")
        }
        let model = try ModelFile.load(modelPath)
        let items = try Corpus.read(corpusPath)
        var options = Classifier.Options()
        if let threshold = flags["--threshold"].flatMap(Double.init) { options.threshold = threshold }
        if let bonus = flags["--context-bonus"].flatMap(Double.init) { options.contextBonus = bonus }
        if let decay = flags["--context-decay"].flatMap(Double.init) { options.contextDecay = decay }
        var typoOptions = TypoCorrector.Options()
        if let score = flags["--typo-score"].flatMap(Int.init) { typoOptions.minScore = score }
        if let margin = flags["--typo-margin"].flatMap(Int.init) { typoOptions.margin = margin }
        let evaluation = Evaluation(model: model, layouts: [
            "ru": layout("Russian", in: layouts), "en": layout("ABC", in: layouts),
        ], options: options, typoOptions: typoOptions)

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
            "typoScore": results.typoOptions.minScore,
            "typoMargin": results.typoOptions.margin,
            "wrongCorrectionRate": results.total.wrongCorrectionRate,
            "typosFixed": results.total.fixedShare,
            "categories": results.categories.map { category -> [String: Any] in
                ["name": category.name, "keepWords": category.keepWords, "falseSwitches": category.falseSwitches,
                 "switchWords": category.switchWords, "switches": category.switches,
                 "checkedWords": category.checkedWords, "wrongCorrections": category.wrongCorrections,
                 "typoWords": category.typoWords, "typosFixed": category.typosFixed]
            },
        ]
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
        /// One line of a context sweep: what the plan's targets look at.
        func sweepLine(_ label: String, _ point: Evaluation.Results) -> String {
            func recall(_ name: String) -> Double { point.categories.first { $0.name == name }?.recall ?? 0 }
            return String(format: "  %@  false %6.3f%%  prose+chat %6.2f%%  mixed %6.2f%%", label as NSString,
                          point.total.falseRate * 100, point.textRecall * 100, recall("mixed") * 100)
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

    case "word":
        guard let modelPath = flags["--model"], let layouts = flags["--layouts"], let text = flags["--text"],
              let language = flags["--language"], language == "ru" || language == "en"
        else { fail("--model, --layouts, --text and --language are required") }
        let model = try ModelFile.load(modelPath)
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
                + String(format: "score %.1f", decision.score) + " language \(decision.language ?? "-")")
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

    default:
        fail("unknown command \(command)")
    }
} catch {
    fail("\(error)")
}
