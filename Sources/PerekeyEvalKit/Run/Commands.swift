// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
import PerekeyDesk

/// The bench's commands of `perekey-eval` (docs/eval.md, «Команды»):
///
///     perekey-eval cases check <files .jsonl>
///     perekey-eval cases list  <files .jsonl> [--suite X] [--scenario Y] [--split dev|test] [--reveal-test]
///     perekey-eval cases build [--suites <dir>] [--cache <dir>] [--tier ci|full] [--out <dir>]
///                              [--only <suite,...>] [--epoch <n>]
///     perekey-eval play   --cases <files or directory> --model <dir> --out <run dir>
///                         [--system machine|null|oracle] [--options <json>] [--settings <preset>]
///                         [--only <suite,...>] [--split dev|test|all]
///     perekey-eval case   --cases <files> --id <id> [--model <dir>] [--system ...] [--reveal-test]
///     perekey-eval selfcheck --cases <files or directory> --model <dir> [--suites <dir> --cache <dir> --tier ci|full [--built <dir>] [--rebuild <suite,...>]] [--mutants]
///     perekey-eval report <run dir> [--format text|md|html|json] [--out <file>] [--profile chat,dev,office]
///                         [--profiles <file>] [--slices] [--words N] [--reveal-test]
///     perekey-eval diff   <run A> <run B> [--format text|md|json] [--list N] [--reveal-test]
///     perekey-eval gate   <head run> [<base run>] [--gates <file>] [--profiles <file>] [--cases <files or directory>]
///                         [--format text|md|json] [--list N] [--stand-pr] [--out <file>]
///
/// `play` also takes `--cache <data cache>` (and `--lexicon <dir>`, `--data <dir>`, `--noise <dir>`) to score with
/// the lexicon: `disputed`, `silent` and the features `known`, `zipf`, `collision`, `seen`.
///
/// Every command takes `--layouts <dir>` (default eval/layouts). Exit status:
/// 0 success, 1 a self-check failed or a bar is not taken, 2 bad input.
public enum EvalCommands {
    public static let names: Set<String> = ["cases", "play", "case", "selfcheck", "report", "diff", "gate"]

    public static func run(_ arguments: [String]) -> Int32 {
        do {
            var parsed = try Arguments(arguments)
            let command = try parsed.command()
            switch command {
            case "cases": return try cases(&parsed)
            case "play": return try play(parsed)
            case "case": return try showCase(parsed)
            case "selfcheck": return try selfcheck(parsed)
            case "report": return try report(parsed)
            case "diff": return try diff(parsed)
            case "gate": return try gate(parsed)
            default: throw EvalError.input("unknown command \(command)")
            }
        } catch {
            FileHandle.standardError.write(Data("perekey-eval: \(error)\n".utf8))
            return 2
        }
    }

    // MARK: - cases

    static func cases(_ parsed: inout Arguments) throws -> Int32 {
        let sub = try parsed.command()
        if sub == "build" { return try build(parsed) }
        let library = try parsed.library()
        let files = try CaseFiles.expand(parsed.positional)
        guard !files.isEmpty else { throw EvalError.input("cases \(sub): no files") }
        switch sub {
        case "check":
            var problems = 0
            var count = 0
            for file in files {
                let text = try String(contentsOfFile: file, encoding: .utf8)
                let items: [EvalCase]
                do {
                    items = try CaseCodec.read(text, file: file)
                } catch {
                    print("\(error)")
                    problems += 1
                    continue
                }
                let lines = text.split(separator: "\n").map(String.init)
                for (item, line) in zip(items, lines) {
                    count += 1
                    var found = CaseCheck.problems(item, layouts: library, reveal: parsed.flag("--reveal-test"))
                    if try CaseCodec.line(item) != line { found.append("the line is not canonical: sorted keys, no spaces") }
                    for problem in found { print("\(file): \(item.id): \(problem)") }
                    problems += found.isEmpty ? 0 : 1
                }
            }
            print("\(count) cases, \(problems) with problems")
            return problems == 0 ? 0 : 2
        case "list":
            let reveal = parsed.flag("--reveal-test")
            for (_, item) in try CaseFiles.read(files) {
                if let suite = parsed.value("--suite"), item.suite != suite { continue }
                if let scenario = parsed.value("--scenario"), item.scenario != scenario { continue }
                if let split = parsed.value("--split"), item.split.rawValue != split { continue }
                let want = item.split == .dev || reveal ? item.want.debugDescription : "(test)"
                print("\(item.id)\t\(item.split.rawValue)\t\(want)")
            }
            return 0
        default:
            throw EvalError.input("unknown command cases \(sub): check, list or build")
        }
    }

