// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
@testable import PerekeyEvalKit
import Testing

@Suite struct LayoutCopiesTests {
    /// eval/layouts/ copies the core's fixtures: a layout changed in one place
    /// and not the other is a red test.
    @Test(arguments: ["ABC", "Russian", "RussianWin", "Ukrainian", "Ukrainian-PC", "Byelorussian", "Kazakh", "US",
                      "USExtended"])
    func copiesEqualTheOriginals(name: String) throws {
        let copy = try Data(contentsOf: URL(fileURLWithPath: Repo.path("eval/layouts/\(name).json")))
        let original = try Data(contentsOf: URL(fileURLWithPath: Repo.path("Tests/PerekeyCoreTests/Fixtures/\(name).json")))
        #expect(copy == original)
    }

    @Test func everyCopyIsListed() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Repo.path("eval/layouts")).sorted()
        #expect(names == ["ABC.json", "Byelorussian.json", "Kazakh.json", "Russian.json", "RussianWin.json", "US.json",
                          "USExtended.json", "Ukrainian-PC.json", "Ukrainian.json"].sorted())
    }
}

@Suite struct SettingsPresetTests {
    /// Field by field: a new field or a new default in the core is a red test
    /// until the preset says what it does with it.
    @Test func theDefaultPresetIsTheCoresDefault() throws {
        let preset = try #require(EvalSettings.preset("default"))
        let core = Settings()
        let presetFields = Mirror(reflecting: preset).children, coreFields = Mirror(reflecting: core).children
        #expect(presetFields.count == coreFields.count)
        for (mine, theirs) in zip(presetFields, coreFields) {
            #expect(mine.label == theirs.label)
            #expect(String(describing: mine.value) == String(describing: theirs.value), "\(mine.label ?? "?")")
        }
        let corrections = Mirror(reflecting: preset.corrections).children
        let coreCorrections = Mirror(reflecting: TextCorrections()).children
        #expect(corrections.count == coreCorrections.count)
        for (mine, theirs) in zip(corrections, coreCorrections) {
            #expect(mine.label == theirs.label)
            #expect(mine.value as? Bool == theirs.value as? Bool, "\(mine.label ?? "?")")
        }
        #expect(preset == core)
    }

    @Test func thePresetsSayWhatTheyTurnOn() throws {
        let all = try #require(EvalSettings.preset("all"))
        #expect(all.autoswitch && all.typoCorrection)
        #expect(all.corrections == TextCorrections(phraseRetype: true, doubleCapitals: true, capsLock: true,
                                                   abbreviations: true, yo: true, hyphen: true))
        let layoutOnly = try #require(EvalSettings.preset("layout-only"))
        #expect(layoutOnly.autoswitch && !layoutOnly.typoCorrection && !layoutOnly.corrections.correctsWords)
        let off = try #require(EvalSettings.preset("off"))
        #expect(!off.autoswitch && !off.typoCorrection && !off.corrections.correctsWords)
        #expect(!off.corrections.phraseRetype)
        #expect(off.hotkeys == Settings().hotkeys, "the shortcuts work in off")
        #expect(EvalSettings.preset("nothing") == nil)
    }

    @Test func theCaseAddsItsWords() throws {
        let settings = try EvalSettings.settings(for: Env(exceptions: ["ghbdtn"], alwaysFix: ["ок": "ок"]))
        #expect(settings.exceptions == ["ghbdtn"])
        #expect(settings.alwaysFix == ["ок": "ок"])
    }
}

@Suite struct ClassifierOptionsTests {
    /// The table names every field of `Classifier.Options`.
    @Test func theTableKnowsEveryField() {
        let fields = Mirror(reflecting: Classifier.Options()).children.compactMap(\.label).sorted()
        #expect(fields == ClassifierOptions.names)
    }

    @Test func everyFieldIsSet() throws {
        for name in ClassifierOptions.names {
            let options = try ClassifierOptions.parse("{\"\(name)\": 7}")
            let value = Mirror(reflecting: options).children.first { $0.label == name }?.value
            #expect(String(describing: value!) == "7.0" || String(describing: value!) == "7", "\(name)")
        }
    }

    @Test func unknownNamesAndBadValuesAreErrors() {
        #expect(throws: EvalError.self) { try ClassifierOptions.parse(#"{"treshold": 3}"#) }
        #expect(throws: EvalError.self) { try ClassifierOptions.parse(#"{"threshold": "3"}"#) }
        #expect(throws: EvalError.self) { try ClassifierOptions.parse(#"{"knownRank": 300}"#) }
        #expect(throws: EvalError.self) { try ClassifierOptions.parse("[1]") }
    }
}

@Suite struct DataSeparationTests {
    /// The model builder never reads the bench's data (docs/eval.md).
    @Test func theModelBuilderDoesNotReadEval() throws {
        let files = ["Sources/perekey-model/main.swift", "Sources/PerekeyModelKit/ModelBuild.swift", "scripts/build-model.sh"]
        for file in files {
            let text = try String(contentsOfFile: Repo.path(file), encoding: .utf8)
            #expect(!text.contains("eval/"), "\(file)")
            #expect(!text.contains("PerekeyEvalKit"), "\(file)")
        }
    }
}

