// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyCore
import PerekeyDesk

/// One event the replay handed to the machine, and what came of it.
public struct ReplayStep: Sendable {
    /// The index of the event in `SessionSegment.steps`; nil for an event
    /// the simulated system layer made.
    public var recorded: Int?
    /// The recorded user event this one stands for: itself, or the held one
    /// it brings back (`.replayed`). Nil for the machine's own events.
    /// Words of two runs over one recording meet by it.
    public var source: Int?
    public var event: RecordedEvent
    public var output: OutputDigest
    /// The word judged at this event, if one was.
    public var trace: JudgeTrace?
    /// The user changed the layout: from the menu, another app, or a shortcut
    /// that only switches it. Not a layout Perekey selected and the system confirmed.
    public var userLayoutChange: Bool
    /// The fence let held input go because its time ran out.
    public var fenceExpired: Bool
}

/// The first answer of the machine that differs from the recorded one.
public struct ReplayMismatch: Sendable, Equatable {
    /// The index in `SessionSegment.steps`.
    public var step: Int
    /// Its line in the file.
    public var line: Int?
    public var expected: OutputDigest
    public var got: OutputDigest
}

public struct ReplayRun: Sendable {
    public var steps: [ReplayStep] = []
    /// Exact mode only: the first difference from the recording.
    public var mismatch: ReplayMismatch?
}

/// Feeds a recorded segment to a fresh `InputMachine` with judgement traces
/// on (docs/classifier.md, «Замер на живых сессиях»).
///
/// - `exact`: every recorded event as it is, the machine's own and the
///   replayed ones too, and every answer compared with the recorded one. The
///   check that the recording is complete and the machine deterministic.
/// - `simulated`: only the user's and the environment's events; `EvalDesk`
///   plays the system layer (`EvalDesk.replay`): retypes are posted, their
///   keys come back, selected layouts are confirmed, held events come back,
///   deadlines pass. For a classifier or logic that decides otherwise than
///   the recorded one: the recorded own events would no longer fit.
public enum SessionDriver {
    public enum Mode: Sendable {
        case exact
        case simulated
    }

    /// Makes the classifier of a recorded spec; nil for none.
    public typealias ClassifierSource = (ClassifierSpec) -> Classifier?

    public static func run(_ segment: SessionSegment, mode: Mode, classifier: ClassifierSource) -> ReplayRun {
        var machine = InputMachine(snapshot: segment.snapshot.machine,
                                   classifier: segment.snapshot.classifier.flatMap(classifier), tracesJudgements: true)
        var watch = Watch(pendingSelections: segment.snapshot.machine.pendingSelections)
        switch mode {
        case .exact: exact(segment, machine: &machine, watch: &watch, classifier: classifier)
        case .simulated: simulated(segment, machine: &machine, watch: &watch, classifier: classifier)
        }
        return watch.run
    }

    private static func exact(_ segment: SessionSegment, machine: inout InputMachine, watch: inout Watch,
                              classifier: ClassifierSource)
    {
        // Held events come back in order: a replayed one stands for the
        // oldest held.
        var heldSources: [Int?] = []
        for (index, step) in segment.steps.enumerated() {
            let event = step.event.inputEvent(classifier: classifier)
            var source: Int? = index
            let origin: EventOrigin? = switch event {
            case let .key(key, _): key.origin
            case let .flagsChanged(_, _, origin, _, _): origin
            default: nil
            }
            if origin == .replayed {
                source = heldSources.isEmpty ? index : heldSources.removeFirst()
            } else if origin?.isOwn == true {
                source = nil
            }
            let before = machine.pendingRetypeSeq
            let output = machine.handle(event)
            if output.disposition == .hold, step.event.isKeyOrFlags { heldSources.append(source) }
            let change = ReplayChange(pendingBefore: before, pendingAfter: machine.pendingRetypeSeq,
                                      lastJudgement: machine.lastJudgement)
            let digest = watch.observe(event, recorded: index, source: source, output: output, change: change)
            if watch.run.mismatch == nil, digest != step.output {
                watch.run.mismatch = ReplayMismatch(step: index, line: segment.lines.indices.contains(index)
                                                        ? segment.lines[index] : nil,
                                                    expected: step.output, got: digest)
            }
        }
    }

