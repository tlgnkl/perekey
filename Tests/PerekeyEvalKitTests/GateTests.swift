// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
@testable import PerekeyEvalKit
import Testing

/// Runs read back from files are what the bars read; these tests build them by hand.
enum Runs {
    struct Spec {
        var id: String
        var suite: String
        var scenario = "clean.cold"
        var harm = 0
        var fixed = 0
        var exact = 1
        var missLayout = 0
    }

    static func run(_ specs: [Spec], commit: String = "abc1234") -> RunData {
        let rows = specs.map { spec -> RunData.Row in
            var metrics = Metrics()
            metrics.cases = 1
            metrics.harm = spec.harm
            metrics.fixed = spec.fixed
            metrics.exact = spec.exact
            metrics.fail = spec.exact == 1 ? 0 : 1
            metrics.missLayout = spec.missLayout
            return RunData.Row(id: spec.id, suite: spec.suite, scenario: spec.scenario, split: "dev", epoch: 1, lag: nil,
                               metrics: metrics)
        }
        let info = RunFiles.Info(commit: commit, models: [:], system: "machine", files: [], split: "all")
        return RunData(directory: "-", info: info, scorer: Scorer.version, incidents: Summary.Incidents(), rows: rows,
                       outcomes: [:], events: [], slices: SliceTable(), words: [])
    }

    static let profiles = ProfileFile(profiles: ["chat": ["a": 0.75, "b": 0.25], "dev": ["c": 1, "a": 1]])
}

@Suite struct GateFileTests {
    func parse(_ json: String) throws -> GateFile { try GateFile.parse(Data(json.utf8), file: "gates.json") }

    @Test func readsTheRepositoryFile() throws {
        let gates = try GateFile.read(Repo.path("eval/gates.json"))
        #expect(gates.version == 1)
        #expect(gates.zero.contains { $0.suite == "flow.*" && $0.metric == "fail" })
        #expect(gates.zero.contains { $0.suite == "incidents" && $0.status == "fixed" })
    }