@Suite struct RunTests {
    func cases() throws -> [EvalCase] {
        try CaseCodec.read(file: Repo.path("eval/cases/flow.basics.jsonl"))
            + CaseCodec.read(file: Repo.path("eval/cases/incidents.jsonl"))
    }

    @Test func twoRunsGiveTheSameBytes() throws {
        func run() throws -> (String, String) {
            var config = Runner.Config()
            config.classifier = Repo.classifier
            var runner = Runner(config: config, library: Repo.library)
            let scores = try cases().map { try runner.play($0).score }
            return try (RunFiles.casesTSV(scores), RunFiles.summaryJSON(scores))
        }
        let first = try run(), second = try run()
        #expect(first == second)
    }

    @Test func nullHarmsAndFixesNothingAndOracleIsExact() throws {
        for item in try cases() {
            let null = try Cases.play(item, system: .null)
            #expect(!null.score.tokens.contains { $0.outcome == .harm || $0.outcome == .fixed }, "\(item.id)")
            let oracle = try Cases.play(item, system: .oracle)
            if item.effectiveScoring == .token {
                #expect(oracle.score.exact, "\(item.id)")
            }
        }
    }

    @Test func theRunFilesHaveTheirColumns() throws {
        let item = Cases.make([.type("привет ", on: "Russian")], want: "привет",
                              tokens: [TokenSpec(t: "привет", lang: "ru", err: .layout)], scenario: "slip.cold")
        let played = try Cases.play(item)
        let tsv = RunFiles.casesTSV([played.score])
        #expect(tsv == "id\twords\twarmup\toutcomes\texact\tlag\tchecks\n\(item.id)\t1\t0\tF\t1\t0\t-\n")
        var checked = item
        checked.checks = [.layout("ABC")]
        let failed = try Cases.play(checked)
        #expect(failed.score.exact, "checks do not touch exact")
        #expect(failed.score.failedChecks == [.layout("ABC")])
        #expect(RunFiles.casesTSV([failed.score]).hasSuffix("\t1\t0\tfailed\n"))
        #expect(Summary([failed.score]).total.checksFailed == 1)
        #expect(try RunFiles.eventsJSONL([played.score]).contains(#""outcome":"fixed""#))
        let summary = Summary([played.score])
        #expect(summary.groups.count == 1)
        #expect(summary.total.fixed == 1)
        #expect(summary.total.rates.missLayout == 0)
    }
}

/// Rule 2.8: the words of the test part reach no file and no message
/// without `--reveal-test`.
@Suite struct TestPartPrivacyTests {
    static let secret = "сокровенное"

    func secretCase(split: EvalCase.Split = .test) -> EvalCase {
        var item = EvalCase(suite: "privacy", scenario: "slip.cold", split: split, layouts: ["ABC", "Russian"],
                            start: "ABC", script: [.type("\(Self.secret) ", on: "Russian")], want: Self.secret,
                            tokens: [TokenSpec(t: Self.secret, lang: "ru", err: .layout)])
        item = try! item.identified()
        return item
    }

    func runFiles(_ item: EvalCase, reveal: Bool) throws -> String {
        var config = Runner.Config()
        config.classifier = Repo.classifier
        config.revealTest = reveal
        var runner = Runner(config: config, library: Repo.library)
        let score = try runner.play(item).score
        let info = RunFiles.Info(commit: "x", models: [:], system: "machine", files: [], split: "all",
                                 testRevealed: reveal)
        return try [RunFiles.casesTSV([score]), RunFiles.eventsJSONL([score]), RunFiles.summaryJSON([score]),
                    RunFiles.runJSON(info)].joined()
    }

    @Test func runFilesHideTheWordsOfTheTestPart() throws {
        let hidden = try runFiles(secretCase(), reveal: false)
        #expect(!hidden.contains(Self.secret))
        #expect(!hidden.contains("cjrhjdtyyjt"), "nor the keys typed in the other layout")
        #expect(hidden.contains("(test)"))
        #expect(hidden.contains(#""testRevealed" : false"#))
        let revealed = try runFiles(secretCase(), reveal: true)
        #expect(revealed.contains(Self.secret))
        #expect(revealed.contains(#""testRevealed" : true"#))
        let dev = try runFiles(secretCase(split: .dev), reveal: false)
        #expect(dev.contains(Self.secret))
    }

    @Test func theCheckDoesNotQuoteTheTestPart() {
        var broken = secretCase()
        broken.tokens = [TokenSpec(t: Self.secret + "ы", lang: "ru", err: .layout)]
        broken.script = [.type("\(Self.secret)© ", on: "Russian")]
        let problems = CaseCheck.problems(broken, layouts: Repo.library)
        #expect(!problems.isEmpty)
        #expect(!problems.joined().contains(Self.secret))
        #expect(!problems.joined().contains("©"))
        let revealed = CaseCheck.problems(broken, layouts: Repo.library, reveal: true)
        #expect(revealed.joined().contains(Self.secret))
    }
}
