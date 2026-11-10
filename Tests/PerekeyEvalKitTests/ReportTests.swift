// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
@testable import PerekeyEvalKit
import Testing

/// Plays cases and writes a run directory the report and diff read back.
enum RunDirectory {
    static func cases() throws -> [EvalCase] {
        try CaseCodec.read(file: Repo.path("eval/cases/flow.basics.jsonl"))
            + CaseCodec.read(file: Repo.path("eval/cases/incidents.jsonl"))
    }

    /// A temporary directory removed at the end of the test by the caller.
    static func temporary() -> String { NSTemporaryDirectory() + "run-\(UUID().uuidString)" }

    static let lexicon = Lexicon(words: [
        "ru": [("привет", 5.5), ("мир", 5), ("окей", 4), ("баг", 3.5), ("где", 6), ("вопервых", 1)],
        "en": [("hello", 5.5), ("zoom", 4), ("git", 4), ("push", 4)],
    ])

    @discardableResult
    static func play(_ items: [EvalCase], to directory: String, system: SystemName = .machine, settings: String? = nil,
                     reveal: Bool = false, knowledge: Bool = true, commit: String = "abc1234") throws -> [CaseScore]
    {
        var config = Runner.Config()
        config.system = system
        config.classifier = Repo.classifier
        config.settings = settings
        config.revealTest = reveal
        if knowledge { config.knowledge = Knowledge(lexicon: lexicon, seen: SeenWords(words: ["привет", "окей"])) }
        var runner = Runner(config: config, library: Repo.library)
        let scores = try items.map { try runner.play($0).score }
        let info = RunFiles.Info(commit: commit, models: ["ru": "62b5126aaaa"], system: system.rawValue, settings: settings,
                                 files: [], split: "all", tier: "ci", testRevealed: reveal,
                                 lexicon: knowledge ? ["ru": "00", "en": "11"] : nil)
        try RunFiles.write(scores, info: info, to: directory)
        return scores
    }

    /// A token case whose word is `word`, in the test or dev part.
    static func wordCase(_ word: String, split: EvalCase.Split, scenario: String = "slip.cold", suite: String = "prose.test") -> EvalCase {
        var item = EvalCase(suite: suite, scenario: scenario, split: split, layouts: ["ABC", "Russian"], start: "ABC",
                            script: [.type("\(word) ", on: "Russian")], want: word,
                            tokens: [TokenSpec(t: word, lang: "ru", err: .layout)])
        item = try! item.identified()
        return item
    }
}

@Suite struct SliceTests {
    func scores() throws -> [CaseScore] {
        try RunDirectory.play(RunDirectory.cases(), to: RunDirectory.temporary(), knowledge: true)
    }

    @Test func everyMeasuredTokenIsInEveryFeatureOnce() throws {
        let scores = try scores()
        let table = SliceTable(scores)
        let measured = scores.flatMap(\.measured).count
        for name in ["lang", "len", "pos", "ctx", "cap", "punct", "digits", "err", "end", "zipf", "collision", "seen"] {
            let sum = table.features[name, default: [:]].values.reduce(0) { $0 + $1.tokens }
            #expect(sum == measured, "\(name)")
        }
        #expect(table.total.tokens == measured)
    }

    @Test func theCountsAddUpToTheSummary() throws {
        let scores = try scores()
        let table = SliceTable(scores)
        let summary = Summary(scores).total
        let total = table.total
        #expect(total.harm == summary.harm && total.miss == summary.miss && total.fixed == summary.fixed)
        #expect(total.botched == summary.botched && total.disputed == summary.disputed && total.silent == summary.silent)
        #expect(total.layoutErrors == summary.layoutErrors && total.missLayout == summary.missLayout)
        // Cases scored as a whole have words in the summary but no token to slice.
        #expect(total.words == scores.filter { $0.scoring == .token }.reduce(0) { $0 + $1.words })
        #expect(total.wrong == summary.wrong && total.wrongNull == summary.wrongNull)
    }

