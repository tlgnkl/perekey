// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import PerekeyCore
@testable import PerekeyModelKit

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

    /// An undone correction is read by the same branches as an undone switch.
    static let correctionUndos: [(UndoChannel, UndoFollowUp, ObservedWord.Label, ObservedWord.Strength?)] = [
        (UndoChannel.button, UndoFollowUp.none, ObservedWord.Label.wrongCorrection, ObservedWord.Strength.strong),
        (.shortcut, .none, .wrongCorrection, .strong),
        (.backspace, .continued, .wrongCorrection, .strong),
        (.backspace, .retyped, .right, .strong),
        (.backspace, .punctuation, .unclear, nil),
        (.backspace, .edited, .unclear, nil),
        (.backspace, .unknown, .unclear, nil),
    ]

    @Test(arguments: SessionWordsTests.correctionUndos)
    func undoneCorrectionIsReadByItsChannelAndFollowUp(channel: UndoChannel, followUp: UndoFollowUp,
                                                       label: ObservedWord.Label, strength: ObservedWord.Strength?)
    {
        let got = SessionWords.label(.actedThenUndone(channel, followUp), action: .corrected(.typo))
        #expect(got.0 == label && got.1 == strength)
    }

    @Test func undoneCorrectionWithoutReportIsUnclear() {
        let got = SessionWords.label(.actedThenUndone(nil, nil), action: .corrected(.typo))
        #expect(got.0 == .unclear && got.1 == nil)
    }

    @Test func switchLabelsStayTheSame() {
        let action = JudgeTrace.Action.switched(to: ru, early: false)
        #expect(SessionWords.label(.actedThenUndone(.backspace, .continued), action: action).0 == .falseSwitch)
        #expect(SessionWords.label(.actedThenUndone(.backspace, .edited), action: action).0 == .unclear)
        #expect(SessionWords.label(.actedThenUndone(nil, nil), action: action).0 == .unclear)
    }

    @Test func backspaceUndoOfACorrectionThenPunctuationIsUnclear() {
        var tape = SessionTape(Settings(typoCorrection: true))
        tape.desk.type("wrold ")
        tape.desk.press(KeyCode.delete)
        tape.desk.press(KeyCode.delete)
        tape.desk.type(", hello ")
        let words = Self.words(&tape)
        #expect(words[0].trace.action == .corrected(.typo))
        #expect(words[0].label == .unclear && words[0].strength == nil)
    }

    @Test func backspaceUndoOfACorrectionThenEditingIsUnclear() {
        var tape = SessionTape(Settings(typoCorrection: true))
        tape.desk.type("wrold ")
        tape.desk.press(KeyCode.delete)
        tape.desk.press(KeyCode.delete)
        tape.desk.type("s hello ")
        let words = Self.words(&tape)
        #expect(words[0].trace.action == .corrected(.typo))
        #expect(words[0].label == .unclear && words[0].strength == nil)
    }

    @Test func backspaceUndoOfACorrectionThenAClickIsUnclear() {
        var tape = SessionTape(Settings(typoCorrection: true))
        tape.desk.type("wrold ")
        tape.desk.press(KeyCode.delete)
        tape.desk.send(.click(time: tape.desk.time))
        tape.desk.type("hello ")
        let words = Self.words(&tape)
        #expect(words[0].trace.action == .corrected(.typo))
        #expect(words[0].label == .unclear && words[0].strength == nil)
    }

    /// The report of an undo can come after the next word's trace; it can
    /// also come after the range the search looks in. No trap then.
    @Test func undoPostedAfterTheNextWordEndsWithoutAReport() {
        let key = KeyStroke(0)
        let trace = { (serial: Int, action: JudgeTrace.Action, seq: UInt32?) in
            JudgeTrace(serial: serial, keys: [key, key, key], layout: en, context: nil, decision: nil, app: nil,
                       action: action, seq: seq)
        }
        let undo = Retype(deleteCount: 3, keys: [], target: en, expected: "", seq: 2, origin: .undo)
        let filler = RecordedEvent.deadline(time: 1)
        func step(_ event: RecordedEvent, _ trace: JudgeTrace? = nil, effects: [EffectDigest] = []) -> ReplayStep {
            ReplayStep(recorded: nil, source: nil, event: event, output: OutputDigest(effects: effects), trace: trace,
                       userLayoutChange: false, fenceExpired: false)
        }
        let run = ReplayRun(steps: [
            step(filler, trace(1, .switched(to: ru, early: false), 1)),
            step(.retypePosted(seq: 1, time: 1)),
            step(filler, effects: [.retype(RetypeDigest(undo))]),
            step(filler, trace(2, .kept, nil)),
            step(filler),
            step(filler),
            step(.retypePosted(seq: 2, time: 2)),
        ])
        let words = SessionWords.extract(run)
        #expect(words.count == 2)
        #expect(words[0].outcome == .actedThenUndone(nil, nil))
        #expect(words[0].label == .unclear)
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

    /// A session in which the recorded machine's own events do not fit the
    /// simulated replay: the first switch is cancelled in the recording (the
    /// caret check failed), the simulated field is blind and posts it.
    static func cancelledFiles() throws -> (directory: URL, session: String, model: String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("replay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var tape = SessionTape()
        tape.desk.cancelRetypes = true
        tape.desk.type("[jhjij ")
        tape.desk.cancelRetypes = false
        tape.desk.type("hello [jhjij ghbdtn ")
        tape.flush()
        let session = directory.appendingPathComponent("cancelled.pksession")
        try SessionFile.data(tape.lines).write(to: session)
        let model = directory.appendingPathComponent("fixture.pklm")
        try Data(ModelFixture.bytes).write(to: model)
        return (directory, session.path, model.path)
    }

    @Test func compareOfAModelWithItselfFindsNothingAndShowsTheCalibration() throws {
        let (directory, session, model) = try Self.cancelledFiles()
        defer { try? FileManager.default.removeItem(at: directory) }
        let json = directory.appendingPathComponent("compare.json").path
        let (status, output) = Self.run(["compare", session, "--model", model, "--candidate-model", model,
                                         "--json", json])
        #expect(status == 0)
        #expect(output.contains("decided otherwise 0"), "\(output)")
        #expect(output.contains("calibration, simulated against exact on the same model"), "\(output)")
        let written = try JSONDecoder().decode(SessionComparison.self, from: Data(contentsOf: URL(fileURLWithPath: json)))
        #expect(written.differ == 0)
        #expect(written.calibration.words == written.words)
    }

    @Test func calibrationCountsTheModeDifferenceNotTheCandidate() throws {
        let (directory, session, model) = try Self.cancelledFiles()
        defer { try? FileManager.default.removeItem(at: directory) }
        let json = directory.appendingPathComponent("compare.json").path
        _ = Self.run(["compare", session, "--model", model, "--candidate-model", model, "--json", json])
        let written = try JSONDecoder().decode(SessionComparison.self, from: Data(contentsOf: URL(fileURLWithPath: json)))
        #expect(written.calibration.differ > 0, "the cancelled retype makes the modes differ")
        #expect(written.differ == 0, "and the candidate is not blamed for it")
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

    @Test func aCommandLineWithoutAModelOrACommandExitsWith2() {
        #expect(Self.run(["words", "a.pksession"]).status == 2)
        #expect(Self.run(["nothing"]).status == 2)
        #expect(Self.run([]).status == 2)
    }

    @Test func noFilesExitsWith2() throws {
        let (directory, _, model) = try Self.files()
        defer { try? FileManager.default.removeItem(at: directory) }
        for command in ["check", "words", "compare"] {
            let (status, output) = Self.run([command, "--model", model])
            #expect(status == 2, "\(command)")
            #expect(output.contains("usage:"))
        }
    }

    @Test(arguments: [
        #"{"threshold": 10, "treshold": 12}"#, #"{"thresholds": 1}"#, "{not json", "[1, 2]", #"{"threshold": "high"}"#,
    ])
    func aCandidateOptionsThatAreNotOptionsExitWith2(text: String) throws {
        let (directory, session, model) = try Self.files()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (status, output) = Self.run(["compare", session, "--model", model, "--candidate-model", model,
                                         "--candidate-options", text])
        #expect(status == 2, "\(output)")
        #expect(output.contains("--candidate-options"))
    }

    @Test func anUnknownOptionIsNamed() throws {
        let (directory, session, model) = try Self.files()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (_, output) = Self.run(["compare", session, "--model", model, "--candidate-model", model,
                                    "--candidate-options", #"{"treshold": 12}"#])
        #expect(output.contains("unknown options: treshold"))
        #expect(output.contains("threshold"), "the known keys are listed")
    }

    @Test func candidateOptionsFromAFileAreRead() throws {
        let (directory, session, model) = try Self.files()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("options.json")
        try Data(#"{"threshold": 12}"#.utf8).write(to: file)
        let (status, _) = Self.run(["compare", session, "--model", model, "--candidate-model", model,
                                    "--candidate-options", file.path])
        #expect(status == 0)
    }

    @Test func aSessionWithoutSegmentsPrintsZeroSegments() throws {
        let (directory, _, model) = try Self.files()
        defer { try? FileManager.default.removeItem(at: directory) }
        let empty = directory.appendingPathComponent("empty.pksession")
        try SessionFile.data([.header(SessionHeader(perekey: "0.2.0", build: "test", time: 1_762_780_000))])
            .write(to: empty)
        let (status, output) = Self.run(["check", empty.path, "--model", model])
        #expect(status == 0)
        #expect(output.contains("empty.pksession: 0 segments"), "\(output)")
    }

    @Test func aModelThatCannotBeLoadedExitsWith1() throws {
        let (directory, session, _) = try Self.files()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (status, output) = Self.run(["check", session, "--model", directory.appendingPathComponent("none").path])
        #expect(status == 1)
        #expect(output.contains("cannot load the model"))
    }
}