    private static func simulated(_ segment: SessionSegment, machine: inout InputMachine, watch: inout Watch,
                                  classifier: ClassifierSource)
    {
        let snapshot = segment.snapshot.machine
        var desk = EvalDesk(machine: machine, settings: snapshot.settings, layouts: snapshot.layouts,
                            mode: snapshot.appMode,
                            time: segment.steps.lazy.compactMap(\.event.time).first ?? 0)
        desk.recording = true
        var seen = 0
        var pending = machine.pendingRetypeSeq
        var heldSources: [Int?] = []
        // The layouts the recorded machine selected and the system has not
        // confirmed yet: a recorded `layoutChanged` to one of them is
        // Perekey's, and the desk confirms its own.
        var recordedSelections = snapshot.pendingSelections
        for (index, step) in segment.steps.enumerated() {
            defer {
                for case let .selectLayout(id) in step.output.effects {
                    if recordedSelections.count == MachineSnapshot.pendingSelectionLimit { recordedSelections.removeFirst() }
                    recordedSelections.append(id)
                }
            }
            var event = step.event.inputEvent(classifier: classifier)
            switch event {
            case let .key(key, _) where key.origin != .user:
                continue
            case let .flagsChanged(_, _, origin, _, _) where origin != .user:
                continue
            case .retypePosted, .retypeCancelled, .selectionRead, .deadline:
                continue
            case let .layoutChanged(id):
                if let found = recordedSelections.firstIndex(of: id) {
                    recordedSelections.removeSubrange(...found)
                    continue
                }
                recordedSelections.removeAll()
            case let .undoLastCorrection(_, time):
                // The hint shows the correction the replayed machine made.
                event = .undoLastCorrection(seq: desk.corrections.last?.seq ?? 0, time: time)
            default:
                break
            }
            desk.replay(event)
            // The first call that is not a deadline is the recorded event;
            // the rest the desk made.
            var matched = false
            for record in desk.records[seen...] {
                var recorded: Int?
                var source: Int?
                let origin = Self.origin(of: record.input)
                if origin == .replayed {
                    source = heldSources.isEmpty ? nil : heldSources.removeFirst()
                } else if origin?.isOwn != true, !matched, !Self.isDeadline(record.input) {
                    matched = true
                    recorded = index
                    source = index
                }
                if record.output.disposition == .hold, origin != nil { heldSources.append(source) }
                let change = ReplayChange(pendingBefore: pending, pendingAfter: record.pendingRetypeSeq,
                                          lastJudgement: record.lastJudgement)
                pending = record.pendingRetypeSeq
                _ = watch.observe(record.input, recorded: recorded, source: source, output: record.output,
                                  change: change)
            }
            seen = desk.records.count
        }
        machine = desk.machine
    }

    private static func origin(of event: InputEvent) -> EventOrigin? {
        switch event {
        case let .key(key, _): key.origin
        case let .flagsChanged(_, _, origin, _, _): origin
        default: nil
        }
    }

    private static func isDeadline(_ event: InputEvent) -> Bool {
        if case .deadline = event { true } else { false }
    }

    /// What the watch learns of the machine around one event.
    struct ReplayChange {
        /// The retype the fence waited for, before the event and after it.
        var pendingBefore: UInt32?
        var pendingAfter: UInt32?
        /// `InputMachine.lastJudgement` after the event.
        var lastJudgement: JudgeTrace?
    }

    /// Watches the machine as events go in, and writes the steps down.
    private struct Watch {
        var run = ReplayRun()
        /// Layouts the machine selected, not confirmed yet (as `Fence`).
        var pendingSelections: [LayoutID]
        var lastSerial = 0

        mutating func observe(_ event: InputEvent, recorded: Int?, source: Int?, output: Output,
                              change: ReplayChange) -> OutputDigest
        {
            guard let recordedEvent = RecordedEvent(event) else { return OutputDigest(output) }
            let digest = OutputDigest(output)
            var trace: JudgeTrace?
            if let last = change.lastJudgement, last.serial != lastSerial {
                lastSerial = last.serial
                trace = last
            }
            var userLayoutChange = false
            if case let .layoutChanged(id) = event {
                if let found = pendingSelections.firstIndex(of: id) {
                    pendingSelections.removeSubrange(...found)
                } else {
                    pendingSelections.removeAll()
                    userLayoutChange = true
                }
            } else if recordedEvent.isUserInput,
                      digest.effects.contains(where: { if case .selectLayout = $0 { true } else { false } }),
                      !digest.effects.contains(where: {
                          switch $0 {
                          case .retype, .convertSelection: true
                          default: false
                          }
                      })
            {
                userLayoutChange = true
            }
            for case let .selectLayout(id) in digest.effects {
                if pendingSelections.count == MachineSnapshot.pendingSelectionLimit { pendingSelections.removeFirst() }
                pendingSelections.append(id)
            }
            let released = change.pendingBefore != nil && change.pendingAfter != change.pendingBefore
            let fenceExpired: Bool = switch recordedEvent {
            case .deadline, .click: released
            case .key, .flagsChanged: recordedEvent.isUserInput && released
            default: false
            }
            run.steps.append(ReplayStep(recorded: recorded, source: source, event: recordedEvent, output: digest,
                                        trace: trace, userLayoutChange: userLayoutChange, fenceExpired: fenceExpired))
            return digest
        }
    }
}

extension RecordedEvent {
    var isKeyOrFlags: Bool {
        switch self {
        case .key, .flagsChanged: true
        default: false
        }
    }

    /// A key or modifier event of the user's, or one of theirs held and
    /// posted again: not Perekey's own.
    var isUserInput: Bool {
        switch self {
        case let .key(key, _): !key.origin.isOwn
        case let .flagsChanged(_, _, origin, _, _): !origin.isOwn
        default: false
        }
    }

    /// A key down the user pressed, as first seen (not a replayed copy).
    var userKeyDown: KeyEvent? {
        if case let .key(key, _) = self, key.origin == .user, key.phase == .down { key } else { nil }
    }
}