    @Test func aPairHoldsTheTokensWithBothValues() throws {
        let scores = try scores()
        let table = SliceTable(scores, pairSupport: 1)
        var expected = 0
        for token in scores.flatMap(\.measured) where token.features?.len == "1-2" && token.features?.ctx == "cold" { expected += 1 }
        #expect(table.pairs["ctx=cold & len=1-2"]?.tokens == nil, "the features are in the order of featureNames: len before ctx")
        #expect(table.pairs["len=1-2 & ctx=cold"]?.tokens == expected)
        #expect(table.pairs.keys.allSatisfy { key in
            let names = key.components(separatedBy: " & ").map { $0.split(separator: "=")[0] }
            return names.count == 2 && names[0] != names[1]
        })
    }

    @Test func aSmallPairIsLeftOut() throws {
        let scores = try scores()
        let all = SliceTable(scores, pairSupport: 1).pairs.count
        let some = SliceTable(scores, pairSupport: 50).pairs.count
        #expect(some < all)
        #expect(SliceTable(scores, pairSupport: 50).pairs.values.allSatisfy { $0.words >= 50 })
    }

    @Test func theFileReadsBack() throws {
        let table = SliceTable(try scores())
        let json = try RunFiles.slicesJSON(try scores())
        #expect(try JSONDecoder().decode(SliceTable.self, from: Data(json.utf8)) == table)
    }
}

@Suite struct ReportTests {
    func run(_ items: [EvalCase]? = nil, reveal: Bool = false, knowledge: Bool = true,
             system: SystemName = .machine) throws -> (String, RunData)
    {
        let directory = RunDirectory.temporary()
        try RunDirectory.play(items ?? RunDirectory.cases(), to: directory, system: system, reveal: reveal,
                              knowledge: knowledge)
        return (directory, try RunData.load(directory))
    }

    @Test func aRunReadsBackAsItWasWritten() throws {
        let (directory, data) = try run()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        #expect(data.rows.count == (try RunDirectory.cases()).count)
        #expect(data.info.commit == "abc1234")
        let scores = try RunDirectory.play(RunDirectory.cases(), to: RunDirectory.temporary())
        #expect(try RunFiles.summaryJSON(scores).contains("\"schema\" : 2"))
        let total = data.rows.reduce(into: Metrics()) { $0.merge($1.metrics) }
        #expect(total.words == Summary(scores).total.words)
        #expect(total.harm == Summary(scores).total.harm && total.exact == Summary(scores).total.exact)
    }

    @Test func aRunFromAnOlderBenchIsRefused() throws {
        let (directory, _) = try run()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/summary.json"
        let old = try String(contentsOfFile: path, encoding: .utf8).replacingOccurrences(of: "\"schema\" : 2", with: "\"schema\" : 1")
        try old.write(toFile: path, atomically: true, encoding: .utf8)
        #expect(throws: EvalError.self) { try RunData.load(directory) }
        try FileManager.default.removeItem(atPath: directory + "/counts.tsv")
        #expect(throws: EvalError.self) { try RunData.load(directory) }
    }

    @Test func theReportPrintsTheBlocksOfThePlan() throws {
        let (directory, data) = try run()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let profiles = NSTemporaryDirectory() + "profiles-\(UUID().uuidString).json"
        try #"{"profiles":{"office":{"incidents":1,"flow.basics":1}},"version":1}"#.write(toFile: profiles, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: profiles) }
        var options = ReportOptions()
        options.profilesFile = profiles
        options.slices = true
        options.support = 1
        let report = try ReportBuilder.build(data, options: options)
        let text = ReportRender.text(report)
        #expect(text.hasPrefix("Perekey Eval — machine, abc1234, модели ru 62b5…, уровень ci, эпоха 1"))
        for block in ["Профили", "Набор × сценарий", "Худшие срезы", "Слова (dev)", "Сбои: исправлено", "Признак len"] {
            #expect(text.contains(block), "\(block)")
        }
        #expect(report.groups.map(\.suite).contains("incidents"))
        #expect(report.incidents.open > 0)
        #expect(report.profiles.count == 1)
    }

