// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import PerekeyCore

/// Learning from undos by evidence (docs/classifier.md, «Обучение»).
@Suite struct UndoLearningTests {
    static let textEdit = "com.apple.TextEdit"
    static let notes = "com.apple.Notes"
    static let day = 20_000.0 * 86_400

    static func report(_ channel: UndoChannel = .button, _ followUp: UndoFollowUp = .none, word: String = "jrtq",
                       app: String? = textEdit, threshold: Int = 2) -> UndoReport
    {
        UndoReport(word: word, app: app, channel: channel, followUp: followUp, threshold: threshold,
                   facts: UndoFacts(kind: .layout, decision: nil))
    }

    /// Counts `report` at `seconds`, numbering days from 1970 as the app does.
    @discardableResult
    static func count(_ report: UndoReport, in words: inout WordRules, at seconds: Double = day) -> LearningStep {
        words.count(report, at: seconds, day: Int(seconds / 86_400))
    }

    // MARK: - Weights and thresholds

    @Test func weights() {
        let options = LearningOptions()
        #expect(options.weight(.button, .none) == 2)
        #expect(options.weight(.shortcut, .none) == 2)
        #expect(options.weight(.backspace, .continued) == 1)
        for followUp in [UndoFollowUp.punctuation, .retyped, .edited, .unknown] {
            #expect(options.weight(.backspace, followUp) == 0)
        }
    }

