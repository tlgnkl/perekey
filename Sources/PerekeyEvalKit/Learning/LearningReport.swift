// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The files and the text of `perekey-eval learning` (docs/eval.md, «Обучение»).
enum LearningReport {
    struct Entry: Codable {
        var name: String
        var manifest: String
        var vocabularySHA256: String
        /// One run per seed, the manifest's seed first.
        var runs: [LearningRun]
    }

    struct Document: Codable {
        var commit: String
        var models: [String: String]
        var options: String?
        var seeds: Int
        var sets: [Entry]
    }

    /// `learning.json`, `days.tsv`, `words.tsv`. Sorted keys: two runs give the same bytes.
    static func write(_ document: Document, to directory: String) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(document).write(to: URL(fileURLWithPath: directory + "/learning.json"))
        var days = ["set\tseed\tday\tmessages\tkeep\tother\tharmed\tundoneByBackspace\tundoneByButton\tconverted\taccidents\tleftWrong\tcounted\tasked\tlearned\tunlearned"]
        var words = ["set\tseed\tword\tlayout\tkeep\tother\tharmed\tkeepInterventions\totherInterventions\tlearnedDay\tunlearned\tneededAfterLearned\tsilent"]
        for entry in document.sets {
            for (seed, run) in entry.runs.enumerated() {
                for d in run.days {
                    days.append([entry.name, "\(seed)", "\(d.day + 1)", "\(d.messages)", "\(d.keep)", "\(d.other)", "\(d.harmed)",
                                 "\(d.undoneByBackspace)", "\(d.undoneByButton)", "\(d.converted)", "\(d.accidents)",
                                 "\(d.leftWrong)", "\(d.counted)", "\(d.asked)", "\(d.learned)", "\(d.unlearned)"]
                            .joined(separator: "\t"))
                }
                for w in run.words {
                    words.append([entry.name, "\(seed)", w.word, w.layout, "\(w.keep)", "\(w.other)", "\(w.harmed)",
                                  "\(w.keepInterventions)", "\(w.otherInterventions)", w.learnedDay.map { "\($0 + 1)" } ?? "-",
                                  "\(w.unlearned)", "\(w.neededAfterLearned)", w.silent.map { $0 ? "yes" : "no" } ?? "-"]
                            .joined(separator: "\t"))
                }
            }
        }
        try (days.joined(separator: "\n") + "\n").write(toFile: directory + "/days.tsv", atomically: true, encoding: .utf8)
        try (words.joined(separator: "\n") + "\n").write(toFile: directory + "/words.tsv", atomically: true, encoding: .utf8)
    }

    // MARK: - Text

    static func number(_ value: Double?, _ digits: Int = 1) -> String {
        value.map { String(format: "%.\(digits)f", $0) } ?? "-"
    }

    static func mean(_ runs: [LearningRun], _ value: (LearningRun.Totals) -> Double?) -> Double? {
        let values = runs.compactMap { value($0.totals) }
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    static func text(_ manifest: LearningManifest, runs: [LearningRun]) -> String {
        var lines = ["\(manifest.name): \(manifest.days) days, \(manifest.messagesPerDay) messages a day, "
            + "\(runs.count) seed\(runs.count == 1 ? "" : "s") from \(manifest.seed); mean over seeds"]
        func line(_ label: String, _ value: String) { lines.append("  " + label.padding(toLength: 54, withPad: " ", startingAt: 0) + value) }
        line("tokens (meant as typed / the other reading)",
             "\(number(mean(runs) { Double($0.keep) }, 0)) / \(number(mean(runs) { Double($0.other) }, 0))")
        line("keep tokens Perekey corrected", number(mean(runs) { Double($0.harmed) }, 1))
        line("interventions by hand, day 1", number(mean(runs) { Double($0.interventionsDay1) }))
        line("interventions by hand, last day", number(mean(runs) { Double($0.interventionsLastDay) }))
        line("interventions by hand, all days", number(mean(runs) { Double($0.interventions) }))
        line("words harmed / of them silent at the end",
             "\(number(mean(runs) { Double($0.wordsHarmed) })) / \(number(mean(runs) { Double($0.wordsSilent) }))")
        line("interventions to silence per word", number(mean(runs) { $0.interventionsToSilence }, 2))
        line("questions asked", number(mean(runs) { Double($0.asked) }))
        line("words learned", number(mean(runs) { Double($0.learnedWords) }))
        line("words learned wrongly (never meant as typed)", number(mean(runs) { Double($0.falseLearned) }))
        line("accidental Backspaces", number(mean(runs) { Double($0.accidents) }, 0))
        line("learned wrongly per 1000 accidental Backspaces", number(mean(runs) { $0.falseLearnedPer1000Accidents }, 2))
        line("words learned, then needed a retype by hand", number(mean(runs) { Double($0.learnedThenNeeded) }))
        line("words the rule before evidence would have learned", number(mean(runs) { Double($0.oldRuleWouldLearn) }))
        line("tokens left wrong", number(mean(runs) { Double($0.leftWrong) }))
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Sweep

    /// The combinations of a grid `{"name": [values]}`, names in order. A name
    /// is a field of `LearningOptions` or `manifest.<share>` for a share of the
    /// manifest (`LearningManifest.overriding`); any other name is an error.
    static func points(grid json: String) throws -> [[(String, Double)]] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any], !object.isEmpty else {
            throw EvalError.input("--grid: not a JSON object: \(json)")
        }
        var axes: [(String, [Double])] = []
        for (name, value) in object.sorted(by: { $0.key < $1.key }) {
            guard LearningOptionsTable.table[name] != nil || LearningManifest.overridable.contains(name) else {
                throw EvalError.input("--grid: no field \(name); known: "
                    + (LearningOptionsTable.names + LearningManifest.overridable.sorted()).joined(separator: ", "))
            }
            guard let list = value as? [NSNumber], !list.isEmpty, list.allSatisfy({ CFGetTypeID($0) != CFBooleanGetTypeID() })
            else { throw EvalError.input("--grid: \(name) is not a list of numbers") }
            axes.append((name, list.map(\.doubleValue)))
        }
        var points: [[(String, Double)]] = [[]]
        for (name, values) in axes {
            points = points.flatMap { point in values.map { point + [(name, $0)] } }
        }
        return points
    }

    struct SweepRow {
        var point: [(String, Double)]
        var name: String
        var runs: [LearningRun]
    }

    static func sweepTable(_ rows: [SweepRow], seeds: Int) -> String {
        var lines = ["point\tset\tseeds\tday1\tlastDay\tallDays\ttoSilence\twordsHarmed\twordsSilent\tasked\tlearned\tfalseLearned\tfalsePer1000\tneeded\tleftWrong"]
        for row in rows {
            let point = row.point.map { "\($0.0)=\(Int($0.1) == Int(exactly: $0.1) ? "\(Int($0.1))" : "\($0.1)")" }.joined(separator: " ")
            let runs = row.runs
            let cells: [String] = [
                point.isEmpty ? "defaults" : point, row.name, "\(seeds)",
                number(mean(runs) { Double($0.interventionsDay1) }), number(mean(runs) { Double($0.interventionsLastDay) }),
                number(mean(runs) { Double($0.interventions) }), number(mean(runs) { $0.interventionsToSilence }, 2),
                number(mean(runs) { Double($0.wordsHarmed) }), number(mean(runs) { Double($0.wordsSilent) }),
                number(mean(runs) { Double($0.asked) }), number(mean(runs) { Double($0.learnedWords) }),
                number(mean(runs) { Double($0.falseLearned) }), number(mean(runs) { $0.falseLearnedPer1000Accidents }, 2),
                number(mean(runs) { Double($0.learnedThenNeeded) }), number(mean(runs) { Double($0.leftWrong) }),
            ]
            lines.append(cells.joined(separator: "\t"))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