    // MARK: - play

    static func play(_ parsed: Arguments) throws -> Int32 {
        guard let out = parsed.value("--out") else { throw EvalError.input("play: --out <run dir> is required") }
        let library = try parsed.library()
        let files = try CaseFiles.expand(parsed.values("--cases"))
        let items = try selected(files, parsed, library: library)
        var config = try parsed.config()
        let knowledge = try parsed.knowledge(items: items, library: library)
        config.knowledge = knowledge?.knowledge
        var runner = Runner(config: config, library: library)
        var scores: [CaseScore] = []
        for item in items { scores.append(try runner.play(item).score) }
        var info = RunFiles.Info(
            commit: GitCommit.current(), models: runner.modelHashes, system: runner.config.system.rawValue,
            settings: runner.config.settings, options: runner.config.optionsJSON,
            files: try files.map { .init(path: $0, sha256: try Runner.sha256(file: $0)) },
            split: parsed.value("--split") ?? "all", only: parsed.value("--only")?.split(separator: ",").map(String.init),
            tier: nil, testRevealed: runner.config.revealTest
        )
        info.lexicon = knowledge?.lexiconHashes
        info.seen = knowledge?.seenHash
        info.noise = knowledge?.knowledge.noise.files
        try RunFiles.write(scores, info: info, to: out)
        print(Console.summary(Summary(scores)), terminator: "")
        return 0
    }

    /// The cases of the files after `--only` and `--split`; every case must
    /// pass the checks, or nothing is played.
    static func selected(_ files: [String], _ parsed: Arguments, library: LayoutLibrary, split override: String? = nil)
        throws -> [EvalCase]
    {
        let only = parsed.value("--only").map { Set($0.split(separator: ",").map(String.init)) }
        let split = override ?? parsed.value("--split") ?? "all"
        guard ["dev", "test", "all"].contains(split) else { throw EvalError.input("--split dev|test|all") }
        var items: [EvalCase] = []
        var problems: [String] = []
        for (file, item) in try CaseFiles.read(files) {
            if let only, !only.contains(item.suite) { continue }
            if split != "all", item.split.rawValue != split { continue }
            problems += CaseCheck.problems(item, layouts: library, reveal: parsed.flag("--reveal-test"))
                .map { "\(file): \(item.id): \($0)" }
            items.append(item)
        }
        guard problems.isEmpty else {
            throw EvalError.input("cases do not pass the check:\n" + problems.joined(separator: "\n"))
        }
        return items
    }

    // MARK: - report and diff

    static func report(_ parsed: Arguments) throws -> Int32 {
        guard let directory = parsed.positional.first else { throw EvalError.input("report: <run dir> is required") }
        var options = ReportOptions()
        options.revealTest = parsed.flag("--reveal-test")
        options.slices = parsed.flag("--slices")
        options.words = try parsed.value("--words").map { try Self.count($0, "--words") }
        options.profiles = parsed.value("--profile")?.split(separator: ",").map(String.init)
        let profilesPath = parsed.value("--profiles") ?? "eval/profiles.json"
        if parsed.value("--profiles") != nil || FileManager.default.fileExists(atPath: profilesPath) {
            options.profilesFile = profilesPath
        }
        if options.words == nil, (parsed.value("--format") ?? "text") == "text" { options.words = 20 }
        let data = try ReportBuilder.build(try RunData.load(directory), options: options)
        let text: String
        switch parsed.value("--format") ?? "text" {
        case "text": text = ReportRender.text(data)
        case "md": text = ReportRender.markdown(data)
        case "html": text = ReportRender.html(data)
        case "json": text = try ReportRender.json(data)
        default: throw EvalError.input("--format text|md|html|json")
        }
        try output(text, to: parsed.value("--out"))
        return 0
    }

