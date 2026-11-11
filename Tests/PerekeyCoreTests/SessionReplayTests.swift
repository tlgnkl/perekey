// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import PerekeyCore
import PerekeyModelKit

/// A session recorded on the test desk, as the recorder of the app writes one.
struct SessionTape {
    var desk: Desk
    var lines: [SessionLine]

    init(_ settings: Settings = Settings(), focus: Focus = Desk.textEdit) {
        desk = Desk(settings, focus: focus)
        lines = [.header(SessionHeader(perekey: "0.2.0", build: "test", time: 1_762_780_000))]
        startSegment()
    }

    /// A segment starts at a quiet point with the snapshot of the machine.
    mutating func startSegment() {
        precondition(desk.machine.isQuiet)
        flush()
        lines.append(.snapshot(SessionSnapshot(desk.machine)))
        desk.tape = []
    }

    /// The events since the last flush go to the file.
    mutating func flush() {
        for step in desk.tape ?? [] { lines.append(.step(step)) }
        desk.tape = desk.tape.map { _ in [] }
    }

    /// A gap: what follows is not recorded until the next segment.
    mutating func gap(_ reason: SessionGap, during: (inout Desk) -> Void) {
        flush()
        lines.append(.gap(reason))
        desk.tape = nil
        during(&desk)
        startSegment()
    }

    var session: Session {
        mutating get {
            flush()
            return try! SessionFile.read(SessionFile.data(lines))
        }
    }

    static func classifier(_ spec: ClassifierSpec) -> Classifier? {
        Classifier(model: ModelFixture.model, options: spec.options)
    }
}

@Suite struct SessionFileTests {
    @Test func fileRoundTripsLineByLine() throws {
        var tape = SessionTape()
        tape.desk.type("[jhjij hello ")
        tape.flush()
        let data = try SessionFile.data(tape.lines)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.hasSuffix("\n"))
        #expect(text.split(separator: "\n").count == tape.lines.count)
        #expect(text.hasPrefix(#"{"header":{"#))
        let session = try SessionFile.read(data)
        #expect(session.header.format == SessionHeader.format && session.header.version == 1)
        #expect(session.segments.count == 1)
        #expect(session.segments[0].steps == tape.lines.compactMap { if case let .step(step) = $0 { step } else { nil } })
        #expect(session.segments[0].lines.first == 3, "line 1 the header, 2 the snapshot")
        #expect(!session.droppedTail)
    }

    @Test func gapStartsASegmentThatStandsAlone() throws {
        var tape = SessionTape()
        tape.desk.type("[jhjij vbh ")
        tape.gap(.secureField) { desk in
            desk.send(.focusChanged(Focus(bundleID: "com.apple.Safari", isSecureField: true)))
            desk.type("ctrhtn ")
            desk.send(.focusChanged(Focus(bundleID: "com.apple.TextEdit")))
            desk.send(.layoutChanged(Fixture.abc.id))
            desk.appLayout = Fixture.abc.id
        }
        tape.desk.type("ghbdtn ")
        let session = tape.session
        #expect(session.segments.count == 2)
        #expect(session.segments[0].gap == .secureField)
        #expect(session.segments[1].gap == nil)
        // The second segment replays alone: it numbers its retypes on.
        let second = SessionDriver.run(session.segments[1], mode: .exact, classifier: SessionTape.classifier)
        #expect(second.mismatch == nil)
        #expect(second.steps.contains { $0.trace?.action == .switched(to: Fixture.russian.id, early: true) })
    }

    @Test(arguments: [
        ("", "empty"),
        ("not json\n", "line 1"),
        (#"{"header":{"format":"other","version":1,"perekey":"","build":"","time":0}}"# + "\n", "not a Perekey session"),
        (#"{"header":{"format":"perekey-session","version":2,"perekey":"","build":"","time":0}}"# + "\n", "version 2"),
    ])
    func brokenStartIsRejected(text: String, message: String) {
        #expect {
            try SessionFile.read(Data(text.utf8))
        } throws: { error in
            "\(error)".contains(message)
        }
    }

    @Test func brokenLinesAreRejectedByNumber() throws {
        var tape = SessionTape()
        tape.desk.type("hello ")
        tape.flush()
        var lines = try #require(String(data: SessionFile.data(tape.lines), encoding: .utf8))
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // A step before any snapshot.
        var noSnapshot = lines
        noSnapshot.remove(at: 1)
        #expect { try SessionFile.read(Data(noSnapshot.joined(separator: "\n").utf8)) } throws: { error in
            "\(error)".contains("line 2") && "\(error)".contains("snapshot")
        }
        // A step after a gap, without its snapshot.
        var afterGap = lines
        afterGap.insert(#"{"gap":"secureInput"}"#, at: 3)
        #expect { try SessionFile.read(Data(afterGap.joined(separator: "\n").utf8)) } throws: { error in
            "\(error)".contains("line 5") && "\(error)".contains("snapshot")
        }
        // A broken line in the middle.
        lines[4] = String(lines[4].dropLast(5))
        #expect { try SessionFile.read(Data(lines.joined(separator: "\n").utf8)) } throws: { error in
            "\(error)".contains("line 5")
        }
    }

    @Test func cutLastLineIsDropped() throws {
        var tape = SessionTape()
        tape.desk.type("hello ")
        tape.flush()
        var data = try SessionFile.data(tape.lines)
        let whole = try SessionFile.read(data)
        // The app stopped in the middle of writing a line.
        data.removeLast(9)
        let cut = try SessionFile.read(data)
        #expect(cut.droppedTail)
        #expect(cut.segments[0].steps.count == whole.segments[0].steps.count - 1)
    }
}

