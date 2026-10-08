// SPDX-License-Identifier: GPL-3.0-or-later
//
// Measures the classifier on the held-out corpus. scripts/eval.sh wraps it.
//
//   perekey-eval corpus --cache <dir> --code <dir> --out <file> [--words N] [--seed S]
//   perekey-eval run --model <file> --corpus <file> --layouts <dir>
//                    [--threshold T] [--sweep] [--errors N per category] [--json <file>]
//   perekey-eval word --model <file> --layouts <dir> --text <word> --language ru|en
//                     [--previous ru|en]
//
// `word` explains one decision: both readings, their costs and ranks, typed
// in the word's own layout and in the other one.
// `corpus` writes a TSV of words by category (about N words, default 50 000).
// `run` types every word in its own layout and in the other one and prints
// false switches and recall per category; `--sweep` repeats it over a range
// of thresholds (the ROC points) and names the lowest threshold that meets the
// plan's targets. Exit status 1 when the targets are missed at the threshold
// in use: false switches ≥ 0.1 % or recall < 95 %.

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
    if argument == "--sweep" {
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
        let evaluation = Evaluation(model: model, layouts: [
            "ru": layout("Russian", in: layouts), "en": layout("ABC", in: layouts),
        ], options: options)

        let results = evaluation.run(items, maxErrors: Int(flags["--errors"] ?? "12") ?? 12)
        print(Evaluation.report(results))
        if !results.errors.isEmpty {
            print("examples of errors:")
            for error in results.errors {
                let expected = error.expectSwitch ? "switch" : "keep"
                print("  \(error.item.category) \(error.item.language) \"\(error.item.text)\" typed in \(error.typed): "
                    + "expected \(expected), got \(error.decision.verdict) \(error.decision.reason) "
                    + String(format: "%.1f", error.decision.score))
            }
        }

        var json: [String: Any] = [
            "threshold": results.threshold,
            "falseRate": results.total.falseRate,
            "recall": results.total.recall,
            "categories": results.categories.map { category -> [String: Any] in
                ["name": category.name, "keepWords": category.keepWords, "falseSwitches": category.falseSwitches,
                 "switchWords": category.switchWords, "switches": category.switches]
            },
        ]
        if flags["--sweep"] != nil {
            let thresholds = stride(from: 0.0, through: 30.0, by: 1.0).map { $0 }
            let points = evaluation.sweep(items, thresholds: thresholds)
            print("\nROC sweep: threshold, false switches, recall")
            var best: Evaluation.Results?
            for point in points {
                let total = point.total
                print(String(format: "  %5.1f  %7.3f%%  %6.2f%%", point.threshold, total.falseRate * 100, total.recall * 100))
                if best == nil, total.falseRate < 0.001, total.recall >= 0.95 { best = point }
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
        if total.falseRate >= 0.001 || total.recall < 0.95 {
            print("FAIL: targets are false switches < 0.1 % and recall ≥ 95 %")
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
        let context = Classifier.Context(previousLanguage: flags["--previous"])
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

    default:
        fail("unknown command \(command)")
    }
} catch {
    fail("\(error)")
}