    static func diff(_ parsed: Arguments) throws -> Int32 {
        guard parsed.positional.count == 2 else { throw EvalError.input("diff: <run A> <run B>") }
        var options = DiffOptions()
        options.revealTest = parsed.flag("--reveal-test")
        if let list = parsed.value("--list") { options.list = try count(list, "--list") }
        let data = try DiffBuilder.build(try RunData.load(parsed.positional[0]), try RunData.load(parsed.positional[1]),
                                         options: options)
        let text: String
        switch parsed.value("--format") ?? "text" {
        case "text": text = DiffRender.text(data, list: options.list)
        case "md": text = DiffRender.text(data, list: options.list, markdown: true)
        case "json":
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            text = String(decoding: try encoder.encode(data), as: UTF8.self) + "\n"
        default: throw EvalError.input("--format text|md|json")
        }
        try output(text, to: parsed.value("--out"))
        return 0
    }

    /// The bars of `eval/gates.json` over a run, and over a run against its base (docs/eval.md, «Планки»).
    static func gate(_ parsed: Arguments) throws -> Int32 {
        guard (1 ... 2).contains(parsed.positional.count) else { throw EvalError.input("gate: <head run> [<base run>]") }
        let gates = try GateFile.read(parsed.value("--gates") ?? "eval/gates.json")
        let profilesPath = parsed.value("--profiles") ?? "eval/profiles.json"
        let profiles = FileManager.default.fileExists(atPath: profilesPath) ? try ProfileFile.read(profilesPath) : nil
        var options = Gate.Options()
        options.standPullRequest = parsed.flag("--stand-pr")
        if let list = parsed.value("--list") { options.listed = try count(list, "--list") }
        var statuses: [String: String] = [:]
        if gates.zero.contains(where: { $0.status != nil }) {
            let cases = parsed.value("--cases") ?? "eval/cases"
            for (_, item) in try CaseFiles.read(try CaseFiles.expand([cases])) {
                if let status = item.status { statuses[item.id] = status }
            }
        }
        let head = try RunData.load(parsed.positional[0])
        let base = try parsed.positional.count == 2 ? RunData.load(parsed.positional[1]) : nil
        if let base, base.scorer != head.scorer {
            throw EvalError.input("the runs were scored by different scorers (\(base.scorer) and \(head.scorer)); play them again")
        }
        let result = Gate.check(gates, head: head, base: base, profiles: profiles, statusOf: statuses, options: options)
        let text: String
        switch parsed.value("--format") ?? "text" {
        case "text": text = GateRender.text(result)
        case "md": text = GateRender.text(result, markdown: true)
        case "json":
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            text = String(decoding: try encoder.encode(result), as: UTF8.self) + "\n"
        default: throw EvalError.input("--format text|md|json")
        }
        try output(text, to: parsed.value("--out"))
        return result.passed ? 0 : 1
    }

    private static func count(_ text: String, _ flag: String) throws -> Int {
        guard let value = Int(text), value >= 0 else { throw EvalError.input("\(flag) needs a number") }
        return value
    }

    private static func output(_ text: String, to path: String?) throws {
        if let path {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        } else {
            print(text, terminator: "")
        }
    }

    // MARK: - case