    @Test func thresholdFollowsTheUndoneDecision() {
        let options = LearningOptions()
        func decision(typed: Classifier.Form, otherRank: UInt8?) -> Classifier.Decision {
            var decision = Classifier.Decision(verdict: .switch(to: Fixture.russian.id), score: 20, reason: .compared,
                                               language: "ru", typedForm: typed, otherForm: .known)
            decision.otherRank = otherRank
            return decision
        }
        #expect(options.threshold(for: decision(typed: .known, otherRank: 200), frequentRank: 160) == 1,
                "the typed reading is a word: likely meant")
        #expect(options.threshold(for: decision(typed: .rare, otherRank: 100), frequentRank: 160) == 1)
        #expect(options.threshold(for: decision(typed: .unknown, otherRank: 120), frequentRank: 160) == 2)
        #expect(options.threshold(for: decision(typed: .notWord, otherRank: 160), frequentRank: 160) == 3,
                "the other reading is frequent: the switch was likely right")
        #expect(options.threshold(for: nil, frequentRank: 160) == 2, "a typo or «ё» has no decision")
    }

    @Test func explainedDecisionCarriesTheRanks() {
        let decision = Desk.classifier.classify(Fixture.abc.strokes("ghbdtn"), typed: Fixture.abc,
                                                other: Fixture.russian, explaining: true)
        #expect(decision.otherRank != nil, "«привет» is in the dictionary")
        #expect(decision.typedRank == nil)
    }

    // MARK: - Counting

    @Test func oneButtonUndoOfAFrequentWordAsksNothingTwoAsk() {
        // «окей»: the other reading is frequent, so it takes 3.
        var words = WordRules()
        let first = Self.count(Self.report(threshold: 3), in: &words)
        #expect(first.outcome == .counted && first.evidence == 2 && first.oldRule == .learn)
        #expect(words.learned.isEmpty, "nothing is learned without asking")
        let second = Self.count(Self.report(threshold: 3), in: &words, at: Self.day + 60)
        #expect(second.outcome == .ask && second.evidence == 4)
        #expect(second.question == LearningQuestion(word: "jrtq", app: Self.textEdit))
        #expect(words.learned.isEmpty)
        #expect(!words.contains("jrtq"), "a candidate is still corrected")
    }

    @Test func backspaceCountsOnlyWhenTheWordWasKept() {
        var words = WordRules()
        for followUp in [UndoFollowUp.punctuation, .retyped, .edited, .unknown] {
            let step = Self.count(Self.report(.backspace, followUp), in: &words)
            #expect(step.outcome == .noEvidence && step.oldRule == .learn)
        }
        #expect(words.candidates.isEmpty)
        let kept = Self.count(Self.report(.backspace, .continued), in: &words)
        #expect(kept.outcome == .counted && kept.evidence == 1)
        let again = Self.count(Self.report(.backspace, .continued), in: &words, at: Self.day + 60)
        #expect(again.outcome == .ask && again.evidence == 2)
    }

    @Test func anotherDayAddsOne() {
        var words = WordRules()
        Self.count(Self.report(.backspace, .continued, threshold: 3), in: &words)
        let next = Self.count(Self.report(.backspace, .continued, threshold: 3), in: &words, at: Self.day + 86_400)
        #expect(next.evidence == 3 && next.outcome == .ask)
    }

    @Test func noAnswerKeepsTheCandidateAndAsksAgain() {
        var words = WordRules()
        #expect(Self.count(Self.report(), in: &words).outcome == .ask)
        #expect(words.candidates.count == 1)
        let again = Self.count(Self.report(.backspace, .continued), in: &words, at: Self.day + 10)
        #expect(again.outcome == .ask && again.evidence == 3)
        #expect(Self.count(Self.report(.backspace, .punctuation), in: &words).outcome == .noEvidence,
                "only a counted undo asks")
    }

    @Test func candidatesAreCountedPerApp() {
        var words = WordRules()
        Self.count(Self.report(.backspace, .continued), in: &words)
        let elsewhere = Self.count(Self.report(.backspace, .continued, app: Self.notes), in: &words)
        #expect(elsewhere.outcome == .counted && elsewhere.evidence == 1)
        #expect(words.candidates.map(\.app) == [Self.textEdit, Self.notes])
    }

    @Test func candidatesGoAfterThirtyDays() {
        var words = WordRules()
        Self.count(Self.report(.backspace, .continued), in: &words)
        Self.count(Self.report(.backspace, .continued, word: "ytn"), in: &words, at: Self.day + 20 * 86_400)
        let late = Self.count(Self.report(.backspace, .continued), in: &words, at: Self.day + 31 * 86_400)
        #expect(late.evidence == 1, "the old evidence is gone")
        words.expireCandidates(at: Self.day + 51 * 86_400)
        #expect(words.candidates.map(\.word) == ["jrtq"])
    }

    @Test func learningOffCountsNothing() {
        var words = WordRules(learnFromUndos: false)
        let step = Self.count(Self.report(), in: &words)
        #expect(step.outcome == .off && step.oldRule == .nothing)
        #expect(words.candidates.isEmpty && words.learned.isEmpty)
    }

    @Test func wordsOfMineAreNotCounted() {
        var words = WordRules(mine: ["jrtq"])
        #expect(Self.count(Self.report(), in: &words).outcome == .notLearnable)
        #expect(Self.count(Self.report(word: "two words"), in: &words).outcome == .notLearnable)
        #expect(words.candidates.isEmpty)
    }

    // MARK: - Answers and scopes

    @Test func hereLearnsForTheAppOnly() throws {
        var words = WordRules()
        let question = try #require(Self.count(Self.report(), in: &words).question)
        let learned = words.answer(question, .here, at: Self.day + 1)
        #expect(learned == LearnedWord(word: "jrtq", learnedAt: Self.day, undoCount: 1, lastUndoneAt: Self.day + 1,
                                       app: Self.textEdit))
        #expect(words.candidates.isEmpty)
        #expect(words.isLearned("jrtq", in: Self.textEdit) && !words.isLearned("jrtq", in: Self.notes))
        let snapshot = AppSettings(words: words).snapshot
        #expect(snapshot.exceptions.isEmpty)
        #expect(snapshot.appExceptions == [Self.textEdit: ["jrtq"]])
        #expect(Self.count(Self.report(), in: &words).outcome == .alreadyLearned)
        #expect(Self.count(Self.report(app: Self.notes), in: &words).outcome == .ask,
                "another app counts on its own")
    }

    @Test func hereInASecondAppLearnsEverywhere() throws {
        var words = WordRules()
        let first = try #require(Self.count(Self.report(), in: &words).question)
        words.answer(first, .here, at: Self.day)
        let second = try #require(Self.count(Self.report(app: Self.notes), in: &words).question)
        #expect(second.reachedElsewhere)
        let learned = words.answer(second, .here, at: Self.day + 5)
        #expect(learned?.app == nil && learned?.undoCount == 2)
        #expect(words.learned.count == 1 && words.candidates.isEmpty)
        #expect(AppSettings(words: words).snapshot.exceptions == ["jrtq"])
    }

    @Test func ripeInTwoAppsLearnsEverywhereOnHere() throws {
        var words = WordRules()
        Self.count(Self.report(), in: &words) // asked, not answered
        let second = try #require(Self.count(Self.report(app: Self.notes), in: &words).question)
        #expect(second.reachedElsewhere)
        #expect(words.answer(second, .here, at: Self.day)?.app == nil)
    }

    @Test func everywhereLearnsGlobally() throws {
        var words = WordRules()
        Self.count(Self.report(.backspace, .continued, app: Self.notes), in: &words)
        let question = try #require(Self.count(Self.report(), in: &words).question)
        let learned = words.answer(question, .everywhere, at: Self.day)
        #expect(learned?.app == nil && learned?.undoCount == 2)
        #expect(words.candidates.isEmpty)
        #expect(words.isLearned("jrtq", in: Self.notes) && words.isLearned("jrtq", in: nil))
    }

    @Test func noStartsTheEvidenceOver() throws {
        var words = WordRules()
        let question = try #require(Self.count(Self.report(), in: &words).question)
        #expect(words.answer(question, .no, at: Self.day) == nil)
        #expect(words.learned.isEmpty && words.candidates.first?.evidence == 0)
        let next = Self.count(Self.report(.backspace, .continued), in: &words, at: Self.day + 1)
        #expect(next.outcome == .counted && next.evidence == 1)
    }

    @Test func unknownAppLearnsEverywhere() throws {
        var words = WordRules()
        let question = try #require(Self.count(Self.report(app: nil), in: &words).question)
        #expect(words.answer(question, .here, at: Self.day)?.app == nil)
    }

    @Test func answerForAWordListedMeanwhileDoesNothing() throws {
        var words = WordRules()
        let question = try #require(Self.count(Self.report(), in: &words).question)
        words.add("jrtq")
        #expect(words.answer(question, .here, at: Self.day) == nil)
        #expect(words.learned.isEmpty && words.mine == ["jrtq"])
    }

    // MARK: - Unlearning

    @Test func retypeByHandForgetsTheWordInItsScope() throws {
        var words = WordRules(learned: [LearnedWord(word: "jrtq", learnedAt: 1, app: Self.textEdit),
                                        LearnedWord(word: "ytn", learnedAt: 1),
                                        LearnedWord(word: "выбор", learnedAt: 1)])
        #expect(words.unlearn(typed: "jrtq", retyped: "окей", app: Self.notes) == nil, "learned for another app")
        #expect(words.unlearn(typed: "Jrtq,", retyped: "окей,", app: Self.textEdit)
            == Unlearned(word: "jrtq", app: Self.textEdit))
        #expect(words.unlearn(typed: "нет", retyped: "ytn", app: Self.notes) == nil,
                "retyped into the learned word: the user wants it")
        #expect(words.unlearn(typed: "ytn", retyped: "нет", app: Self.notes) == Unlearned(word: "ytn", app: nil),
                "a word learned everywhere goes everywhere")
        #expect(words.unlearn(typed: "ds,jh", retyped: "выбор", app: nil) == Unlearned(word: "выбор", app: nil),
                "learned as its other reading")
        #expect(words.learned.isEmpty)
    }

    @Test func retypeByHandDropsTheCandidate() {
        var words = WordRules()
        Self.count(Self.report(.backspace, .continued), in: &words)
        #expect(words.unlearn(typed: "jrtq", retyped: "окей", app: Self.textEdit) == nil)
        #expect(words.candidates.isEmpty)
    }

    // MARK: - Settings file

    @Test func olderFilesMigrate() throws {
        let json = #"{"words":{"learned":[{"word":"jrtq","learnedAt":5},{"word":"ghbdtn","learnedAt":6,"undoCount":2}]}}"#
        let words = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8)).words
        #expect(words.learned == [LearnedWord(word: "ghbdtn", learnedAt: 6, undoCount: 2)])
        #expect(words.candidates == [LearningCandidate(word: "jrtq", app: nil, evidence: 1, threshold: 2,
                                                       undoCount: 1, firstUndoneAt: 5, lastCountedDay: 0)])
        // Saved again, nothing migrates twice: a word learned after one undo stays learned.
        var learnedOnce = words
        learnedOnce.learned.append(LearnedWord(word: "ytn", learnedAt: 7, app: Self.textEdit))
        let again = try JSONDecoder().decode(WordRules.self, from: JSONEncoder().encode(learnedOnce))
        #expect(again == learnedOnce)
    }

    @Test func migratedCandidateCountsInEveryApp() throws {
        var words = WordRules(candidates: [LearningCandidate(word: "jrtq", app: nil, evidence: 1, threshold: 2,
                                                             undoCount: 1, firstUndoneAt: Self.day - 10,
                                                             lastCountedDay: 20_000)])
        let step = Self.count(Self.report(.backspace, .continued, app: Self.notes), in: &words)
        #expect(step.outcome == .ask && step.question?.app == Self.notes)
        let learned = words.answer(try #require(step.question), .here, at: Self.day)
        #expect(learned?.app == Self.notes && learned?.undoCount == 2)
        #expect(words.candidates.isEmpty)
    }

    @Test func wordLearnedForTwoScopesDecodesOnce() throws {
        let json = #"{"learning":2,"learned":[{"word":"x","learnedAt":1,"app":"a"},{"word":"x","learnedAt":2,"app":"a"},{"word":"x","learnedAt":3},{"word":"y","learnedAt":4,"app":"a"},{"word":"y","learnedAt":5,"app":"b"}],"candidates":[{"word":"y","app":"c","evidence":1,"threshold":2,"undoCount":1,"firstUndoneAt":1,"lastCountedAt":1,"lastCountedDay":0},{"word":"y","app":"a","evidence":1,"threshold":2,"undoCount":1,"firstUndoneAt":1,"lastCountedAt":1,"lastCountedDay":0}]}"#
        let words = try JSONDecoder().decode(WordRules.self, from: Data(json.utf8))
        #expect(words.learned.map { [$0.word, $0.app ?? "*"] } == [["x", "*"], ["y", "a"], ["y", "b"]])
        #expect(words.candidates.map(\.app) == ["c"], "learned for «a» already")
    }

    // MARK: - Journal

    @Test func journalKeepsTheLatestEntriesAndNoWord() throws {
        var journal = LearningJournal()
        let report = Self.report(.backspace, .continued, word: "секрет")
        for index in 0..<(LearningJournal.capacity + 3) {
            journal.append(LearningJournal.Entry(undo: report, step: LearningStep(outcome: .counted, oldRule: .learn),
                                                 at: Double(index)))
        }
        #expect(journal.entries.count == LearningJournal.capacity)
        #expect(journal.entries.first?.time == 3)
        let data = try JSONEncoder().encode(journal)
        #expect(!String(decoding: data, as: UTF8.self).contains("секрет"))
        #expect(try JSONDecoder().decode(LearningJournal.self, from: data) == journal)
    }
}

