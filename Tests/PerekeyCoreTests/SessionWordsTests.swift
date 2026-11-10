// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import PerekeyCore
import PerekeyModelKit

private let en = Fixture.abc.id
private let ru = Fixture.russian.id

/// Words with labels from what the user did next (docs/classifier.md,
/// «Замер на живых сессиях»).
@Suite struct SessionWordsTests {
    static func words(_ tape: inout SessionTape, options: SessionWords.Options = SessionWords.Options()) -> [ObservedWord] {
        let session = tape.session
        return session.segments.flatMap { segment in
            SessionWords.extract(SessionDriver.run(segment, mode: .exact, classifier: SessionTape.classifier),
                                 options: options)
        }
    }

    @Test func switchTheUserKeptIsRightAndWeak() throws {
        var tape = SessionTape()
        tape.desk.type("[jhjij vbh ")
        let words = Self.words(&tape)
        #expect(words.map(\.label) == [.right, .right])
        #expect(words.map(\.strength) == [.weak, .weak])
        #expect(words[0].outcome == .acted)
    }

    @Test func keptWordTheUserTypedOnIsRightAndWeak() {
        var tape = SessionTape()
        tape.desk.type("hello world ")
        let words = Self.words(&tape)
        #expect(words.map(\.outcome) == [.kept, .kept])
        #expect(words.map(\.label) == [.right, .right])
    }

