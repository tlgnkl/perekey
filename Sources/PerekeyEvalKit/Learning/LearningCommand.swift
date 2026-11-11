// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
import PerekeyModelKit

/// `perekey-eval learning` (docs/eval.md, «Обучение»):
///
///     perekey-eval learning run --manifest <file> [--manifest …] --model <dir> [--options <json>] [--seeds N] [--out <dir>]
///     perekey-eval learning sweep --manifest <file> [--manifest …] --model <dir> --grid <json> [--options <json>]
///                                 [--seeds N] [--out <file>]
///     perekey-eval learning vocabulary --run <play run dir> --out <file> [--size 50]
///
/// `--options` takes fields of `LearningOptions` and of `Classifier.Options` in one object. `--grid` is an
/// object of lists, `{"frequentThreshold": [2, 3, 4], "manifest.accidentContinues": [0, 0.1]}`: `sweep` runs
/// every combination; `manifest.<share>` changes a share of the manifests.
enum LearningCommand {
    static func run(_ parsed: inout Arguments) throws -> Int32 {
        guard !parsed.positional.isEmpty else { throw EvalError.input("usage: perekey-eval learning run|sweep|vocabulary …") }
        switch parsed.positional.removeFirst() {
        case "run": return try runSets(parsed)
        case "sweep": return try sweep(parsed)
        case "vocabulary": return try vocabulary(parsed)
        case let other: throw EvalError.input("learning: unknown subcommand \(other)")
        }
    }

    // MARK: - Sets

    /// A manifest with its vocabulary, read.
    struct LoadedSet {
        var manifest: LearningManifest
        var vocabulary: LearningVocabulary
        var vocabularySHA: String
        var file: String
    }

    static func sets(_ parsed: Arguments) throws -> [LoadedSet] {
        let files = parsed.values("--manifest")
        guard !files.isEmpty else { throw EvalError.input("learning: --manifest <file> is required") }
        return try files.map { file in
            let manifest = try LearningManifest.read(file: file)
            let path = URL(fileURLWithPath: file).deletingLastPathComponent().appendingPathComponent(manifest.vocabulary).path
            return LoadedSet(manifest: manifest, vocabulary: try LearningVocabulary.read(file: path),
                       vocabularySHA: try Runner.sha256(file: path), file: file)
        }
    }

    /// The options of `--options` and the classifier of `--model`, made once per run of the command.
    struct Setup {
        var learning: LearningOptions
        var classifier: Classifier
        var optionsJSON: String?
        var modelHashes: [String: String]
    }