    @Test func eachFormatCarriesTheSameBlocks() throws {
        let (directory, data) = try run()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        var options = ReportOptions()
        options.slices = true
        let report = try ReportBuilder.build(data, options: options)
        let md = ReportRender.markdown(report), html = ReportRender.html(report), json = try ReportRender.json(report)
        #expect(md.hasPrefix("# Perekey Eval") && md.contains("## Набор × сценарий") && md.contains("|---|"))
        #expect(html.contains("<table class=\"sortable\">") && html.contains("<details>") && html.contains("</html>"))
        #expect(!html.contains("http://") && !html.contains("https://") && !html.contains("<link") && !html.contains("src="),
                "one file, nothing outside")
        #expect(json.contains("\"groups\"") && json.contains("\"worst\""))
        let decoded = try JSONDecoder().decode(ReportData.self, from: Data(json.utf8))
        #expect(decoded == report)
    }

    @Test func htmlEscapesWhatItQuotes() throws {
        var report = try ReportBuilder.build(run().1)
        report.words = [WordLine(word: "<b>&\"x", split: "dev", occurrences: 1, harm: 1, miss: 0, botched: 0, weight: 1)]
        let html = ReportRender.html(report)
        #expect(html.contains("&lt;b&gt;&amp;&quot;x") && !html.contains("<b>&"))
    }

    @Test func aProfileIsTheWeightedMeanOfItsSuites() {
        func row(_ suite: String, harm: Int, words: Int) -> RunData.Row {
            var metrics = Metrics()
            metrics.cases = 1
            metrics.harm = harm
            metrics.words = words
            return RunData.Row(id: "\(suite)/clean.cold/0", suite: suite, scenario: "clean.cold", split: "dev", epoch: 1, lag: nil, metrics: metrics)
        }
        let rows = [row("a", harm: 1, words: 10), row("b", harm: 3, words: 10)]
        let both = ProfileEstimator.row("p", weights: ["a": 1, "b": 1], rows: rows)
        #expect(both.harm.value == 0.2 && both.missing.isEmpty && both.harm.events == 4 && both.harm.of == 20)
        let weighted = ProfileEstimator.row("p", weights: ["a": 3, "b": 1], rows: rows)
        #expect(abs(weighted.harm.value! - 0.15) < 1e-12)
        let partial = ProfileEstimator.row("p", weights: ["a": 1, "c": 5], rows: rows)
        #expect(partial.missing == ["c"] && abs(partial.harm.value! - 0.1) < 1e-12)
    }

    @Test func theProfilesFileIsChecked() throws {
        let path = NSTemporaryDirectory() + "profiles-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try #"{"profiles":{"x":{"a":0}},"version":1}"#.write(toFile: path, atomically: true, encoding: .utf8)
        #expect(throws: EvalError.self) { try ProfileFile.read(path) }
        try #"{"profiles":{"x":{"a":1}},"version":2}"#.write(toFile: path, atomically: true, encoding: .utf8)
        #expect(throws: EvalError.self) { try ProfileFile.read(path) }
        let repo = try ProfileFile.read(Repo.path("eval/profiles.json"))
        #expect(Set(repo.profiles.keys) == ["chat", "dev", "office"])
    }

    @Test func aGroupHasItsIntervalAndCounts() throws {
        let (directory, data) = try run()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let report = try ReportBuilder.build(data)
        let group = try #require(report.groups.first { $0.suite == "incidents" && $0.scenario == "clean.cold" })
        let harm = try #require(group.estimates["harm"])
        #expect(harm.of == group.words && harm.events > 0)
        let low = try #require(harm.low), high = try #require(harm.high), value = try #require(harm.value)
        #expect(low <= value && value <= high)
        let none = try #require(report.groups.compactMap { $0.estimates["harm"] }.first { $0.events == 0 && $0.of > 0 })
        #expect(none.upperIfNone == 3 / Double(none.of))
    }

    /// Rule 2.8: no word of the test part in the report without `--reveal-test`.
    @Test func noWordOfTheTestPartIsInTheReport() throws {
        let secret = "сокровенное"
        let items = try RunDirectory.cases() + [RunDirectory.wordCase(secret, split: .test),
                                                 RunDirectory.wordCase("видимое", split: .dev)]
        let (directory, data) = try run(items, reveal: true, system: .null)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        #expect(data.info.testRevealed)
        var options = ReportOptions()
        options.slices = true
        options.words = 1000
        options.support = 1
        let hidden = try ReportBuilder.build(data, options: options)
        let everything = [ReportRender.text(hidden), ReportRender.markdown(hidden), ReportRender.html(hidden),
                          try ReportRender.json(hidden)]
        for (index, output) in everything.enumerated() {
            #expect(!output.contains(secret), "format \(index)")
            #expect(!output.contains("cjrhjdtyyjt"), "format \(index), the keys")
        }
        #expect(ReportRender.text(hidden).contains("видимое"))
        #expect(!ReportRender.text(hidden).contains("ТЕСТ РАСКРЫТ"))
        options.revealTest = true
        let shown = try ReportBuilder.build(data, options: options)
        #expect(ReportRender.text(shown).contains(secret))
        #expect(ReportRender.text(shown).contains("ТЕСТ РАСКРЫТ") && ReportRender.text(shown).contains("тест раскрыт"))
    }

    @Test func aRunPlayedWithoutRevealNeverShowsTheTestWords() throws {
        let secret = "сокровенное"
        let items = [RunDirectory.wordCase(secret, split: .test), RunDirectory.wordCase("видимое", split: .dev)]
        let (directory, data) = try run(items, reveal: false, system: .null)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        var options = ReportOptions()
        options.revealTest = true
        options.words = 1000
        let report = try ReportBuilder.build(data, options: options)
        #expect(!ReportRender.text(report).contains(secret))
        #expect(!report.testRevealed)
        #expect(report.notes.contains { $0.contains("скрыты") })
    }

    @Test func theWordListHoldsTheErrorsOfTheDevPart() throws {
        let items = [RunDirectory.wordCase("видимое", split: .dev), RunDirectory.wordCase("где", split: .dev)]
        let (directory, data) = try run(items, system: .null)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let report = try ReportBuilder.build(data)
        #expect(report.words.map(\.word).contains("где"))
        #expect(report.words.allSatisfy { $0.harm + $0.miss + $0.botched > 0 && $0.split == "dev" })
    }

    @Test func aRunWithoutALexiconSaysSo() throws {
        let (directory, data) = try run(knowledge: false)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let report = try ReportBuilder.build(data)
        #expect(report.notes.contains { $0.contains("без лексикона") })
        #expect(report.seen.isEmpty)
    }

    @Test func theWorstSlicesAreRankedByTheExtraErrors() {
        var table = SliceTable()
        func counters(words: Int, wrong: Int) -> SliceCounters {
            var c = SliceCounters()
            c.words = words
            c.tokens = words
            c.miss = wrong
            return c
        }
        table.features["len"] = ["1-2": counters(words: 300, wrong: 150), "3": counters(words: 700, wrong: 50)]
        table.pairs["len=1-2 & ctx=against"] = counters(words: 250, wrong: 200)
        table.pairs["len=3 & ctx=cold"] = counters(words: 100, wrong: 100)
        let total = counters(words: 1000, wrong: 200)
        var options = ReportOptions()
        options.support = 200
        let worst = ReportBuilder.worstSlices(table, total: total, options: options)
        // Base rate 0.2. Extra: pair 250 → (0.8 − 0.2) · 250 = 150; len=1-2 → (0.5 − 0.2) · 300 = 90;
        // len=3 is below the base; the small pair has too few words.
        #expect(worst.map(\.name) == ["len=1-2 & ctx=against", "len=1-2"])
        #expect(abs(worst[0].extra - 150) < 1e-9 && abs(worst[1].extra - 90) < 1e-9)
    }

    @Test func theNumbersAreFormattedWithACommaAndSpaces() {
        #expect(Fmt.int(119_804) == "119\u{00A0}804" && Fmt.int(12) == "12" && Fmt.int(-1500) == "-1\u{00A0}500")
        #expect(Fmt.scaled(0.00031, scale: 1000) == "0,31" && Fmt.scaled(0.0382, scale: 1000) == "38,2")
        #expect(Fmt.scaled(nil, scale: 1000) == "—")
        let zero = Estimate(value: 0, low: 0, high: 0, events: 0, of: 14_220, upperIfNone: 3 / 14_220)
        #expect(Fmt.estimate(zero, scale: 1000) == "0 (≤ 0,21)")
        let some = Estimate(value: 37.0 / 119_804, low: 0.000224, high: 0.000426, events: 37, of: 119_804, upperIfNone: nil)
        #expect(Fmt.estimate(some, scale: 1000) == "0,31 (0,22–0,43)")
    }

    @Test func theFilesOfARunHideTheTestWordsToo() throws {
        let secret = "сокровенное"
        let item = RunDirectory.wordCase(secret, split: .test)
        let directory = RunDirectory.temporary()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try RunDirectory.play([item], to: directory, reveal: false)
        for name in ["run.json", "cases.tsv", "events.jsonl", "summary.json", "counts.tsv", "slices.json", "words.tsv"] {
            let text = try String(contentsOfFile: directory + "/" + name, encoding: .utf8)
            #expect(!text.contains(secret), Comment(rawValue: name))
        }
    }
}