    static func showCase(_ parsed: Arguments) throws -> Int32 {
        guard let id = parsed.value("--id") else { throw EvalError.input("case: --id is required") }
        let library = try parsed.library()
        let files = try CaseFiles.expand(parsed.values("--cases"))
        guard let original = try CaseFiles.read(files).map(\.item).first(where: { $0.id == id }) else {
            throw EvalError.input("no case \(id)")
        }
        if original.split == .test, !parsed.flag("--reveal-test") {
            throw EvalError.input("\(id) is in the test part: its words are shown only with --reveal-test")
        }
        let problems = CaseCheck.problems(original, layouts: library, reveal: true)
        guard problems.isEmpty else { throw EvalError.input(problems.joined(separator: "\n")) }
        var runner = Runner(config: try parsed.config(), library: library)
        let item = runner.prepared(original)
        let events = try runner.typist.events(for: item, layouts: library)
        let setup = try CaseSetup(item: item, library: library,
                                  classifier: runner.config.system == .machine ? try runner.classifier(for: item) : nil)
        print("\(item.id)  \(item.split.rawValue)  \(runner.config.system.rawValue)  want \(item.want.debugDescription)")
        let out: RunResult
        if runner.config.system == .machine {
            var machine = try MachineSystem(setup: setup)
            machine.recording = true
            for typed in events { try machine.send(typed.event, at: typed.time) }
            out = try machine.finish()
            var records = machine.desk.records[...]
            for (index, typed) in events.enumerated() {
                print(String(format: "%9.4f  ", typed.time) + Console.describe(typed.event))
                while let record = records.first, record.event <= index {
                    records = records.dropFirst()
                    print("           → " + Console.describe(record))
                }
            }
            for record in records { print("           → " + Console.describe(record)) }
        } else {
            for typed in events { print(String(format: "%9.4f  ", typed.time) + Console.describe(typed.event)) }
            out = try runner.config.system.play(setup, events: events)
        }
        let null = try SystemName.null.play(setup, events: events)
        var score = runner.scorer.score(item, null: null, out: out, events: events)
        score.failedChecks = Runner.failedChecks(item, out, library: library)
        print("null  \(null.text.debugDescription)")
        print("out   \(out.text.debugDescription)  layout \(out.layout)  corrections \(out.corrections)  undone \(out.undone)")
        if score.scoring == .token {
            for token in score.tokens {
                print("  \(token.index)  \(token.want)  null \(token.null)  out \(token.out)  \(token.outcome.rawValue)"
                    + (token.form.map { "  \($0)" } ?? "") + (token.cascade ? "  cascade" : ""))
            }
        }
        print("exact \(score.exact)" + (score.failedChecks.isEmpty ? "" : "  failed checks \(score.failedChecks)"))
        return 0
    }

    // MARK: - selfcheck