/// What the key after a Backspace undo says, in the machine.
@Suite struct UndoWatchTests {
    @Test func backspaceForTheSpaceThenPunctuationLearnsNothing() throws {
        // "jrtq " came out "окей "; the user pressed Backspace to put a comma
        // after the word, and that undid the switch. It must teach nothing.
        var desk = Desk()
        desk.type("[jhjij ")
        #expect(desk.text == "хорошо ")
        desk.press(KeyCode.delete)
        #expect(desk.text == "[jhjij ")
        #expect(desk.undoReports.isEmpty, "a Backspace waits for the next key")
        desk.press(KeyCode.delete)
        desk.type(",")
        let report = try #require(desk.undoReports.first)
        #expect(report.channel == .backspace && report.followUp == .punctuation)
        #expect(desk.learned.isEmpty)
        var words = WordRules()
        let step = UndoLearningTests.count(report, in: &words)
        #expect(step.outcome == .noEvidence && step.oldRule == .learn, "the old rule learned it")
        #expect(words.learned.isEmpty && words.candidates.isEmpty)
    }

    @Test func typingOnCounts() throws {
        var desk = Desk()
        desk.type("[jhjij ")
        desk.press(KeyCode.delete)
        desk.type("v")
        let report = try #require(desk.undoReports.first)
        #expect(report.followUp == .continued && report.word == "jhjij")
        #expect(report.app == Desk.textEdit.bundleID)
        #expect(report.facts.kind == "layout" && report.facts.otherForm != nil)
    }