@Suite struct DiffTests {
    func pair(_ items: [EvalCase], b: (SystemName, String?)) throws -> (RunData, RunData, [String]) {
        let dirA = RunDirectory.temporary(), dirB = RunDirectory.temporary()
        try RunDirectory.play(items, to: dirA, commit: "aaaaaaa")
        try RunDirectory.play(items, to: dirB, system: b.0, settings: b.1, commit: "bbbbbbb")
        return (try RunData.load(dirA), try RunData.load(dirB), [dirA, dirB])
    }

    @Test func aRunAgainstItselfGivesZeros() throws {
        let (a, _, dirs) = try pair(RunDirectory.cases(), b: (.machine, nil))
        defer { dirs.forEach { try? FileManager.default.removeItem(atPath: $0) } }
        let diff = try DiffBuilder.build(a, a)
        #expect(diff.common == a.rows.count && diff.onlyA == 0 && diff.onlyB == 0)
        for row in diff.rows { #expect(row.a == row.b && row.better == 0 && row.worse == 0 && row.p == 1, "\(row.name)") }
        #expect(diff.broken.isEmpty && diff.fixed.isEmpty && diff.brokenTest.isEmpty && diff.fixedTest.isEmpty)
        let text = DiffRender.text(diff, list: 20)
        #expect(text.contains("Сломано (dev): нет") && text.contains("Починено (dev): нет"))
    }

    @Test func anotherSystemShowsWhatBrokeAndWhatWasFixed() throws {
        let (a, b, dirs) = try pair(RunDirectory.cases(), b: (.null, nil))
        defer { dirs.forEach { try? FileManager.default.removeItem(atPath: $0) } }
        let diff = try DiffBuilder.build(a, b)
        // Null fixes nothing, so what the machine fixed is broken in B; what the machine harmed is fixed in B.
        #expect(!diff.broken.isEmpty && !diff.fixed.isEmpty)
        #expect(diff.broken.contains { $0.before == "fixed" && $0.after == "miss" })
        #expect(diff.fixed.contains { $0.before == "harm" && $0.after == "ok" })
        #expect(diff.broken.allSatisfy { ["ok", "fixed", "exact"].contains($0.before) && ["harm", "miss", "botched", "fail"].contains($0.after) })
        #expect(diff.fixed.allSatisfy { ["harm", "miss", "botched", "fail"].contains($0.before) && ["ok", "fixed", "exact"].contains($0.after) })
        let reverse = try DiffBuilder.build(b, a)
        #expect(reverse.fixed.count == diff.broken.count && reverse.broken.count == diff.fixed.count)
        let fixedRow = try #require(reverse.rows.first { $0.name == "пропуск" })
        #expect(fixedRow.better > 0 && fixedRow.better + fixedRow.worse > 0)
        #expect(fixedRow.p == Stats.mcNemar(better: fixedRow.better, worse: fixedRow.worse))
        let text = DiffRender.text(diff, list: 3)
        #expect(text.hasPrefix("A machine@aaaaaaa → B null@bbbbbbb, случаев"))
        #expect(text.contains("Сломано (dev): \(diff.broken.count)") && text.contains("было"))
        #expect(DiffRender.text(diff, list: 3, markdown: true).hasPrefix("# A machine@"))
    }

    @Test func theTestPartIsCountedNotQuoted() throws {
        let secret = "сокровенное"
        let items = [RunDirectory.wordCase(secret, split: .test, scenario: "slip.cold", suite: "class.test"),
                     RunDirectory.wordCase("видимое", split: .dev)]
        let (a, b, dirs) = try pair(items, b: (.null, nil))
        defer { dirs.forEach { try? FileManager.default.removeItem(atPath: $0) } }
        let diff = try DiffBuilder.build(a, b, options: DiffOptions())
        let text = DiffRender.text(diff, list: 20)
        #expect(!text.contains(secret))
        #expect(diff.brokenTest == ["class.test": 1] || diff.brokenTest.isEmpty)
        #expect(diff.broken.allSatisfy { $0.want != secret })
    }

    @Test func runsScoredByDifferentScorersAreRefused() throws {
        let (a, b, dirs) = try pair(try Array(RunDirectory.cases().prefix(3)), b: (.machine, nil))
        defer { dirs.forEach { try? FileManager.default.removeItem(atPath: $0) } }
        var other = b
        other.scorer += 1
        #expect(throws: EvalError.self) { try DiffBuilder.build(a, other) }
    }

    @Test func casesOnlyInOneRunAreCounted() throws {
        let items = try Array(RunDirectory.cases().prefix(6))
        let dirA = RunDirectory.temporary(), dirB = RunDirectory.temporary()
        defer { [dirA, dirB].forEach { try? FileManager.default.removeItem(atPath: $0) } }
        try RunDirectory.play(items, to: dirA)
        try RunDirectory.play(Array(items.prefix(4)), to: dirB)
        let diff = try DiffBuilder.build(RunData.load(dirA), RunData.load(dirB))
        #expect(diff.common == 4 && diff.onlyA == 2 && diff.onlyB == 0)
    }
}
