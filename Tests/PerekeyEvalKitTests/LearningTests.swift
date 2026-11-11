// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
import PerekeyDesk
@testable import PerekeyEvalKit
import Testing

/// The learning sets (docs/eval.md, «Обучение»): options, manifests, the
/// reactor, the days. The fixture model knows «привет», so «ghbdtn» is the
/// word Perekey switches; the real vocabulary needs the real model.
@Suite struct LearningTests {
    // MARK: - Options

    @Test func theTableNamesEveryFieldOfLearningOptions() {
        let fields = Set(Mirror(reflecting: LearningOptions()).children.compactMap(\.label))
        #expect(fields == Set(LearningOptionsTable.names), "a field of LearningOptions the table does not know")
        let defaults = LearningOptions()
        for name in LearningOptionsTable.names {
            var options = LearningOptions()
            // 7 is none of the defaults, so the setter must change the field.
            try! LearningOptionsTable.table[name]!(&options, 7)
            #expect(options != defaults, "\(name) does not set its field")
        }
    }

    @Test func optionsGoToTheirOwnTable() throws {
        let (learning, classifier) = try LearningOptionsTable.parse(#"{"frequentThreshold": 4, "threshold": 12}"#)
        #expect(learning.frequentThreshold == 4)
        #expect(classifier.threshold == 12)
        #expect(learning.plausibleThreshold == LearningOptions().plausibleThreshold)
    }

    @Test func badOptionsAreErrors() {
        #expect(throws: EvalError.self) { try LearningOptionsTable.parse(#"{"nothing": 1}"#) }
        #expect(throws: EvalError.self) { try LearningOptionsTable.parse(#"{"frequentThreshold": "3"}"#) }
        #expect(throws: EvalError.self) { try LearningOptionsTable.parse(#"{"frequentThreshold": 2.5}"#) }
        #expect(throws: EvalError.self) { try LearningOptionsTable.parse(#"{"frequentThreshold": true}"#) }
        #expect(throws: EvalError.self) { try LearningOptionsTable.parse("[1]") }
    }

    @Test func aGridIsTheProductOfItsLists() throws {
        let points = try LearningReport.points(grid: #"{"frequentThreshold": [2, 3], "backspaceWeight": [0, 1, 2]}"#)
        #expect(points.count == 6)
        #expect(points.first.map { $0.map(\.0) } == ["backspaceWeight", "frequentThreshold"], "names in order")
        #expect(try LearningReport.points(grid: #"{"manifest.accident": [0, 0.5]}"#).count == 2)
        #expect(throws: EvalError.self) { try LearningReport.points(grid: #"{"manifest.days": [1]}"#) }
        #expect(throws: EvalError.self) { try LearningReport.points(grid: #"{"nothing": [1]}"#) }
        #expect(throws: EvalError.self) { try LearningReport.points(grid: #"{"newDayBonus": 1}"#) }
        #expect(throws: EvalError.self) { try LearningReport.points(grid: "{}") }
    }

    // MARK: - Manifest and vocabulary

    static let manifestJSON = """
    {"name":"learning.test","layouts":["ABC","Russian"],"vocabulary":"v.tsv","days":3,"messagesPerDay":5,
     "zipf":1,"meantOther":0,"backspaceShare":0,"accident":0,"answer":"everywhere","seed":1}
    """

    func manifest(_ edit: (inout [String: Any]) -> Void = { _ in }) throws -> LearningManifest {
        var object = try #require(JSONSerialization.jsonObject(with: Data(Self.manifestJSON.utf8)) as? [String: Any])
        edit(&object)
        return try LearningManifest.parse(JSONSerialization.data(withJSONObject: object), label: "test")
    }

    @Test func aManifestIsStrict() throws {
        _ = try manifest()
        #expect(throws: EvalError.self) { try manifest { $0["extra"] = 1 } }
        #expect(throws: EvalError.self) { try manifest { $0["name"] = "personal.test" } }
        #expect(throws: EvalError.self) { try manifest { $0["layouts"] = ["ABC"] } }
        #expect(throws: EvalError.self) { try manifest { $0["meantOther"] = 1.5 } }
        #expect(throws: EvalError.self) { try manifest { $0["days"] = 0 } }
        #expect(throws: EvalError.self) { try manifest { $0["settings"] = "nothing" } }
        #expect(throws: EvalError.self) { try manifest { $0["answer"] = "maybe" } }
        #expect(throws: EvalError.self) { try manifest { $0["accidentContinues"] = 0.7; $0["accidentRetypes"] = 0.7 } }
        #expect(throws: EvalError.self) { try manifest { $0.removeValue(forKey: "seed") } }
    }

    @Test func theSetsOfTheRepositoryAreRead() throws {
        let directory = Repo.path("eval/learning")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory).filter { $0.hasSuffix(".json") }.sorted()
        #expect(files == ["learning.control.json", "learning.jrtq.json", "learning.personal.json"])
        for file in files {
            let manifest = try LearningManifest.read(file: "\(directory)/\(file)")
            let vocabulary = try LearningVocabulary.read(file: "\(directory)/\(manifest.vocabulary)")
            #expect(file == manifest.name + ".json")
            // Every word has a reading to type in the other layout.
            _ = try LearningSimulation(.init(manifest: manifest, vocabulary: vocabulary, library: Repo.library,
                                             classifier: nil))
        }
        let personal = try LearningVocabulary.read(file: "\(directory)/learning.personal.tsv")
        #expect(personal.entries.count == 50)
    }

    @Test func aVocabularyIsWordsAndLayouts() throws {
        let text = "# comment\nvs\tABC\t9\n\nшт\tRussian\n"
        let vocabulary = try LearningVocabulary.parse(text, label: "t")
        #expect(vocabulary.entries == [.init(word: "vs", layout: "ABC"), .init(word: "шт", layout: "Russian")])
        #expect(throws: EvalError.self) { try LearningVocabulary.parse("vs\tABC\nvs\tABC\n", label: "t") }
        #expect(throws: EvalError.self) { try LearningVocabulary.parse("vs\n", label: "t") }
        #expect(throws: EvalError.self) { try LearningVocabulary.parse("# nothing\n", label: "t") }
    }

    @Test func aShareOfTheManifestCanBeSweptAndIsChecked() throws {
        let manifest = try manifest()
        #expect(try manifest.overriding("manifest.accident", 0.4).accident == 0.4)
        #expect(throws: EvalError.self) { try manifest.overriding("manifest.accident", 1.4) }
        #expect(throws: EvalError.self) { try manifest.overriding("manifest.days", 3) }
        // The sweep of a share changes the run.
        let calm = try LearningSimulation.run(Self.config { $0["meantOther"] = 1 })
        let shaky = try LearningSimulation.run(Self.config { $0["meantOther"] = 1; $0["accident"] = 1 })
        #expect(calm.totals.accidents == 0 && shaky.totals.accidents > 0)
    }

    @Test func aWordMustBeInTheStoredFormAndTypeable() throws {
        let manifest = try manifest()
        func build(_ word: String, _ layout: String) throws {
            _ = try LearningSimulation(.init(manifest: manifest, vocabulary: .init(entries: [.init(word: word, layout: layout)]),
                                             library: Repo.library, classifier: nil))
        }
        try build("ghbdtn", "ABC")
        #expect(throws: EvalError.self) { try build("Ghbdtn", "ABC") }
        #expect(throws: EvalError.self) { try build("ghbdtn", "Ukrainian") }
        #expect(throws: EvalError.self) { try build("ghbdtn", "Russian") }
    }

    // MARK: - The vocabulary of a run

    static func event(_ id: String, want: String, outcome: String = "harm", form: String = "layout", err: String = "none",
                      lang: String = "en") -> String {
        #"{"features":{"err":"\#(err)","lang":"\#(lang)"},"form":"\#(form)","id":"\#(id)","index":0,"outcome":"\#(outcome)","want":"\#(want)"}"#
    }

    @Test func theVocabularyTakesTheHarmOfWordsTypedAsMeant() throws {
        let lines = [
            Self.event("class.short/clean.cold/a", want: "vs"),
            Self.event("class.short/clean.warm/b", want: "VS"),
            Self.event("class.short/clean.cold/c", want: "шт", lang: "ru"),
            Self.event("class.short/slip.cold/d", want: "bp"),
            Self.event("class.short/clean.cold/e", want: "(test)"),
            Self.event("class.short/clean.cold/f", want: "x"),
            Self.event("class.short/clean.cold/g", want: "a1b"),
            Self.event("class.short/clean.cold/h", want: "nj", outcome: "botched"),
            Self.event("class.short/clean.cold/i", want: "nt", form: "edit"),
            Self.event("class.short/clean.cold/j", want: "dj", err: "layout"),
            Self.event("class.short/clean.cold/k", want: "ye", lang: "uk"),
        ].joined(separator: "\n")
        let candidates = try VocabularyPicker.candidates(eventsJSONL: lines, runJSON: Data(#"{"testRevealed":false}"#.utf8))
        #expect(candidates.sorted { $0.word < $1.word } == [
            .init(word: "vs", layout: "ABC", harm: 2), .init(word: "шт", layout: "Russian", harm: 1),
        ])
    }

    @Test func theVocabularyIsChosenByHarmThenAlphabet() {
        let candidates = [("b", 2), ("a", 2), ("c", 5), ("d", 1)].map {
            VocabularyPicker.Candidate(word: $0.0, layout: "ABC", harm: $0.1)
        }
        #expect(VocabularyPicker.choose(candidates, size: 3).map(\.word) == ["c", "a", "b"])
        #expect(VocabularyPicker.choose(candidates.reversed(), size: 3).map(\.word) == ["c", "a", "b"])
    }

    // MARK: - The reactor

    @Test(arguments: [
        (true, false, Typist.Reactor.Reaction.nothing),
        (false, true, Typist.Reactor.Reaction.undoByButton),
        (false, false, Typist.Reactor.Reaction.convert),
    ])
    func theReactorAnswersWhatItSees(asMeant: Bool, corrected: Bool, reaction: Typist.Reactor.Reaction) {
        var options = Typist.Reactor.Options()
        options.backspaceShare = 0
        options.accident = 1
        var reactor = Typist.Reactor(options: options, seed: 1)
        #expect(reactor.react(.init(asMeant: asMeant, corrected: corrected)) == reaction)
    }

    @Test func aWrongCorrectionIsUndoneByBackspaceByItsShare() {
        for (share, expected) in [(0.0, Typist.Reactor.Reaction.undoByButton), (1.0, .undoByBackspace)] {
            var options = Typist.Reactor.Options()
            options.backspaceShare = share
            var reactor = Typist.Reactor(options: options, seed: 7)
            for _ in 0..<50 { #expect(reactor.react(.init(asMeant: false, corrected: true)) == expected) }
        }
        var options = Typist.Reactor.Options()
        options.backspaceShare = 0.5
        var reactor = Typist.Reactor(options: options, seed: 7)
        let backspaces = (0..<1000).filter { _ in reactor.react(.init(asMeant: false, corrected: true)) == .undoByBackspace }
        #expect((400...600).contains(backspaces.count), "half of 1000, got \(backspaces.count)")
    }

    @Test func aRightCorrectionIsFollowedByAnAccidentByItsShare() {
        var options = Typist.Reactor.Options()
        options.accident = 0.2
        options.accidentContinues = 0.25
        options.accidentRetypes = 0.25
        var reactor = Typist.Reactor(options: options, seed: 3)
        var ends: [Typist.Reactor.AccidentEnd: Int] = [:]
        var accidents = 0
        for _ in 0..<5000 {
            if case let .accidentalBackspace(end) = reactor.react(.init(asMeant: true, corrected: true)) {
                accidents += 1
                ends[end, default: 0] += 1
            }
        }
        #expect((850...1150).contains(accidents), "a fifth of 5000, got \(accidents)")
        for end in [Typist.Reactor.AccidentEnd.continues, .retype] {
            #expect((150...350).contains(ends[end] ?? 0), "a quarter of \(accidents), got \(ends[end] ?? 0)")
        }
        #expect((350...650).contains(ends[.punctuation] ?? 0), "the rest")
    }

    @Test func theReactorIsDeterministic() {
        func run() -> [Typist.Reactor.Reaction] {
            var options = Typist.Reactor.Options()
            options.accident = 0.5
            var reactor = Typist.Reactor(options: options, seed: 99)
            return (0..<200).map { reactor.react(.init(asMeant: $0 % 3 != 0, corrected: $0 % 2 == 0)) }
        }
        #expect(run() == run())
    }

    // MARK: - The typist for steps

    @Test func stepsStartWhereTheyAreToldAndEndWithoutThePause() throws {
        let typist = Typist()
        let item = Cases.make([.type("ab", on: "ABC")], want: "ab")
        let whole = try typist.events(for: item, layouts: Repo.library)
        let steps = try typist.events(of: [.type("ab", on: "ABC")], env: Env(), layouts: Repo.library, label: "t")
        #expect(steps == whole, "the same steps give the events of the case")
        let part = try typist.events(of: [.type("ab", on: "ABC")], env: Env(), layouts: Repo.library, label: "t",
                                     startingAt: 5000, endPause: false)
        #expect(part.count == whole.count - 1)
        #expect(part.first?.time == 5000)
        #expect(part.map(\.event) == whole.dropLast().map(\.event))
    }

    // MARK: - The days

    static func config(_ edit: (inout [String: Any]) -> Void = { _ in }, words: [String] = ["ghbdtn"],
                       options: LearningOptions = LearningOptions()) throws -> LearningSimulation.Config
    {
        var object = try #require(JSONSerialization.jsonObject(with: Data(manifestJSON.utf8)) as? [String: Any])
        object["messagesPerDay"] = 10
        edit(&object)
        let manifest = try LearningManifest.parse(JSONSerialization.data(withJSONObject: object), label: "test")
        let vocabulary = LearningVocabulary(entries: words.map { .init(word: $0, layout: "ABC") })
        return LearningSimulation.Config(manifest: manifest, vocabulary: vocabulary, library: Repo.library,
                                         classifier: Repo.classifier, options: options)
    }

    /// Every threshold of the options at one number: whichever kind of decision the machine reports, the same bar.
    static func bar(_ value: Int) -> LearningOptions {
        var options = LearningOptions()
        options.plausibleThreshold = value
        options.ordinaryThreshold = value
        options.frequentThreshold = value
        return options
    }

    @Test func aWordPerekeyFalselySwitchesIsLearnedAfterAnUndoThatReachesTheBar() throws {
        // «ghbdtn» → «привет»; a button undo is 2 evidence, the bar of the fixture's decision is 2.
        let run = try LearningSimulation.run(Self.config())
        let word = try #require(run.words.first)
        #expect(word.keep == 30)
        #expect(word.keepInterventions == 1)
        #expect(word.harmed == 1)
        #expect(word.learnedDay == 0)
        #expect(word.silent == true)
        #expect(run.totals.interventionsToSilence == 1)
        #expect(run.totals.asked == 1)
        #expect(run.totals.learnedWords == 1)
        #expect(run.totals.falseLearned == 0)
        #expect(run.days[0].interventions == 1)
        #expect(run.totals.interventionsDay1 == 1)
        #expect(run.totals.interventionsLastDay == 0, "silent once learned")
    }

    @Test func aHigherBarTakesMoreUndos() throws {
        // 2 evidence for each button undo: a bar of 1 or 2 takes one, 3 or 4 two, 5 or 6 three.
        for (bar, undos) in [(1, 1), (2, 1), (3, 2), (4, 2), (5, 3), (6, 3)] {
            let run = try LearningSimulation.run(Self.config(options: Self.bar(bar)))
            #expect(run.words[0].keepInterventions == undos, "bar \(bar)")
            #expect(run.words[0].silent == true)
        }
    }

    @Test func backspaceUndosCountOneEachWhenTheWordIsKept() throws {
        // backspaceShare 1: every undo is a Backspace followed by the Return that ends the message: evidence 1.
        let one = try LearningSimulation.run(Self.config({ $0["backspaceShare"] = 1 }, options: Self.bar(3)))
        #expect(one.words[0].keepInterventions == 3, "1 + 1 + 1 ≥ 3")
        var options = Self.bar(3)
        options.backspaceWeight = 0
        let none = try LearningSimulation.run(Self.config({ $0["backspaceShare"] = 1 }, options: options))
        #expect(none.words[0].keepInterventions == none.words[0].keep, "a Backspace that counts nothing never teaches")
        #expect(none.totals.learnedWords == 0)
    }

    @Test func aWordThatIsNotAnsweredStaysACandidate() throws {
        let run = try LearningSimulation.run(Self.config { $0["answer"] = "never" })
        #expect(run.totals.learnedWords == 0)
        #expect(run.words[0].harmed == run.words[0].keep, "every keep token is switched")
        #expect(run.words[0].keepInterventions == run.words[0].keep)
        #expect(run.words[0].silent == false)
        #expect(run.totals.asked > 0)
    }

    @Test func aWordLearnedHereIsAskedOnlyInItsApp() throws {
        let apps = ["com.apple.TextEdit", "com.apple.Notes"]
        let run = try LearningSimulation.run(Self.config {
            $0["answer"] = "here"
            $0["apps"] = apps
            $0["appsForEverywhere"] = nil
        })
        // «Только здесь» in the first app learns it there; the second app takes one undo more.
        #expect(run.words[0].keepInterventions == 2)
        #expect(run.words[0].learnedDay == 0)
        #expect(run.words[0].silent == true)
    }

    @Test func aLearnedWordMeantTheOtherWayNeedsARetypeAndIsForgotten() throws {
        let run = try LearningSimulation.run(Self.config { $0["meantOther"] = 0.3; $0["days"] = 6 })
        let word = run.words[0]
        #expect(word.learnedDay != nil)
        #expect(word.neededAfterLearned > 0, "the word was learned and the person meant «привет» later")
        #expect(word.unlearned > 0, "the retype by hand forgets it (WordRules.unlearn)")
        #expect(word.otherInterventions > 0)
        #expect(run.totals.learnedThenNeeded == 1)
    }

    @Test func theCaseOfJrtqLearnsNothing() throws {
        // The person always means «привет»; each time a Backspace meant for the space undoes the switch and a comma follows.
        let run = try LearningSimulation.run(Self.config {
            $0["meantOther"] = 1
            $0["accident"] = 1
            $0["accidentContinues"] = 0
            $0["accidentRetypes"] = 0
            $0["days"] = 5
        })
        #expect(run.totals.accidents == 50)
        #expect(run.totals.learnedWords == 0)
        #expect(run.totals.falseLearned == 0)
        #expect(run.totals.counted == 0, "a Backspace before punctuation gives no evidence")
        #expect(run.totals.oldRuleWouldLearn == 1, "the rule before evidence learned the word at the first one")
        #expect(run.totals.leftWrong == 50, "the word stays «ghbdtn,» in the text")
    }

    @Test func aBackspaceThatTheWordSurvivesTeachesAWrongWord() throws {
        // The same Backspaces, but the person types on and the word stays as typed: evidence 1 each.
        var options = LearningOptions()
        options.frequentThreshold = 1
        let run = try LearningSimulation.run(Self.config({
            $0["meantOther"] = 1
            $0["accident"] = 1
            $0["accidentContinues"] = 1
        }, options: options))
        #expect(run.totals.falseLearned == 1)
        #expect(run.totals.falseLearnedPer1000Accidents.map { $0 > 0 } == true)
    }

    // MARK: - The review of E8

    /// The committed «jrtq» set, played with a model that knows «окей» (the fixture model plus the word).
    static func jrtq(_ edit: (inout LearningManifest) throws -> Void = { _ in }, options: LearningOptions = LearningOptions())
        throws -> LearningRun
    {
        let directory = Repo.path("eval/learning")
        var manifest = try LearningManifest.read(file: "\(directory)/learning.jrtq.json")
        try edit(&manifest)
        let vocabulary = try LearningVocabulary.read(file: "\(directory)/\(manifest.vocabulary)")
        let classifier = Classifier(model: ModelFixture.model(withRussianWords: [("окей", 150)], hyphenByRule: []))
        return try LearningSimulation.run(.init(manifest: manifest, vocabulary: vocabulary, library: Repo.library,
                                                classifier: classifier, options: options))
    }

    @Test func theCommittedJrtqSetLearnsNothingBecauseOfItsRule() throws {
        let run = try Self.jrtq()
        // The set is played: Backspaces happen, and Perekey switched «jrtq» every time.
        #expect(run.totals.accidents > 0)
        #expect(run.totals.accidents == run.totals.other, "each «jrtq» was switched, then undone by the Backspace for the space")
        #expect(run.totals.learnedWords == 0)
        #expect(run.totals.counted == 0)
        #expect(run.totals.falseLearned == 0)
        // Control 1: the rule before the evidence learned the word from the same Backspaces.
        #expect(run.totals.oldRuleWouldLearn == 1)
        // Control 2: the same set, the same machine, but the person types on after the Backspace
        // (it counts) and the threshold is 1: the word is learned. So the zero is the rule, not the set.
        let continuing = try Self.jrtq({ $0 = try $0.overriding("manifest.accidentContinues", 1) }, options: Self.bar(1))
        #expect(continuing.totals.learnedWords == 1)
        #expect(continuing.totals.falseLearned == 1)
        // The rule at the thresholds of today and a continuing person: two Backspaces are enough, too.
        let today = try Self.jrtq({ $0 = try $0.overriding("manifest.accidentContinues", 1) })
        #expect(today.totals.learnedWords == 1)
    }

    @Test func aWordIsLearnedFalselyWhenTheAccidentsGaveItsPoints() throws {
        // «ghbdtn» is meant as typed and as «привет»; the bar of 3 needs a Backspace that a real undo does not give.
        // A button undo is 2 points, an accidental Backspace that the person types on after is 1 (+1 on a new day).
        var decisive = 0
        var keptAndFalse = 0
        for seed in 1...30 {
            let run = try LearningSimulation.run(Self.config({
                $0["meantOther"] = 0.5
                $0["accident"] = 1
                $0["accidentContinues"] = 1
                $0["backspaceShare"] = 0
                $0["days"] = 4
                $0["seed"] = seed
            }, options: Self.bar(3)))
            let word = try #require(run.words.first)
            #expect(run.totals.falseLearned == (word.learnedByAccident ? 1 : 0))
            #expect(word.accidentPoints >= 0)
            if word.learnedByAccident {
                decisive += 1
                #expect(word.learnedDay != nil)
                if word.keep > 0 { keptAndFalse += 1 }
            }
        }
        #expect(decisive > 0, "the accidents taught a word in some seeds")
        #expect(keptAndFalse > 0, "a word the person also meant as typed is counted: the old «keep == 0» rule missed it")
    }

    @Test func aWordLearnedByRealUndosAloneIsNotLearnedFalsely() throws {
        // No accidents: the same loop teaches the word by the button, and nothing is false.
        let run = try LearningSimulation.run(Self.config({ $0["accident"] = 1; $0["meantOther"] = 0 }))
        #expect(run.totals.learnedWords == 1)
        #expect(run.totals.falseLearned == 0)
        #expect(run.words[0].accidentPoints == 0)
    }

    @Test func wordsThatNeverWentSilentAreCountedNextToTheMean() throws {
        var run = try LearningSimulation.run(Self.config())
        run.totals.wordsHarmed = 5
        run.totals.wordsSilent = 3
        #expect(run.totals.wordsNeverSilent == 2)
        let text = LearningReport.text(try manifest(), runs: [run])
        #expect(text.contains("words that never went silent"))
        #expect(text.contains("only the words that went silent"))
        let table = LearningReport.sweepTable([.init(point: [], name: "learning.test", runs: [run])], seeds: 1)
        let header = try #require(table.split(separator: "\n").first).split(separator: "\t").map(String.init)
        #expect(header.contains("neverSilent"))
        #expect(header.contains("toSilence(silent only)"))
    }

    @Test func theVocabularyRefusesARunWithTheTestRevealedOrAPersonalOne() throws {
        let events = Self.event("class.short/clean.cold/a", want: "vs")
        func info(_ json: String) -> Data { Data(json.utf8) }
        #expect(try VocabularyPicker.candidates(eventsJSONL: events, runJSON: info(#"{"testRevealed":false,"commit":"c"}"#)).count == 1)
        #expect(try VocabularyPicker.candidates(eventsJSONL: events, runJSON: info(#"{"commit":"c","personal":false}"#)).count == 1)
        #expect(throws: EvalError.self) {
            try VocabularyPicker.candidates(eventsJSONL: events, runJSON: info(#"{"testRevealed":true}"#))
        }
        #expect(throws: EvalError.self) {
            try VocabularyPicker.candidates(eventsJSONL: events, runJSON: info(#"{"testRevealed":false,"personal":true}"#))
        }
        #expect(throws: EvalError.self) { try VocabularyPicker.candidates(eventsJSONL: events, runJSON: nil) }
        #expect(throws: EvalError.self) { try VocabularyPicker.candidates(eventsJSONL: events, runJSON: info("[1]")) }
    }

    @Test func aGridIsCheckedBeforeAnyRun() throws {
        // A bad value is an error of the grid, not of the point that happens to come last.
        #expect(throws: EvalError.self) { try LearningReport.points(grid: #"{"frequentThreshold": [3, 1.5]}"#) }
        #expect(throws: EvalError.self) { try LearningReport.points(grid: #"{"frequentThreshold": [-1]}"#) }
        #expect(throws: EvalError.self) { try LearningReport.points(grid: #"{"manifest.accident": [0.2, 1.4]}"#) }
        #expect(throws: EvalError.self) { try LearningReport.points(grid: #"{"manifest.zipf": [-1]}"#) }
        // The sets are checked against every point before the first run: the model below does not exist,
        // and the error is still the grid's, not the model's.
        let file = Repo.path("eval/learning/learning.jrtq.json")
        func sweep(_ grid: String) throws -> Int32 {
            var parsed = try Arguments(["sweep", "--manifest", file, "--layouts", Repo.path("eval/layouts"),
                                        "--model", "/nonexistent-model", "--grid", grid])
            parsed.positional.removeAll()
            return try LearningCommand.sweep(parsed)
        }
        do {
            _ = try sweep(#"{"manifest.accidentContinues": [0, 0.7], "manifest.accidentRetypes": [0, 0.7]}"#)
            Issue.record("a share above 1 together went through")
        } catch let error as EvalError {
            #expect("\(error)".contains("together are a share"), "\(error)")
        }
    }

    @Test func aRetypeAfterTheAccidentGivesNoEvidence() throws {
        let run = try LearningSimulation.run(Self.config {
            $0["meantOther"] = 1
            $0["accident"] = 1
            $0["accidentRetypes"] = 1
            $0["days"] = 5
        })
        #expect(run.totals.learnedWords == 0)
        #expect(run.totals.counted == 0)
        #expect(run.totals.leftWrong == 0, "the retype put «привет» back")
        #expect(run.totals.converted == 50)
    }

    @Test func aRunIsDeterministicAndTheSeedChangesIt() throws {
        let one = try LearningSimulation.run(Self.config({ $0["meantOther"] = 0.3 }, words: ["ghbdtn", "rfr"]))
        let two = try LearningSimulation.run(Self.config({ $0["meantOther"] = 0.3 }, words: ["ghbdtn", "rfr"]))
        #expect(one == two)
        var config = try Self.config({ $0["meantOther"] = 0.3 }, words: ["ghbdtn", "rfr"])
        config.seed = 2
        let three = try LearningSimulation.run(config)
        #expect(three != one)
    }

    @Test func zipfPutsTheFirstWordsFirst() throws {
        let run = try LearningSimulation.run(Self.config({ $0["days"] = 20; $0["answer"] = "never" },
                                                         words: ["ghbdtn", "rfr", "ntcn", "cgfcb,j"]))
        #expect(run.words.map(\.keep) == run.words.map(\.keep).sorted(by: >), "rank 1 is typed most: \(run.words.map(\.keep))")
        #expect(run.words.map(\.keep).reduce(0, +) == 200)
    }

    @Test func theFilesAreTheSameBytesTwice() throws {
        func files() throws -> [String] {
            let run = try LearningSimulation.run(Self.config({ $0["meantOther"] = 0.3 }))
            let document = LearningReport.Document(commit: "c", models: [:], options: nil, seeds: 1,
                                                   sets: [.init(name: "learning.test", manifest: "m", vocabularySHA256: "s", runs: [run])])
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("learning-\(UUID().uuidString)").path
            defer { try? FileManager.default.removeItem(atPath: directory) }
            try LearningReport.write(document, to: directory)
            return try ["learning.json", "days.tsv", "words.tsv"].map { try String(contentsOfFile: "\(directory)/\($0)", encoding: .utf8) }
        }
        let first = try files()
        #expect(first == (try files()))
        #expect(first[1].split(separator: "\n").count == 1 + 3, "a header and a row per day")
    }

    @Test func theSweepTablePrintsOneRowPerPointAndSet() throws {
        let run = try LearningSimulation.run(Self.config())
        let rows = [LearningReport.SweepRow(point: [("frequentThreshold", 3)], name: "learning.test", runs: [run]),
                    LearningReport.SweepRow(point: [], name: "learning.test", runs: [run])]
        let lines = LearningReport.sweepTable(rows, seeds: 1).split(separator: "\n")
        #expect(lines.count == 3)
        #expect(lines[1].hasPrefix("frequentThreshold=3\tlearning.test\t1\t"))
        #expect(lines[2].hasPrefix("defaults\t"))
    }

    @Test func theLoopOfTheAppIsTheLoopOfTheStand() throws {
        // The core's own test drives `WordRules` the same way: an undo, a count, an answer.
        var rules = WordRules()
        let report = UndoReport(word: "ghbdtn", app: "com.apple.TextEdit", channel: .button, threshold: 3,
                                facts: UndoFacts(kind: .layout, decision: nil))
        _ = rules.count(report, at: 100, day: 0)
        let step = rules.count(report, at: 160, day: 0)
        #expect(step.outcome == .ask)
        let question = try #require(step.question)
        #expect(rules.answer(question, .everywhere, at: 160) != nil)
        #expect(rules.learned.map(\.word) == ["ghbdtn"])
    }
}