    @Test func spaceAgainAfterDeletingItCounts() {
        var desk = Desk()
        desk.type("[jhjij ")
        desk.press(KeyCode.delete)
        desk.press(KeyCode.delete)
        desk.type(" ")
        #expect(desk.undoReports.map(\.followUp) == [.continued])
    }

    @Test func deletingIntoTheWordCountsNothing() {
        var desk = Desk()
        desk.type("[jhjij ")
        desk.press(KeyCode.delete)
        desk.press(KeyCode.delete)
        desk.press(KeyCode.delete)
        #expect(desk.undoReports.map(\.followUp) == [.edited])
        #expect(desk.learned.isEmpty)
    }

    @Test func lettersOntoTheWordCountNothing() {
        var desk = Desk()
        desk.type("[jhjij ")
        desk.press(KeyCode.delete)
        desk.press(KeyCode.delete)
        desk.type("f")
        #expect(desk.undoReports.map(\.followUp) == [.edited])
    }

    @Test func retypeShortcutCountsNothing() {
        var desk = Desk()
        desk.type("[jhjij ")
        desk.press(KeyCode.delete)
        desk.tapOption()
        #expect(desk.undoReports.map(\.followUp) == [.retyped])
    }

    @Test func clickOrFocusChangeCountsNothing() {
        var desk = Desk()
        desk.type("[jhjij ")
        desk.press(KeyCode.delete)
        desk.send(.click(time: desk.time, onHint: false))
        desk.type("[jhjij ")
        desk.press(KeyCode.delete)
        desk.send(.focusChanged(Focus(bundleID: "com.apple.Notes"), .moved))
        #expect(desk.undoReports.map(\.followUp) == [.unknown, .unknown])
    }

    @Test func hintButtonReportsAtOnce() throws {
        var desk = Desk()
        desk.type("[jhjij ")
        let seq = try #require(desk.corrections.first).seq
        desk.send(.click(time: desk.time, onHint: true))
        desk.send(.undoLastCorrection(seq: seq, time: desk.time))
        desk.settle()
        let report = try #require(desk.undoReports.first)
        #expect(report.channel == .button && report.followUp == .none)
        #expect(desk.learned == ["jhjij"])
    }

    @Test func learningOffReportsNothing() {
        var desk = Desk(Settings(learnFromUndos: false))
        desk.type("[jhjij ")
        desk.press(KeyCode.delete)
        desk.type("v")
        #expect(desk.undoReports.isEmpty)
    }

    @Test func wordLearnedForAnAppIsLeftAloneThereOnly() {
        let settings = Settings(appExceptions: ["com.apple.TextEdit": ["jhjij"]])
        var desk = Desk(settings)
        desk.type("[jhjij ")
        #expect(desk.text == "[jhjij ")
        var elsewhere = Desk(settings, focus: Focus(bundleID: "com.apple.Notes"))
        elsewhere.type("[jhjij ")
        #expect(elsewhere.text == "хорошо ")
    }
}