    @Test func undoByTheHintButtonIsAStrongFalseSwitch() throws {
        var tape = SessionTape()
        tape.desk.type("[jhjij ")
        tape.desk.send(.undoLastCorrection(seq: try #require(tape.desk.corrections.first).seq, time: tape.desk.time))
        tape.desk.settle()
        tape.desk.type("hello ")
        let words = Self.words(&tape)
        #expect(words[0].outcome == .actedThenUndone(.button, UndoFollowUp.none))
        #expect(words[0].label == .falseSwitch && words[0].strength == .strong)
    }

    @Test func undoByTheShortcutIsAStrongFalseSwitch() {
        var tape = SessionTape()
        tape.desk.type("[jhjij ")
        tape.desk.tapOption()
        tape.desk.type("hello ")
        let words = Self.words(&tape)
        #expect(words[0].outcome == .actedThenUndone(.shortcut, UndoFollowUp.none))
        #expect(words[0].label == .falseSwitch && words[0].strength == .strong)
    }

    @Test func backspaceUndoThenTypingOnIsAStrongFalseSwitch() {
        var tape = SessionTape()
        tape.desk.type("[jhjij ")
        tape.desk.press(KeyCode.delete)
        tape.desk.type("hello ")
        let words = Self.words(&tape)
        #expect(words[0].outcome == .actedThenUndone(.backspace, .continued))
        #expect(words[0].label == .falseSwitch && words[0].strength == .strong)
    }

    @Test func backspaceUndoThenPunctuationIsUnclear() {
        var tape = SessionTape()
        tape.desk.type("[jhjij ")
        tape.desk.press(KeyCode.delete)
        tape.desk.press(KeyCode.delete)
        tape.desk.type(", hello ")
        let words = Self.words(&tape)
        #expect(words[0].label == .unclear)
        #expect(words[0].strength == nil)
    }

    @Test func backspaceUndoThenTheRetypeShortcutSaysTheSwitchWasRight() {
        var tape = SessionTape()
        tape.desk.type("[jhjij ")
        tape.desk.press(KeyCode.delete)
        tape.desk.tapOption()
        tape.desk.type("hello ")
        let words = Self.words(&tape)
        #expect(words[0].outcome == .actedThenUndone(.backspace, .retyped))
        #expect(words[0].label == .right && words[0].strength == .strong)
    }

    @Test func earlySwitchUndoneIsAStrongFalseSwitch() {
        var tape = SessionTape()
        tape.desk.type("ghb")
        tape.desk.press(KeyCode.delete)
        tape.desk.type("dtn hello ")
        let words = Self.words(&tape)
        #expect(words.count == 2)
        #expect(words[0].trace.action == .switched(to: ru, early: true))
        #expect(words[0].label == .falseSwitch && words[0].strength == .strong)
    }

    @Test func undoneWordCorrectionIsAStrongWrongCorrection() {
        var tape = SessionTape(Settings(typoCorrection: true))
        tape.desk.type("wrold ")
        tape.desk.press(KeyCode.delete)
        tape.desk.type("hello ")
        let words = Self.words(&tape)
        #expect(words[0].trace.action == .corrected(.typo))
        #expect(words[0].label == .wrongCorrection && words[0].strength == .strong)
    }

    @Test func keptWordRetypedByHandIsAStrongMiss() {
        var tape = SessionTape()
        tape.desk.type("hello ")
        tape.desk.tapOption()
        tape.desk.type("vbh ")
        let words = Self.words(&tape)
        #expect(words[0].outcome == .keptThenRetyped)
        #expect(words[0].label == .miss && words[0].strength == .strong)
        #expect(words[0].retypedTo == ru)
    }

    @Test func retypeShortcutOnTheNextWordIsNoMissOfThisOne() {
        var tape = SessionTape()
        tape.desk.type("hello wor")
        tape.desk.tapOption()
        tape.desk.type(" ")
        let words = Self.words(&tape)
        #expect(words[0].outcome == .kept)
        #expect(words[0].label == .right)
    }

    /// The user erased a kept word, switched the layout and typed the same
    /// keys: Perekey should have switched it.
    static func erase(_ tape: inout SessionTape, count: Int) {
        for _ in 0..<count { tape.desk.press(KeyCode.delete) }
    }

    @Test(arguments: [true, false])
    func erasedAndTypedAgainInTheOtherLayoutIsAStrongMiss(switchFirst: Bool) {
        var tape = SessionTape()
        tape.desk.type("hello ")
        if switchFirst { tape.desk.send(.layoutChanged(ru)) }
        Self.erase(&tape, count: 6)
        if !switchFirst { tape.desk.send(.layoutChanged(ru)) }
        tape.desk.appLayout = ru
        tape.desk.type("hello ", on: Fixture.abc)
        let words = Self.words(&tape)
        #expect(words[0].outcome == .keptThenRetypedAfterErasing)
        #expect(words[0].label == .miss && words[0].strength == .strong)
    }

    @Test func optionBackspaceErasesTheWordToo() {
        var tape = SessionTape()
        tape.desk.type("hello ")
        tape.desk.press(KeyCode.delete, flags: Keyboard.leftOption)
        tape.desk.send(.layoutChanged(ru))
        tape.desk.type("hello ")
        #expect(Self.words(&tape)[0].outcome == .keptThenRetypedAfterErasing)
    }

    @Test func erasedAndTypedAnotherWordIsNoMiss() {
        var tape = SessionTape()
        tape.desk.type("hello ")
        Self.erase(&tape, count: 6)
        tape.desk.send(.layoutChanged(ru))
        tape.desk.type("world ")
        let words = Self.words(&tape)
        #expect(words[0].outcome == .kept)
        #expect(words[0].label == .right)
    }

    @Test func sameWordWithoutALayoutChangeIsNoMiss() {
        var tape = SessionTape()
        tape.desk.type("hello ")
        Self.erase(&tape, count: 6)
        tape.desk.type("hello ")
        #expect(Self.words(&tape)[0].outcome == .kept)
    }

    @Test func tooFewErasedIsNoMiss() {
        var tape = SessionTape()
        tape.desk.type("hello ")
        Self.erase(&tape, count: 3)
        tape.desk.send(.layoutChanged(ru))
        tape.desk.type("hello ")
        #expect(Self.words(&tape)[0].outcome == .kept)
    }

    @Test func shortWordIsNoMiss() {
        var tape = SessionTape()
        tape.desk.type("hi ")
        Self.erase(&tape, count: 3)
        tape.desk.send(.layoutChanged(ru))
        tape.desk.type("hi ")
        #expect(Self.words(&tape)[0].outcome == .kept, "fewer keys than SessionWords.Options.minKeys")
    }

    @Test func tooLateIsNoMiss() {
        var tape = SessionTape()
        tape.desk.type("hello ")
        Self.erase(&tape, count: 6)
        tape.desk.send(.layoutChanged(ru))
        tape.desk.time += 20
        tape.desk.type("hello ")
        #expect(Self.words(&tape)[0].outcome == .kept)
    }

    @Test func anotherFocusIsNoMiss() {
        var tape = SessionTape()
        tape.desk.type("hello ")
        Self.erase(&tape, count: 6)
        tape.desk.send(.focusChanged(Focus(bundleID: "com.apple.Notes")))
        tape.desk.send(.layoutChanged(ru))
        tape.desk.type("hello ")
        #expect(Self.words(&tape)[0].outcome == .kept)
    }

    @Test func cancelledSwitchIsNoLabel() {
        var tape = SessionTape()
        tape.desk.cancelRetypes = true
        tape.desk.type("[jhjij ")
        let words = Self.words(&tape)
        #expect(words[0].outcome == .cancelled)
        #expect(words[0].label == .none)
    }

    @Test func wordNotJudgedHasNoLabel() {
        var tape = SessionTape()
        tape.desk.send(.appModeChanged(.manualOnly))
        tape.desk.type("[jhjij ")
        let words = Self.words(&tape)
        #expect(words[0].outcome == .notJudged(.appMode))
        #expect(words[0].label == .none)
    }
}

@Suite struct SessionSummaryTests {
    static let typed = ["[jhjij", "hello", "ghbdtn", "vbh", "world", "wrold"]

    static func tape() -> SessionTape {
        var tape = SessionTape(Settings(typoCorrection: true))
        tape.desk.type("[jhjij ")
        tape.desk.press(KeyCode.delete)
        tape.desk.type("hello ")
        tape.desk.tapOption()
        tape.desk.send(.layoutChanged(en))
        tape.desk.appLayout = en
        tape.desk.type("ghbdtn vbh world ")
        tape.desk.send(.appModeChanged(.manualOnly))
        tape.desk.type("hello ")
        tape.desk.send(.appModeChanged(.auto))
        tape.desk.send(.layoutChanged(en))
        tape.desk.appLayout = en
        tape.desk.type("wrold ")
        return tape
    }

    static func summary(_ tape: inout SessionTape) -> (SessionSummary, [ObservedWord], Session) {
        let session = tape.session
        var summary = SessionSummary()
        var all: [ObservedWord] = []
        for segment in session.segments {
            let run = SessionDriver.run(segment, mode: .exact, classifier: SessionTape.classifier)
            let words = SessionWords.extract(run)
            summary.add(run, words: words)
            all += words
        }
        return (summary, all, session)
    }

    @Test func countsByOutcome() {
        var tape = Self.tape()
        let (summary, _, _) = Self.summary(&tape)
        #expect(summary.words == 7)
        #expect(summary.judged == 6)
        #expect(summary.notJudged == ["appMode": 1])
        #expect(summary.switches == 3)
        #expect(summary.earlySwitches == 2, "«ghb» and «цщк», typed on Russian, switch inside the word")
        #expect(summary.falseStrong == 1)
        #expect(summary.missesByHand == 1)
        #expect(summary.corrections["typo"] == SessionSummary.KindCount(count: 1, undone: 0))
        #expect(summary.byApp["com.apple.TextEdit"]?.words == 7)
        #expect(summary.byReason["compared"] != nil)
        #expect(summary.mismatches == 0)
    }

    /// Without `--show-words` nothing typed is printed.
    @Test func reportHoldsNoTypedWord() throws {
        var tape = Self.tape()
        let (summary, words, session) = Self.summary(&tape)
        let report = summary.render()
        let json = try #require(String(data: JSONEncoder().encode(summary), encoding: .utf8))
        let layouts = session.segments[0].snapshot.machine.layouts
        for word in Self.typed {
            let strokes = Fixture.abc.strokes(word)
            for layout in layouts {
                let reading = strokes.compactMap { layout.text(for: $0) }.joined()
                #expect(!report.contains(reading), "\(reading) in the report")
                #expect(!json.contains(reading), "\(reading) in the JSON")
            }
        }
        // With it, the words are listed.
        let list = SessionReport.words(words, layouts: layouts)
        #expect(list.contains("[jhjij") && list.contains("хорошо"))
    }

    @Test func reportNamesEveryNumber() {
        var tape = Self.tape()
        let (summary, _, _) = Self.summary(&tape)
        let report = summary.render()
        for line in ["words", "judged", "switches", "false", "misses", "corrections", "retypes"] {
            #expect(report.contains(line), "\(line)")
        }
    }
}

@Suite struct SessionCompareTests {
    static func compare(_ tape: inout SessionTape, candidate: Classifier.Options) -> SessionComparison {
        let session = tape.session
        var comparison = SessionComparison()
        for segment in session.segments {
            let base = SessionWords.extract(SessionDriver.run(segment, mode: .exact, classifier: SessionTape.classifier))
            let other = SessionDriver.run(segment, mode: .simulated) { spec in
                Classifier(model: ModelFixture.model, options: candidate)
            }
            comparison.add(base: base, candidate: other)
        }
        return comparison
    }

    @Test func sameClassifierDecidesNothingDifferently() {
        var tape = SessionSummaryTests.tape()
        let comparison = Self.compare(&tape, candidate: Classifier.Options())
        #expect(comparison.words == 7)
        #expect(comparison.differ == 0)
        #expect(comparison.strongFixed == 0 && comparison.strongBroken == 0)
    }

    @Test func candidateThatNeverSwitchesFixesTheUndoneSwitch() {
        var tape = SessionTape()
        tape.desk.type("[jhjij ")
        tape.desk.tapOption()
        tape.desk.type("vbh ")
        var options = Classifier.Options()
        options.threshold = 1000
        let comparison = Self.compare(&tape, candidate: options)
        #expect(comparison.strongFixed == 1)
        #expect(comparison.strongBroken == 0)
        #expect(comparison.weakDiffer == 1, "мир, kept by the user, is no longer switched")
    }

    @Test func candidateThatNeverSwitchesBreaksASwitchTheUserConfirmed() {
        var tape = SessionTape()
        tape.desk.type("[jhjij ")
        tape.desk.press(KeyCode.delete)
        tape.desk.tapOption()
        tape.desk.type("hello ")
        var options = Classifier.Options()
        options.threshold = 1000
        let comparison = Self.compare(&tape, candidate: options)
        #expect(comparison.strongBroken == 1)
    }
}

/// `perekey-eval replay` on files, with the fixture model as `--model`.
@Suite struct ReplayCommandTests {
    static func files() throws -> (directory: URL, session: String, model: String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("replay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var tape = SessionSummaryTests.tape()
        tape.flush()
        let session = directory.appendingPathComponent("test.pksession")
        try SessionFile.data(tape.lines).write(to: session)
        let model = directory.appendingPathComponent("fixture.pklm")
        try Data(ModelFixture.bytes).write(to: model)
        return (directory, session.path, model.path)
    }

    static func run(_ arguments: [String]) -> (status: Int32, output: String) {
        var output: [String] = []
        let status = ReplayCommand.run(arguments) { output.append($0) }
        return (status, output.joined(separator: "\n"))
    }

    @Test func checkFindsNoDifference() throws {
        let (directory, session, model) = try Self.files()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (status, output) = Self.run(["check", session, "--model", model])
        #expect(status == 0)
        #expect(output.contains("no difference"))
    }

    @Test func wordsPrintNoTypedWordUnlessAsked() throws {
        let (directory, session, model) = try Self.files()
        defer { try? FileManager.default.removeItem(at: directory) }
        let json = directory.appendingPathComponent("words.json").path
        let (status, output) = Self.run(["words", session, "--model", model, "--json", json])
        #expect(status == 0)
        let written = try String(contentsOfFile: json, encoding: .utf8)
        for word in SessionSummaryTests.typed {
            for layout in [Fixture.abc, Fixture.russian] {
                let reading = Fixture.abc.strokes(word).compactMap { layout.text(for: $0) }.joined()
                #expect(!output.contains(reading), "\(reading) printed")
                #expect(!written.contains(reading), "\(reading) written")
            }
        }
        let shown = Self.run(["words", session, "--model", model, "--show-words"]).output
        #expect(shown.contains("[jhjij") && shown.contains("хорошо"))
    }

    @Test func compareWithTheSameModelFindsNothing() throws {
        let (directory, session, model) = try Self.files()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (status, output) = Self.run(["compare", session, "--model", model, "--candidate-model", model,
                                         "--candidate-options", #"{"threshold": 10}"#])
        #expect(status == 0)
        #expect(output.contains("decided otherwise 0"))
    }

    @Test func brokenFileFailsWithItsName() throws {
        let (directory, _, model) = try Self.files()
        defer { try? FileManager.default.removeItem(at: directory) }
        let broken = directory.appendingPathComponent("broken.pksession")
        try Data("{}\n".utf8).write(to: broken)
        let (status, output) = Self.run(["check", broken.path, "--model", model])
        #expect(status == 1)
        #expect(output.contains("broken.pksession") && output.contains("line 1"))
    }

    @Test func missingModelIsAUsageError() {
        #expect(Self.run(["words", "a.pksession"]).status == 2)
        #expect(Self.run(["nothing"]).status == 2)
    }
}