    static func setup(_ parsed: Arguments, sets: [LoadedSet], library: LayoutLibrary) throws -> Setup {
        guard let model = parsed.value("--model") else { throw EvalError.input("learning: --model <dir> is required") }
        var learning = LearningOptions()
        var classifierOptions = Classifier.Options()
        if let json = parsed.value("--options") { (learning, classifierOptions) = try LearningOptionsTable.parse(json) }
        let languages = Set(try sets.flatMap { set in
            try set.manifest.layouts.compactMap { name -> String? in
                guard let map = library[name] else { throw EvalError.input("\(set.manifest.name): unknown layout \(name)") }
                return map.language
            }
        }).sorted()
        let loaded = try ModelFile.load(model, languages: languages)
        var hashes: [String: String] = [:]
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: model, isDirectory: &isDirectory), isDirectory.boolValue {
            for language in languages {
                hashes[language] = try Runner.sha256(file: "\(model)/\(language).\(ModelFile.fileExtension)")
            }
        } else {
            hashes[(model as NSString).lastPathComponent] = try Runner.sha256(file: model)
        }
        return Setup(learning: learning, classifier: Classifier(model: loaded, options: classifierOptions),
                     optionsJSON: parsed.value("--options"), modelHashes: hashes)
    }

    static func seeds(_ parsed: Arguments) throws -> Int {
        guard let text = parsed.value("--seeds") else { return 1 }
        guard let count = Int(text), count > 0, count <= 100 else { throw EvalError.input("--seeds is 1…100") }
        return count
    }

    static func play(_ set: LoadedSet, setup: Setup, library: LayoutLibrary, options: LearningOptions, seeds: Int) throws
        -> [LearningRun]
    {
        try (0..<seeds).map { offset in
            try LearningSimulation.run(LearningSimulation.Config(
                manifest: set.manifest, vocabulary: set.vocabulary, library: library, classifier: setup.classifier,
                options: options, seed: set.manifest.seed &+ UInt64(offset)))
        }
    }

    // MARK: - run

    static func runSets(_ parsed: Arguments) throws -> Int32 {
        let library = try parsed.library()
        let sets = try sets(parsed)
        let setup = try setup(parsed, sets: sets, library: library)
        let seeds = try seeds(parsed)
        var report = LearningReport.Document(commit: GitCommit.current(), models: setup.modelHashes,
                                             options: setup.optionsJSON, seeds: seeds, sets: [])
        var text = ""
        for set in sets {
            let runs = try play(set, setup: setup, library: library, options: setup.learning, seeds: seeds)
            report.sets.append(LearningReport.Entry(name: set.manifest.name, manifest: set.file,
                                                    vocabularySHA256: set.vocabularySHA, runs: runs))
            text += LearningReport.text(set.manifest, runs: runs)
        }
        if let out = parsed.value("--out") { try LearningReport.write(report, to: out) }
        EvalContext.out(text, terminator: "")
        return 0
    }

    // MARK: - sweep

    static func sweep(_ parsed: Arguments) throws -> Int32 {
        guard let grid = parsed.value("--grid") else { throw EvalError.input("learning sweep: --grid <json> is required") }
        let points = try LearningReport.points(grid: grid)
        let library = try parsed.library()
        let sets = try sets(parsed)
        try LearningReport.check(points: points, against: sets.map(\.manifest))
        let setup = try setup(parsed, sets: sets, library: library)
        let seeds = try seeds(parsed)
        var rows: [LearningReport.SweepRow] = []
        for point in points {
            var options = setup.learning
            for (name, value) in point {
                try LearningOptionsTable.table[name]?(&options, value)
            }
            for var set in sets {
                for (name, value) in point where LearningManifest.overridable.contains(name) {
                    set.manifest = try set.manifest.overriding(name, value)
                }
                let runs = try play(set, setup: setup, library: library, options: options, seeds: seeds)
                rows.append(LearningReport.SweepRow(point: point, name: set.manifest.name, runs: runs))
            }
        }
        let table = LearningReport.sweepTable(rows, seeds: seeds)
        if let out = parsed.value("--out") {
            try table.write(toFile: out, atomically: true, encoding: .utf8)
        }
        EvalContext.out(table, terminator: "")
        return 0
    }

    // MARK: - vocabulary

    static func vocabulary(_ parsed: Arguments) throws -> Int32 {
        guard let run = parsed.value("--run") else { throw EvalError.input("learning vocabulary: --run <play run dir> is required") }
        guard let out = parsed.value("--out") else { throw EvalError.input("learning vocabulary: --out <file> is required") }
        let size = try parsed.value("--size").map { text -> Int in
            guard let size = Int(text), size > 0 else { throw EvalError.input("--size is a positive number") }
            return size
        } ?? 50
        let events = (try? String(contentsOfFile: "\(run)/events.jsonl", encoding: .utf8)) ?? ""
        guard !events.isEmpty else { throw EvalError.input("\(run)/events.jsonl: no such run") }
        let candidates = try VocabularyPicker.candidates(eventsJSONL: events,
                                                         runJSON: try? Data(contentsOf: URL(fileURLWithPath: "\(run)/run.json")))
        let chosen = VocabularyPicker.choose(candidates, size: size)
        guard chosen.count == size else {
            throw EvalError.input("learning vocabulary: \(chosen.count) words fit the rule, \(size) wanted")
        }
        let commit = (try? Data(contentsOf: URL(fileURLWithPath: "\(run)/run.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["commit"] as? String
        let header = [
            "# Личный словарь набора learning.*: слова, которые Perekey ложно переключает (вред формы layout, ошибка none, сценарий clean.*, часть dev).",
            "# Отбор: слова из букв, не короче двух; по числу вредов (убывание), затем по алфавиту; первые \(size).",
            "# Источник: \(run) (commit \(commit ?? "?")); команда: perekey-eval learning vocabulary --run <каталог прогона> --out <файл> --size \(size)",
            "# Столбцы: слово, раскладка, в которой человек его пишет, число вредов в части dev.",
        ]
        let lines = chosen.map { "\($0.word)\t\($0.layout)\t\($0.harm)" }
        try (header + lines).joined(separator: "\n").appending("\n").write(toFile: out, atomically: true, encoding: .utf8)
        EvalContext.out("\(chosen.count) words, \(candidates.count) fit the rule → \(out)")
        return 0
    }
}

/// Words that Perekey falsely switches, from the events of a run (`events.jsonl`).
enum VocabularyPicker {
    struct Candidate: Hashable {
        var word: String
        var layout: String
        var harm: Int
    }

    /// The layout a person writes a word of this language in; the bench's
    /// pair of layouts for the set is ABC and Russian.
    static let layouts = ["en": "ABC", "ru": "Russian"]

    /// Reads `run.json` of the run: a run with the words of the test part shown (`testRevealed`) or with a
    /// personal set (`personal`) is no source for a vocabulary that is committed to the repository; a run
    /// without `run.json` cannot be told, and is refused too.
    static func checkSource(runJSON: Data?) throws {
        guard let runJSON, let info = (try? JSONSerialization.jsonObject(with: runJSON)) as? [String: Any] else {
            throw EvalError.input("learning vocabulary: run.json is missing or is not an object; the run cannot be told from a revealed or a personal one")
        }
        if info["testRevealed"] as? Bool == true {
            throw EvalError.input("learning vocabulary: the run shows the words of the test part (testRevealed); play it again without --reveal-test")
        }
        if info["personal"] as? Bool == true {
            throw EvalError.input("learning vocabulary: the run holds a personal set; its words are not for a committed vocabulary")
        }
    }

    /// Harm of form `layout` on a word typed as meant (`err: none`) in a
    /// `clean.*` scenario, of the part dev (the words of `test` are not
    /// printed), by lowercase word. Letters only, two at least.
    static func candidates(eventsJSONL: String, runJSON: Data?) throws -> [Candidate] {
        try checkSource(runJSON: runJSON)
        var counts: [String: (layout: String, harm: Int)] = [:]
        for line in eventsJSONL.split(separator: "\n") {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                throw EvalError.input("events.jsonl: a line is not JSON")
            }
            guard row["outcome"] as? String == "harm", row["form"] as? String == "layout",
                  let want = row["want"] as? String, want != "(test)",
                  let features = row["features"] as? [String: Any], features["err"] as? String == "none",
                  let language = features["lang"] as? String, let layout = layouts[language],
                  let id = row["id"] as? String, id.split(separator: "/").dropFirst().first?.hasPrefix("clean") == true,
                  want.count >= 2, want.allSatisfy(\.isLetter)
            else { continue }
            let word = WordRules.normalize(want)
            counts[word] = (layout, (counts[word]?.harm ?? 0) + 1)
        }
        return counts.map { Candidate(word: $0.key, layout: $0.value.layout, harm: $0.value.harm) }
    }

    static func choose(_ candidates: [Candidate], size: Int) -> [Candidate] {
        Array(candidates.sorted { ($0.harm, $1.word) > ($1.harm, $0.word) }.prefix(size))
    }
}
