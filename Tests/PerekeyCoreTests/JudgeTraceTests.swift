// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import PerekeyCore
import PerekeyModelKit

private let en = Fixture.abc.id
private let ru = Fixture.russian.id

/// The trace of each decision on a word (`InputMachine.tracesJudgements`),
/// for the replay of recorded sessions.
@Suite struct JudgeTraceTests {
    static func desk(_ settings: Settings = Settings(), focus: Focus? = Desk.textEdit) -> Desk {
        var desk = Desk(settings, focus: focus)
        desk.machine = InputMachine(settings: settings, layouts: [Fixture.abc, Fixture.russian], currentLayout: en,
                                    classifier: Desk.classifier, tracesJudgements: true)
        if let focus { desk.send(.focusChanged(focus)) }
        return desk
    }

    /// Types `text` and collects every trace made on the way.
    static func traces(_ desk: inout Desk, typing text: String, on layout: LayoutMap = Fixture.abc) -> [JudgeTrace] {
        var traces: [JudgeTrace] = []
        var serial = desk.machine.lastJudgement?.serial ?? 0
        for character in text {
            desk.type(String(character), on: layout)
            if let trace = desk.machine.lastJudgement, trace.serial != serial {
                serial = trace.serial
                traces.append(trace)
            }
        }
        return traces
    }

    @Test func noTraceUnlessAsked() {
        var desk = Desk()
        desk.type("[jhjij hello ")
        #expect(desk.machine.lastJudgement == nil)
    }

    @Test func keptWordIsTracedAtItsEnd() throws {
        var desk = Self.desk()
        let traces = Self.traces(&desk, typing: "hello ")
        let trace = try #require(traces.first)
        #expect(traces.count == 1)
        #expect(trace.action == .kept)
        #expect(trace.keys == Fixture.abc.strokes("hello"))
        #expect(trace.layout == en)
        #expect(trace.app == "com.apple.TextEdit")
        #expect(trace.seq == nil)
        let decision = try #require(trace.decision)
        #expect(decision.verdict == .keep)
        #expect(decision.typedForm == .known, "explained")
    }

    @Test func switchedWordIsTracedWithItsRetype() throws {
        var desk = Self.desk()
        let trace = try #require(Self.traces(&desk, typing: "[jhjij ").first)
        #expect(trace.action == .switched(to: ru, early: false))
        #expect(trace.keys == Fixture.abc.strokes("[jhjij"))
        #expect(trace.seq == desk.corrections.first?.seq)
        #expect(trace.decision?.verdict == .switch(to: ru))
        #expect(trace.decision?.otherForm == .known)
    }

    @Test func contextIsTheOneTheWordWasJudgedIn() throws {
        var desk = Self.desk()
        let traces = Self.traces(&desk, typing: "[jhjij vbh ")
        #expect(traces.count == 2)
        #expect(traces[0].context?.previousLanguage == nil)
        #expect(traces[1].context?.previousLanguage == "ru")
    }

    @Test func earlySwitchIsTracedAtItsLetter() throws {
        var desk = Self.desk()
        let traces = Self.traces(&desk, typing: "ghbdtn ")
        #expect(traces.count == 1, "the end of a word switched inside it is no second word")
        let trace = try #require(traces.first)
        #expect(trace.action == .switched(to: ru, early: true))
        #expect(trace.keys == Fixture.abc.strokes("ghb"))
        #expect(trace.seq != nil)
        #expect(trace.decision != nil)
    }

    @Test func wordCorrectionIsTracedByItsKind() throws {
        var desk = Self.desk(Settings(typoCorrection: true))
        let trace = try #require(Self.traces(&desk, typing: "wrold ").first)
        #expect(trace.action == .corrected(.typo))
        #expect(trace.layout == en)
        #expect(trace.seq == desk.corrections.first?.seq)
    }

    @Test(arguments: [
        (AppMode.manualOnly, JudgeTrace.Skip.appMode),
        (AppMode.off, JudgeTrace.Skip.appMode),
    ])
    func appModeIsWhyAWordIsNotJudged(mode: AppMode, skip: JudgeTrace.Skip) throws {
        var desk = Self.desk()
        desk.send(.appModeChanged(mode))
        let trace = try #require(Self.traces(&desk, typing: "[jhjij ").first)
        #expect(trace.action == .notJudged(skip))
        #expect(trace.keys == Fixture.abc.strokes("[jhjij"))
    }