    static func selfcheck(_ parsed: Arguments) throws -> Int32 {
        let library = try parsed.library()
        let files = try CaseFiles.expand(parsed.values("--cases"))
        var failures: [String] = []
        var lines: [String] = []

        // 6. Every case passes the checks.
        var problems = 0
        for (file, item) in try CaseFiles.read(files) {
            let found = CaseCheck.problems(item, layouts: library, reveal: parsed.flag("--reveal-test"))
            for problem in found { failures.append("\(file): \(item.id): \(problem)") }
            problems += found.isEmpty ? 0 : 1
        }
        guard problems == 0 else {
            for failure in failures { print(failure) }
            print("selfcheck: \(problems) cases do not pass the check")
            return 1
        }
        let items = try selected(files, parsed, library: library)
        let config = try parsed.config()
        func run(_ system: SystemName, settings: String? = nil) throws -> [Runner.Played] {
            var config = config
            config.system = system
            config.settings = settings ?? config.settings
            var runner = Runner(config: config, library: library)
            return try items.map { try runner.play($0) }
        }

        // 1. Null harms and fixes nothing.
        let null = try run(.null)
        let nullHarm = null.flatMap(\.score.measured).filter { $0.outcome == .harm || $0.outcome == .fixed }
        lines.append("1. null: harm and fixed \(nullHarm.count)")
        if !nullHarm.isEmpty { failures.append("null has \(nullHarm.count) harmed or fixed tokens") }

        // 2. Oracle: every token ok or fixed, every text exact. The checks of
        // whole cases (layout, corrections) are not the oracle's: it only has the text.
        let oracle = try run(.oracle)
        let oracleWrong = oracle.filter { played in
            played.score.scoring == .token ? !played.score.exact
                : Scorer.normalize(played.out.text, played.item.effectiveFold)
                != Scorer.normalize(played.item.want, played.item.effectiveFold)
        }
        lines.append("2. oracle: \(oracle.count - oracleWrong.count) of \(oracle.count) exact")
        for played in oracleWrong { failures.append("oracle is not exact on \(played.item.id)") }

        // 3. The machine with the preset `off` types what Null types, where
        // the case presses no shortcut and no Undo.
        let off = try run(.machine, settings: "off")
        var compared = 0
        for (played, nullPlayed) in zip(off, null) where !played.item.allSteps.contains(where: {
            switch $0 {
            case .hotkey, .undo: true
            default: false
            }
        }) {
            compared += 1
            if played.out.text != nullPlayed.out.text {
                failures.append("machine off differs from null on \(played.item.id)" + (played.score.hidden ? ""
                        : ": \(played.out.text.debugDescription) vs \(nullPlayed.out.text.debugDescription)"))
            }
        }
        lines.append("3. machine off = null on \(compared) cases without shortcuts")

        // 4. Two runs of the machine give the same bytes.
        let first = try run(.machine).map(\.score), second = try run(.machine).map(\.score)
        let same = try RunFiles.casesTSV(first) == RunFiles.casesTSV(second)
            && RunFiles.summaryJSON(first) == RunFiles.summaryJSON(second)
            && RunFiles.countsTSV(first) == RunFiles.countsTSV(second)
            && RunFiles.slicesJSON(first) == RunFiles.slicesJSON(second)
            && RunFiles.wordsTSV(first) == RunFiles.wordsTSV(second)
        lines.append("4. machine twice: "
            + (same ? "cases.tsv, summary.json, counts.tsv, slices.json and words.tsv the same" : "DIFFERENT"))
        if !same { failures.append("two runs of the machine differ") }

        // 5. Building the cases twice gives the same bytes.
        if parsed.value("--suites") == nil {
            lines.append("5. cases built twice: skipped, no --suites")
        } else {
            let settings = try BuildSettings(parsed)
            var identical = 0
            let manifests = try settings.manifests()
            // `--built <dir>`: the files an earlier `cases build` wrote there are the first build.
            let earlier = try parsed.value("--built").map { try BuildSummary.read(directory: $0) }
            // `--rebuild <suite,...>`: build only these suites a second time (a source that reads fast).
            let rebuilt = parsed.value("--rebuild").map { Set($0.split(separator: ",").map(String.init)) }
            var compared = 0
            for manifest in manifests {
                if parsed.flag("--skip-missing"), let missing = settings.missingSource(of: manifest) {
                    lines.append("   \(manifest.suite): пропущен, нет источника \(missing)")
                    continue
                }
                if let rebuilt, !rebuilt.contains(manifest.suite) { continue }
                let first: (sha256: String, report: BuildReport)
                if let earlier {
                    guard let entry = earlier.suites.first(where: { $0.report.suite == manifest.suite }) else {
                        lines.append("   \(manifest.suite): not in --built, not compared")
                        continue
                    }
                    first = (entry.sha256, entry.report)
                } else {
                    let built = try builtSuite(manifest, settings: settings, library: library)
                    first = (built.sha256, built.report)
                }
                let second = try builtSuite(manifest, settings: settings, library: library)
                compared += 1
                if first.sha256 == second.sha256, first.report == second.report {
                    identical += 1
                } else {
                    failures.append("building \(manifest.suite) twice gives different bytes")
                }
            }
            lines.append("5. cases built twice (\(settings.tier.rawValue)): \(identical) of \(compared) suites identical")
        }
        lines.append("6. cases pass the check: \(items.count)")

        // 7. Every mutant of the machine shifts the count it must shift (docs/eval.md, «Мутанты»).
        if parsed.flag("--mutants") {
            // Both parts: a shift is read off counts, and more cases make the counts firm.
            let mutantItems = try selected(files, parsed, library: library, split: "all")
            var ordinaryConfig = config
            ordinaryConfig.system = .machine
            var ordinaryRunner = Runner(config: ordinaryConfig, library: library)
            let ordinary = try mutantItems.filter { item in Mutants.all.contains { Mutants.covers($0, item) } }
                .map { try ordinaryRunner.play($0).score }
            for mutant in Mutants.all {
                var mutated = config
                mutated.system = .machine
                mutated.optionsJSON = mutant.options
                mutated.options = try mutant.options.map(ClassifierOptions.parse) ?? Classifier.Options()
                mutated.settings = mutant.settings ?? config.settings
                var runner = Runner(config: mutated, library: library)
                let scores = try mutantItems.filter { Mutants.covers(mutant, $0) }.map { try runner.play($0).score }
                for finding in Mutants.judge(mutant, ordinary: ordinary, mutated: scores) {
                    lines.append("7. mutant " + finding.line)
                    if finding.verdict == .fail { failures.append(finding.line) }
                }
            }
        } else {
            lines.append("7. mutants: skipped, no --mutants")
        }

        for line in lines { print(line) }
        for failure in failures { print("FAIL: \(failure)") }
        return failures.isEmpty ? 0 : 1
    }
}