    @Test func theRepositoryFileNamesOnlyMetricsThatExist() throws {
        let gates = try GateFile.read(Repo.path("eval/gates.json"))
        for rule in gates.zero + gates.noWorse { #expect(GateMetric.names.contains(rule.metric), "\(rule.metric)") }
    }

    @Test func aFileThatIsNotInCanonicalOrderStillReads() throws {
        let gates = try parse(#"{"version":1,"zero":[],"noWorse":[{"profile":"*","metric":"harm"}],"accepted":[],"targets":[]}"#)
        #expect(gates.noWorse == [GateFile.Rule(profile: "*", metric: "harm")])
    }

    @Test func rejectsWhatItDoesNotKnow() {
        #expect(throws: EvalError.self) { try parse(#"{"version":2,"zero":[],"noWorse":[],"accepted":[],"targets":[]}"#) }
        #expect(throws: EvalError.self) {
            try parse(#"{"version":1,"zero":[],"noWorse":[],"accepted":[],"targets":[],"extra":1}"#)
        }
        #expect(throws: EvalError.self) {
            try parse(#"{"version":1,"zero":[{"suite":"x","metric":"harm","colour":"red"}],"noWorse":[],"accepted":[],"targets":[]}"#)
        }
        #expect(throws: EvalError.self) {
            try parse(#"{"version":1,"zero":[{"suite":"x","metric":"wrong"}],"noWorse":[],"accepted":[],"targets":[]}"#)
        }
        #expect(throws: EvalError.self) {
            try parse(#"{"version":1,"zero":[],"noWorse":[{"metric":"harm"}],"accepted":[],"targets":[]}"#)
        }
        #expect(throws: EvalError.self) {
            try parse(#"{"version":1,"zero":[],"noWorse":[{"suite":"x","profile":"y","metric":"harm"}],"accepted":[],"targets":[]}"#)
        }
        #expect(throws: EvalError.self) {
            try parse(#"{"version":1,"zero":[{"suite":"x","metric":"harm","direction":"up"}],"noWorse":[],"accepted":[],"targets":[]}"#)
        }
        #expect(throws: EvalError.self) {
            try parse(#"{"version":1,"zero":[],"noWorse":[{"suite":"x","metric":"harm","direction":"sideways"}],"accepted":[],"targets":[]}"#)
        }
    }

    @Test func patternsMatchRunsOfCharacters() {
        #expect(GateMetric.matches("flow.*", "flow.basics"))
        #expect(!GateMetric.matches("flow.*", "flow"))
        #expect(GateMetric.matches("*", "anything"))
        #expect(GateMetric.matches("incidents", "incidents"))
        #expect(!GateMetric.matches("incidents", "incidents2"))
        #expect(GateMetric.matches("a*c*e", "abcde"))
        #expect(!GateMetric.matches("a*c*e", "abde"))
        #expect(!GateMetric.matches("ab*ba", "aba"))
    }
}

@Suite struct GateTests {
    typealias S = Runs.Spec

    func gates(zero: [GateFile.Rule] = [], noWorse: [GateFile.Rule] = [], accepted: [GateFile.Accepted] = []) -> GateFile {
        GateFile(zero: zero, noWorse: noWorse, accepted: accepted)
    }

    @Test func zeroPassesWhenNoCaseFails() {
        let head = Runs.run([S(id: "flow.x/a/1", suite: "flow.x"), S(id: "flow.y/a/2", suite: "flow.y")])
        let result = Gate.check(gates(zero: [.init(suite: "flow.*", metric: "fail")]), head: head, base: nil, profiles: nil, statusOf: [:])
        #expect(result.passed)
        #expect(result.checks.map(\.scope) == ["flow.x", "flow.y"])
        #expect(result.checks.allSatisfy { $0.verdict == .pass && $0.head == 0 })
    }

    @Test func zeroNamesTheCasesThatFail() {
        let head = Runs.run([S(id: "flow.x/a/1", suite: "flow.x", exact: 0), S(id: "flow.x/a/2", suite: "flow.x"),
                             S(id: "flow.x/a/3", suite: "flow.x", exact: 0)])
        let result = Gate.check(gates(zero: [.init(suite: "flow.*", metric: "fail")]), head: head, base: nil, profiles: nil, statusOf: [:])
        #expect(!result.passed)
        #expect(result.checks[0].head == 2)
        #expect(result.checks[0].cases.map(\.id) == ["flow.x/a/1", "flow.x/a/3"])
        #expect(GateRender.text(result).contains("flow.x/a/3"))
    }

    @Test func zeroWithAStatusReadsOnlyThoseCases() {
        let head = Runs.run([S(id: "incidents/a/1", suite: "incidents", exact: 0), S(id: "incidents/a/2", suite: "incidents", exact: 0)])
        let rule = GateFile.Rule(suite: "incidents", status: "fixed", metric: "fail")
        let open = Gate.check(gates(zero: [rule]), head: head, base: nil, profiles: nil,
                              statusOf: ["incidents/a/1": "open", "incidents/a/2": "open"])
        #expect(open.passed, "an incident that waits for a fix is not a bar")
        let fixed = Gate.check(gates(zero: [rule]), head: head, base: nil, profiles: nil,
                               statusOf: ["incidents/a/1": "open", "incidents/a/2": "fixed"])
        #expect(!fixed.passed)
        #expect(fixed.checks[0].cases.map(\.id) == ["incidents/a/2"])
    }

    @Test func aSuiteThatIsNotInTheRunIsSkippedNotPassed() {
        let head = Runs.run([S(id: "flow.x/a/1", suite: "flow.x")])
        let result = Gate.check(gates(zero: [.init(suite: "protect.url", metric: "harm")]), head: head, base: nil, profiles: nil, statusOf: [:])
        #expect(result.passed)
        #expect(result.checks.map(\.verdict) == [.skipped])
    }

    @Test func noWorsePassesOnEqualAndFailsOnGrowth() {
        let rule = GateFile.Rule(suite: "class.*", metric: "harm")
        let base = Runs.run([S(id: "class.a/s/1", suite: "class.a", harm: 1), S(id: "class.a/s/2", suite: "class.a")])
        let same = Gate.check(gates(noWorse: [rule]), head: Runs.run([S(id: "class.a/s/1", suite: "class.a", harm: 1), S(id: "class.a/s/2", suite: "class.a")], commit: "h"),
                              base: base, profiles: nil, statusOf: [:])
        #expect(same.passed)
        let worse = Gate.check(gates(noWorse: [rule]), head: Runs.run([S(id: "class.a/s/1", suite: "class.a", harm: 1), S(id: "class.a/s/2", suite: "class.a", harm: 2)]),
                               base: base, profiles: nil, statusOf: [:])
        #expect(!worse.passed)
        #expect(worse.checks[0].base == 1 && worse.checks[0].head == 3)
        #expect(worse.checks[0].cases == [GateCase(id: "class.a/s/2", head: 2, base: 0)])
    }

    @Test func aTradeOfFewerHarmsForMoreFixesPasses() {
        // Two broken, twelve repaired: the sum fell (docs/eval.md, «Планки»).
        let rule = GateFile.Rule(suite: "class.a", metric: "harm")
        var baseSpecs = (0 ..< 12).map { S(id: "class.a/s/\($0)", suite: "class.a", harm: 1) }
        baseSpecs += [S(id: "class.a/s/20", suite: "class.a"), S(id: "class.a/s/21", suite: "class.a")]
        var headSpecs = (0 ..< 12).map { S(id: "class.a/s/\($0)", suite: "class.a") }
        headSpecs += [S(id: "class.a/s/20", suite: "class.a", harm: 1), S(id: "class.a/s/21", suite: "class.a", harm: 1)]
        let result = Gate.check(gates(noWorse: [rule]), head: Runs.run(headSpecs), base: Runs.run(baseSpecs), profiles: nil, statusOf: [:])
        #expect(result.passed)
        #expect(result.checks[0].base == 12 && result.checks[0].head == 2)
    }

    @Test func upMeansTheCountMustNotFall() {
        let rule = GateFile.Rule(suite: "typos.a", metric: "fixed", direction: "up")
        let base = Runs.run([S(id: "typos.a/s/1", suite: "typos.a", fixed: 2)])
        let fewer = Gate.check(gates(noWorse: [rule]), head: Runs.run([S(id: "typos.a/s/1", suite: "typos.a", fixed: 1)]),
                               base: base, profiles: nil, statusOf: [:])
        #expect(!fewer.passed)
        #expect(fewer.checks[0].cases == [GateCase(id: "typos.a/s/1", head: 1, base: 2)])
        let more = Gate.check(gates(noWorse: [rule]), head: Runs.run([S(id: "typos.a/s/1", suite: "typos.a", fixed: 3)]),
                              base: base, profiles: nil, statusOf: [:])
        #expect(more.passed)
    }

    @Test func casesOnlyInOneRunAreNotCompared() {
        let rule = GateFile.Rule(suite: "class.a", metric: "harm")
        let base = Runs.run([S(id: "class.a/s/1", suite: "class.a")])
        let head = Runs.run([S(id: "class.a/s/1", suite: "class.a"), S(id: "class.a/s/new", suite: "class.a", harm: 5)])
        let result = Gate.check(gates(noWorse: [rule]), head: head, base: base, profiles: nil, statusOf: [:])
        #expect(result.passed)
        #expect(result.notes.contains { $0.contains("общих случаев 1") })
    }

    @Test func aProfileSumsTheCountsOfItsSuitesWithTheirWeights() {
        let rule = GateFile.Rule(profile: "chat", metric: "harm")
        let base = Runs.run([S(id: "a/s/1", suite: "a"), S(id: "b/s/1", suite: "b")])
        // Weights 0.75 and 0.25: a harm in b costs a third of a harm in a.
        let inB = Gate.check(gates(noWorse: [rule]), head: Runs.run([S(id: "a/s/1", suite: "a"), S(id: "b/s/1", suite: "b", harm: 4)]),
                             base: base, profiles: Runs.profiles, statusOf: [:])
        #expect(!inB.passed)
        #expect(inB.checks[0].scope == "profile:chat")
        #expect(inB.checks[0].head == 1.0)
        #expect(inB.checks[0].base == 0)
    }

    @Test func aProfileMissingASuiteRenormalizesTheWeights() {
        let rule = GateFile.Rule(profile: "dev", metric: "harm")
        let base = Runs.run([S(id: "a/s/1", suite: "a", harm: 2)])
        let head = Runs.run([S(id: "a/s/1", suite: "a", harm: 2)])
        let result = Gate.check(gates(noWorse: [rule]), head: head, base: base, profiles: Runs.profiles, statusOf: [:])
        #expect(result.passed)
        #expect(result.checks[0].head == 2, "only suite a is present, so its weight is 1")
    }

    @Test func aProfileWithNoSuiteInTheRunsIsSkipped() {
        let rule = GateFile.Rule(profile: "chat", metric: "harm")
        let run = Runs.run([S(id: "z/s/1", suite: "z")])
        let result = Gate.check(gates(noWorse: [rule]), head: run, base: run, profiles: Runs.profiles, statusOf: [:])
        #expect(result.passed)
        #expect(result.checks.map(\.verdict) == [.skipped])
    }

    @Test func acceptedMakesTheGrowthAnException() {
        let rule = GateFile.Rule(suite: "class.a", metric: "harm")
        let base = Runs.run([S(id: "class.a/s/1", suite: "class.a")])
        let head = Runs.run([S(id: "class.a/s/1", suite: "class.a", harm: 1)])
        let entry = GateFile.Accepted(metric: "harm", scope: "class.*", reason: "the rule is stricter now", pr: 99)
        let result = Gate.check(gates(noWorse: [rule], accepted: [entry]), head: head, base: base, profiles: nil, statusOf: [:])
        #expect(result.passed)
        #expect(result.checks[0].verdict == .accepted)
        let text = GateRender.text(result)
        #expect(text.contains("the rule is stricter now") && text.contains("PR #99"))
        let other = Gate.check(gates(noWorse: [rule], accepted: [.init(metric: "silent", scope: "class.a", reason: "r", pr: 1)]),
                               head: head, base: base, profiles: nil, statusOf: [:])
        #expect(!other.passed, "an exception names its metric")
    }

    @Test func aStandPullRequestShowsNoWorseAndStillGatesZero() {
        var options = Gate.Options()
        options.standPullRequest = true
        let base = Runs.run([S(id: "class.a/s/1", suite: "class.a")])
        let head = Runs.run([S(id: "class.a/s/1", suite: "class.a", harm: 1, exact: 0)])
        let noWorse = Gate.check(gates(noWorse: [.init(suite: "class.a", metric: "harm")]), head: head, base: base, profiles: nil,
                                 statusOf: [:], options: options)
        #expect(noWorse.passed)
        #expect(noWorse.checks[0].verdict == .shown)
        let zero = Gate.check(gates(zero: [.init(suite: "class.a", metric: "fail")]), head: head, base: base, profiles: nil,
                              statusOf: [:], options: options)
        #expect(!zero.passed)
    }

    @Test func withoutABaseNoWorseIsSaidToBeUnchecked() {
        let head = Runs.run([S(id: "class.a/s/1", suite: "class.a", harm: 1)])
        let result = Gate.check(gates(noWorse: [.init(suite: "class.a", metric: "harm")]), head: head, base: nil, profiles: nil, statusOf: [:])
        #expect(result.passed)
        #expect(result.checks.map(\.verdict) == [.skipped])
        #expect(result.notes.contains { $0.contains("не проверены") })
    }

    @Test func theListIsCutAndTheRestCounted() {
        var options = Gate.Options()
        options.listed = 2
        let head = Runs.run((0 ..< 5).map { S(id: "flow.x/a/\($0)", suite: "flow.x", exact: 0) })
        let result = Gate.check(gates(zero: [.init(suite: "flow.x", metric: "fail")]), head: head, base: nil, profiles: nil,
                                statusOf: [:], options: options)
        #expect(result.checks[0].cases.count == 2 && result.checks[0].more == 3)
        #expect(GateRender.text(result).contains("…и ещё 3"))
    }

    @Test func theGatesOfTheRepositoryAreTakenByTheOracleOnTheHandWrittenCases() throws {
        // The oracle types the wanted text, so every hand-written case passes; against itself nothing moves.
        let directory = RunDirectory.temporary()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try RunDirectory.play(RunDirectory.cases(), to: directory, system: .oracle)
        let run = try RunData.load(directory)
        var gates = try GateFile.read(Repo.path("eval/gates.json"))
        // The oracle has the text and nothing else: the checks of a case read the layout and the counts of the system.
        gates.zero.removeAll { $0.metric == "checksFailed" }
        let statuses = Dictionary(uniqueKeysWithValues: try RunDirectory.cases().compactMap { item in item.status.map { (item.id, $0) } })
        let result = Gate.check(gates, head: run, base: run, profiles: nil, statusOf: statuses)
        #expect(result.passed, "\(GateRender.text(result))")
        #expect(result.checks.contains { $0.scope == "flow.basics" && $0.verdict == .pass })
        #expect(result.checks.contains { $0.scope == "incidents" && $0.verdict == .pass })
    }
}

@Suite struct MutantTests {
    /// A case of `suite` and `scenario` whose tokens came out as `outcomes`; `ctx` is the context feature of every token.
    func score(_ suite: String, _ scenario: String, _ outcomes: [Outcome], ctx: String = "cold") -> CaseScore {
        let tokens = outcomes.enumerated().map { index, outcome in
            TokenScore(index: index, measured: true, want: "слово", null: "", out: "", outcome: outcome, form: nil, cascade: false,
                       features: TokenFeatures(lang: "ru", len: "4", pos: "mid", ctx: ctx, cap: "lower", punct: "none", digits: "no",
                                               err: "layout", end: "space", tags: []),
                       trace: [], err: .layout)
        }
        return CaseScore(id: "\(suite)/\(scenario)/\(outcomes.count)\(ctx)", suite: suite, scenario: scenario, split: .dev,
                         scoring: .token, status: nil, tokens: tokens, warmupTokens: 0, words: tokens.count, exact: false,
                         failedChecks: [], lag: nil, wantText: "", nullText: "", outText: "")
    }

    var thresholdZero: Mutant { Mutants.all.first { $0.name == "threshold: 0" }! }
    var contextZero: Mutant { Mutants.all.first { $0.name == "contextBonus: 0" }! }

    @Test func aMutantThatShiftsItsCountPasses() {
        let ordinary = [score("prose.a", "clean.cold", [.ok, .ok, .harm])]
        let mutated = [score("prose.a", "clean.cold", [.harm, .harm, .harm])]
        let findings = Mutants.judge(thresholdZero, ordinary: ordinary, mutated: mutated)
        #expect(findings.map(\.verdict) == [.ok])
        #expect(findings[0].line.contains("1 → 3"))
    }

    @Test func aMutantThatShiftsNothingFailsTheSelfCheck() {
        let ordinary = [score("prose.a", "clean.cold", [.ok, .harm])]
        let findings = Mutants.judge(thresholdZero, ordinary: ordinary, mutated: ordinary)
        #expect(findings.map(\.verdict) == [.fail])
        #expect(findings[0].line.contains("НЕТ СДВИГА"))
    }

    @Test func aCountOfZeroNeedsAtLeastTheFactor() {
        let ordinary = [score("prose.a", "clean.cold", [.ok, .ok])]
        let one = [score("prose.a", "clean.cold", [.harm, .ok])]
        #expect(Mutants.judge(thresholdZero, ordinary: ordinary, mutated: one).map(\.verdict) == [.fail], "1 harm is below the factor 2")
        let two = [score("prose.a", "clean.cold", [.harm, .harm])]
        #expect(Mutants.judge(thresholdZero, ordinary: ordinary, mutated: two).map(\.verdict) == [.ok])
    }

    @Test func otherScenariosAreNotTheMutantsConcern() {
        let ordinary = [score("prose.a", "slip.cold", [.ok, .harm])]
        let findings = Mutants.judge(thresholdZero, ordinary: ordinary, mutated: [])
        #expect(findings.map(\.verdict) == [.skipped])
        #expect(!Mutants.covers(thresholdZero, Cases.make([.type("hi ", on: "ABC")], want: "hi", scenario: "slip.cold")))
        #expect(Mutants.covers(thresholdZero, Cases.make([.type("hi ", on: "ABC")], want: "hi", scenario: "clean.warm")))
    }

    @Test func theSliceCountsOnlyItsTokens() {
        let mutant = Mutant(name: "any", options: nil, settings: nil, expectations: [
            .init(what: "П в срезе ctx=agree", suite: "*", scenarioPrefix: "slip.", slice: "ctx=agree", count: .missLayout,
                  relation: .grows(times: 2)),
        ])
        func miss(_ ctx: String, _ count: Int) -> CaseScore {
            score("prose.a", "slip.warm", Array(repeating: .miss, count: count), ctx: ctx)
        }
        let ordinary = [miss("agree", 2), miss("against", 5)]
        #expect(Mutants.judge(mutant, ordinary: ordinary, mutated: [miss("agree", 4), miss("against", 5)]).first?.verdict == .ok)
        #expect(Mutants.judge(mutant, ordinary: ordinary, mutated: [miss("agree", 2), miss("against", 9)]).first?.verdict == .fail)
    }

    @Test func shrinksNeedsEventsToLose() {
        let slip = Mutants.all.first { $0.name == "contextBonus: 0" }!
        func misses(_ count: Int) -> [CaseScore] { [score("prose.a", "slip.warm", Array(repeating: .miss, count: count))] }
        let finding = { (ordinary: Int, mutated: Int) in Mutants.judge(slip, ordinary: misses(ordinary), mutated: misses(mutated)).first!.verdict }
        #expect(finding(100, 90) == .ok)
        #expect(finding(100, 100) == .fail, "no loss is no shift")
        #expect(finding(100, 99) == .fail, "1 % is below the bar of 2 %")
        #expect(finding(0, 0) == .fail, "nothing to lose is not a shift")
    }

    @Test func notAboveFailsOnGrowth() {
        let ordinary = [score("prose.a", "clean.warm", [.ok, .harm])]
        let fine = Mutants.judge(contextZero, ordinary: ordinary, mutated: ordinary)
        #expect(fine.last?.verdict == .ok)
        let worse = [score("prose.a", "clean.warm", [.harm, .harm])]
        #expect(Mutants.judge(contextZero, ordinary: ordinary, mutated: worse).last?.verdict == .fail)
    }

    /// `selfcheck --only` picks the hand-written suites (flow.basics has no manifest); the suites
    /// it builds a second time are named by `--rebuild`, so `--only` must not look them up.
    @Test func selfCheckOnlyNamesSuitesWithoutManifests() throws {
        let directory = try SuiteFixtures.directory()
        let manifest = """
        {"suite":"t.suite","version":1,"epoch":1,"seed":7,"about":"test","reader":"tatoeba","source":"src",
         "license":"test","sampling":"token","layoutSets":[["ABC","Russian"]],"scenarios":["clean.cold"],
         "tiers":{"ci":400,"full":800},"split":{"dev":20,"by":"unit"}}
        """
        try manifest.write(toFile: directory + "/t.suite.suite.json", atomically: true, encoding: .utf8)
        let parsed = try Arguments(["--suites", directory, "--only", "flow.basics,t.suite"])
        #expect(throws: (any Error).self) { try EvalCommands.BuildSettings(parsed).manifests() }
        let ignoring = try EvalCommands.BuildSettings(parsed, ignoringOnly: true)
        #expect(try ignoring.manifests().map { $0.suite } == ["t.suite"])
    }

    @Test func everyMutantNamesOptionsTheClassifierHas() throws {
        for mutant in Mutants.all {
            if let json = mutant.options { _ = try ClassifierOptions.parse(json) }
            if let settings = mutant.settings { #expect(EvalSettings.names.contains(settings), "\(settings)") }
            #expect(!mutant.expectations.isEmpty)
        }
    }
}