@Suite struct SessionDriverTests {
    /// What the recorder of the same code wrote replays without a difference.
    @Test func exactReplayOfItsOwnRecordingMatches() {
        var tape = SessionTape(Settings(typoCorrection: true))
        tape.desk.type("ghbdtn [jhjij hello ")
        tape.desk.press(KeyCode.delete)
        tape.desk.type(" vbh ")
        tape.desk.tapOption()
        tape.desk.type("wrold ")
        tape.desk.send(.click(time: tape.desk.time))
        tape.desk.type("ghb", settling: false)
        tape.desk.settle()
        tape.desk.type("dtn ")
        let session = tape.session
        let run = SessionDriver.run(session.segments[0], mode: .exact, classifier: SessionTape.classifier)
        #expect(run.mismatch == nil)
        #expect(run.steps.count == session.segments[0].steps.count)
        #expect(run.steps.compactMap(\.trace).count >= 6)
    }

    @Test func exactReplayNamesTheFirstDifference() throws {
        var tape = SessionTape()
        tape.desk.type("[jhjij vbh ")
        var session = tape.session
        let index = try #require(session.segments[0].steps.firstIndex { !$0.output.effects.isEmpty && $0.event.isUserKey })
        session.segments[0].steps[index].output.effects.removeAll()
        let run = SessionDriver.run(session.segments[0], mode: .exact, classifier: SessionTape.classifier)
        let mismatch = try #require(run.mismatch)
        #expect(mismatch.step == index)
        #expect(mismatch.line == session.segments[0].lines[index])
        #expect(mismatch.expected.effects.isEmpty)
        #expect(!mismatch.got.effects.isEmpty)
    }

    @Test func otherModelDiffersOnTheFirstSwitch() throws {
        var tape = SessionTape()
        tape.desk.type("hello [jhjij ")
        let session = tape.session
        let run = SessionDriver.run(session.segments[0], mode: .exact) { spec in
            var options = spec.options
            options.threshold = 1000
            return Classifier(model: ModelFixture.model, options: options)
        }
        #expect(run.mismatch != nil)
    }

    /// Simulated: only the user's and the system's events go in; the driver
    /// plays the system layer. The same code then decides as recorded.
    @Test func simulatedReplayDecidesAsRecorded() throws {
        var tape = SessionTape()
        tape.desk.type("ghbdtn [jhjij hello vbh ")
        tape.desk.press(KeyCode.delete)
        tape.desk.type(" ")
        let session = tape.session
        let exact = SessionDriver.run(session.segments[0], mode: .exact, classifier: SessionTape.classifier)
        let simulated = SessionDriver.run(session.segments[0], mode: .simulated, classifier: SessionTape.classifier)
        #expect(simulated.mismatch == nil, "simulated compares nothing")
        let actions = { (run: ReplayRun) in run.steps.compactMap { step in step.trace.map { ($0.action, step.source) } } }
        #expect(actions(simulated).map(\.0) == actions(exact).map(\.0))
        #expect(actions(simulated).map(\.1) == actions(exact).map(\.1), "a word is found by its key in the recording")
        // No own or replayed key of the recording went in.
        for step in simulated.steps where step.recorded != nil {
            #expect(!step.event.isOwnOrReplayed)
        }
        #expect(simulated.steps.contains { $0.recorded == nil }, "the driver posted the retypes itself")
    }

    @Test func simulatedReplayActsOnTheCandidateDecision() throws {
        var tape = SessionTape()
        tape.desk.type("[jhjij hello ")
        let session = tape.session
        let never = SessionDriver.run(session.segments[0], mode: .simulated) { spec in
            var options = spec.options
            options.threshold = 1000
            return Classifier(model: ModelFixture.model, options: options)
        }
        #expect(never.steps.compactMap(\.trace).map(\.action) == [.kept, .kept])
        #expect(!never.steps.contains { $0.output.effects.contains { if case .retype = $0 { true } else { false } } })
    }

    @Test func hintUndoGoesToTheCandidateCorrection() throws {
        var tape = SessionTape()
        tape.desk.type("hello [jhjij ")
        let seq = try #require(tape.desk.corrections.last).seq
        tape.desk.send(.undoLastCorrection(seq: seq, time: tape.desk.time))
        tape.desk.settle()
        let session = tape.session
        // The candidate numbers its retypes its own way: one more switch first.
        let simulated = SessionDriver.run(session.segments[0], mode: .simulated, classifier: SessionTape.classifier)
        #expect(simulated.steps.contains { $0.output.effects.contains { if case .correctionUndone = $0 { true } else { false } } })
    }
}

extension RecordedEvent {
    var isUserKey: Bool {
        if case let .key(key, _) = self { key.origin == .user && key.phase == .down } else { false }
    }

    var isOwnOrReplayed: Bool {
        switch self {
        case let .key(key, _): key.origin != .user
        case let .flagsChanged(_, _, origin, _, _): origin != .user
        default: false
        }
    }
}