/// The arguments of a bench command: words, then `--flags` with values.
struct Arguments {
    var positional: [String] = []
    private var values: [String: [String]] = [:]
    private var flags: Set<String> = []
    private static let booleans: Set<String> = ["--reveal-test", "--slices", "--stand-pr", "--mutants", "--skip-missing"]

    init(_ arguments: [String]) throws {
        var current: String?
        for argument in arguments {
            if argument.hasPrefix("--") {
                if Self.booleans.contains(argument) {
                    flags.insert(argument)
                    current = nil
                } else {
                    current = argument
                    values[argument, default: []] += []
                }
            } else if let flag = current {
                values[flag, default: []].append(argument)
            } else {
                positional.append(argument)
            }
        }
        for (flag, list) in values where list.isEmpty { throw EvalError.input("\(flag) needs a value") }
    }

    /// The next word: a command or a subcommand.
    mutating func command() throws -> String {
        guard !positional.isEmpty else { throw EvalError.input("usage: perekey-eval cases|play|case|selfcheck|report|diff|gate …") }
        return positional.removeFirst()
    }

    func value(_ flag: String) -> String? { values[flag]?.last }
    func values(_ flag: String) -> [String] { values[flag] ?? [] }
    func flag(_ flag: String) -> Bool { flags.contains(flag) }

    /// What `play` scores with besides the cases, given by `--cache` or `--lexicon`.
    struct KnowledgeSetup {
        var knowledge: Knowledge
        var lexiconHashes: [String: String]
        var seenHash: String?
    }

    /// The lexicon, the lists of `data/` and the noise decisions, for the languages of the
    /// cases' layouts. Without `--cache` and `--lexicon` the run has none.
    func knowledge(items: [EvalCase], library: LayoutLibrary) throws -> KnowledgeSetup? {
        guard value("--cache") != nil || value("--lexicon") != nil else { return nil }
        let directory = value("--lexicon") ?? ".build/quality"
        let languages = Array(Set(try items.flatMap { try library.maps(of: $0).compactMap(\.language) })).sorted()
        let lexicon = try Lexicon.load(languages: languages, directory: directory, cache: value("--cache"))
        let dataPath = value("--data") ?? "data"
        let seen = FileManager.default.fileExists(atPath: dataPath) ? try SeenWords(directory: dataPath) : nil
        let noise = try NoiseDecisions(directory: value("--noise") ?? "eval/noise")
        var hashes: [String: String] = [:]
        for language in languages { hashes[language] = try Lexicon.hash(language: language, directory: directory) }
        return KnowledgeSetup(knowledge: Knowledge(lexicon: lexicon, seen: seen, noise: noise), lexiconHashes: hashes,
                              seenHash: seen?.hash)
    }

    func library() throws -> LayoutLibrary {
        try LayoutLibrary(directory: value("--layouts") ?? "eval/layouts")
    }

    func config() throws -> Runner.Config {
        var config = Runner.Config()
        if let name = value("--system") {
            guard let system = SystemName(rawValue: name) else { throw EvalError.input("--system machine|null|oracle") }
            config.system = system
        }
        config.model = value("--model")
        if config.system == .machine, config.model == nil { throw EvalError.input("--model <dir> is required") }
        if let json = value("--options") {
            config.options = try ClassifierOptions.parse(json)
            config.optionsJSON = json
        }
        config.revealTest = flag("--reveal-test")
        if let preset = value("--settings") {
            guard EvalSettings.preset(preset) != nil else {
                throw EvalError.input("--settings \(EvalSettings.names.joined(separator: "|"))")
            }
            config.settings = preset
        }
        return config
    }
}