    @Test func passwordFieldAndUnknownFocusAreWhyNot() throws {
        var secure = Self.desk(focus: Focus(bundleID: "com.apple.Safari", isSecureField: false))
        secure.send(.focusChanged(Focus(bundleID: "com.apple.Safari", isSecureField: true)))
        // A password field keeps no word: nothing is typed into the buffer.
        #expect(Self.traces(&secure, typing: "[jhjij ").isEmpty)
        var unknown = Self.desk(focus: .unknown(bundleID: "com.apple.Safari"))
        let trace = try #require(Self.traces(&unknown, typing: "[jhjij ").first)
        #expect(trace.action == .notJudged(.unknownFocus))
    }

    @Test func switchingOffIsWhyNot() throws {
        let none = TextCorrections(doubleCapitals: false, capsLock: false, abbreviations: false, yo: false,
                                   hyphen: false)
        var desk = Self.desk(Settings(autoswitch: false, corrections: none, typoCorrection: false))
        let trace = try #require(Self.traces(&desk, typing: "[jhjij ").first)
        #expect(trace.action == .notJudged(.autoswitchOff))
    }

    @Test func noModelIsWhyNot() throws {
        var desk = Desk(classifier: nil)
        desk.machine = InputMachine(layouts: [Fixture.abc, Fixture.russian], currentLayout: en,
                                    tracesJudgements: true)
        desk.send(.focusChanged(Desk.textEdit))
        let trace = try #require(Self.traces(&desk, typing: "[jhjij ").first)
        #expect(trace.action == .notJudged(.noClassifier))
    }

    @Test func wordRetypedByHandBeforeItsEndIsLeftAlone() throws {
        var desk = Self.desk()
        desk.type("hello")
        desk.tapOption()
        let trace = try #require(Self.traces(&desk, typing: " ", on: Fixture.russian).first)
        #expect(trace.action == .notJudged(.leftAlone))
    }

    @Test func oneTracePerWord() {
        var desk = Self.desk()
        // "hello." is judged at the period; the space after it is no new word,
        // nor is the second space.
        var traces = Self.traces(&desk, typing: "hello.  world")
        desk.press(KeyCode.tab)
        if let trace = desk.machine.lastJudgement, trace.serial != traces.last?.serial { traces.append(trace) }
        #expect(traces.map(\.keys.count) == [6, 5])
    }

    /// Tracing changes nothing the machine does.
    @Test func tracingLeavesTheOutputAlone() {
        func session(tracing: Bool) -> [Output] {
            var machine = InputMachine(settings: Settings(typoCorrection: true),
                                       layouts: [Fixture.abc, Fixture.russian], currentLayout: en,
                                       classifier: Desk.classifier, tracesJudgements: tracing)
            var outputs: [Output] = [machine.handle(.focusChanged(Desk.textEdit))]
            var time = 100.0
            for text in ["ghbdtn ", "hello ", "[jhjij, ", "wrold "] {
                for stroke in Fixture.abc.strokes(text) {
                    time += 0.05
                    let flags: UInt64 = stroke.modifiers.contains(.shift) ? Keyboard.leftShift : 0
                    outputs.append(machine.handle(.key(KeyEvent(.down, keyCode: stroke.keyCode, flags: flags), time: time)))
                    if let seq = machine.pendingRetypeSeq {
                        outputs.append(machine.handle(.retypePosted(seq: seq, time: time)))
                        outputs.append(machine.handle(.key(KeyEvent(.down, keyCode: 0, origin: .own(seq: seq, last: true)),
                                                           time: time)))
                    }
                }
            }
            return outputs
        }
        #expect(session(tracing: true) == session(tracing: false))
    }
}

/// A fresh machine made from the snapshot of another goes on as that one does.
@Suite struct MachineSnapshotTests {
    @Test func freshMachineGoesOnAsTheOldOne() throws {
        var desk = Desk(Settings(typoCorrection: true))
        desk.type("[jhjij vbh ")
        desk.send(.languageContextChanged(LanguageContext(app: "com.apple.TextEdit",
                                                          prior: LanguagePrior(counts: ["ru": 300]))))
        desk.send(.focusChanged(Focus(bundleID: "com.apple.TextEdit")))
        #expect(desk.machine.isQuiet)
        let snapshot = try JSONDecoder().decode(MachineSnapshot.self, from: JSONEncoder().encode(desk.machine.snapshot))
        #expect(snapshot == desk.machine.snapshot)
        var copy = desk
        copy.machine = InputMachine(snapshot: snapshot, classifier: Desk.classifier)
        copy.tape = []
        desk.tape = []
        for text in ["ghbdtn ", "hello ", "vbh ", "[jhjij, "] {
            desk.type(text)
            copy.type(text)
        }
        desk.press(KeyCode.delete)
        copy.press(KeyCode.delete)
        #expect(copy.tape == desk.tape)
        #expect(copy.text == desk.text)
        #expect(desk.tape?.contains { $0.output.effects.contains { if case .corrected = $0 { true } else { false } } } == true)
    }

    @Test func machineIsQuietOnlyWithNothingInFlight() {
        var desk = Desk()
        #expect(desk.machine.isQuiet)
        desk.type("hel", settling: false)
        #expect(!desk.machine.isQuiet, "a word in the buffer")
        desk.send(.click(time: desk.time))
        #expect(desk.machine.isQuiet)
        desk.type("[jhjij ", settling: false)
        #expect(desk.machine.isHolding)
        #expect(!desk.machine.isQuiet, "a retype in flight")
    }

    /// The shortcut's next press goes on with the phrase (`ManualActions`);
    /// a snapshot does not hold that. The machine is not quiet right after the
    /// shortcut, and a click or a cancelled retype ends the phrase. The word
    /// in the buffer already keeps the machine from being quiet; `isQuiet`
    /// asks `manual.isIdle` too, so it stays true if the buffer ever empties
    /// with the phrase left.
    @Test func machineIsNotQuietRightAfterTheRetypeShortcut() {
        var desk = Desk(Settings(corrections: TextCorrections(phraseRetype: true)))
        desk.type("hello world ")
        desk.tapOption()
        #expect(!desk.machine.isQuiet, "the retype is posted, its word is in the buffer")
        desk.send(.click(time: desk.time))
        #expect(desk.machine.isQuiet)
        desk.type("hello ")
        desk.cancelRetypes = true
        desk.tapOption()
        #expect(desk.machine.isQuiet, "a cancelled retype ends the phrase and empties the buffer")
    }

    /// A segment that starts at the first quiet point after the shortcut goes
    /// on as the recorded machine did.
    @Test func segmentStartingAfterTheRetypeShortcutGoesOnAsTheOldMachine() {
        var tape = SessionTape(Settings(corrections: TextCorrections(phraseRetype: true)))
        tape.desk.type("hello ")
        tape.desk.cancelRetypes = true
        tape.desk.tapOption()
        tape.desk.cancelRetypes = false
        tape.desk.send(.click(time: tape.desk.time))
        tape.startSegment()
        tape.desk.type("hello ")
        tape.desk.tapOption()
        let session = tape.session
        #expect(session.segments.count == 2)
        for segment in session.segments {
            let run = SessionDriver.run(segment, mode: .exact, classifier: SessionTape.classifier)
            #expect(run.mismatch == nil)
        }
    }

    @Test func snapshotCarriesTheRetypeNumbering() throws {
        var desk = Desk()
        desk.type("[jhjij ")
        desk.send(.focusChanged(Desk.textEdit))
        var copy = InputMachine(snapshot: desk.machine.snapshot, classifier: Desk.classifier)
        var time = desk.time
        for stroke in Fixture.abc.strokes("[jhjij ") {
            time += 0.05
            let output = copy.handle(.key(KeyEvent(.down, keyCode: stroke.keyCode), time: time))
            if let retype = output.retype {
                #expect(retype.seq == (desk.corrections.first?.seq ?? 0) + 1)
            }
        }
    }
}
