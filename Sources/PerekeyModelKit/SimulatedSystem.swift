// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyCore

/// The system layer as a simulated replay plays it, as `correctionSession`
/// of `perekey-bench` does: every retype is posted at once and its keys come
/// back through the tap, every layout the machine selects is confirmed, held
/// events come back `.replayed`, a selection is answered with as many "x" as
/// the recorded one had. Nothing is ever cancelled.
///
/// Kept apart from `SessionDriver`, which only feeds it and watches.
public struct SimulatedSystem: Sendable {
    /// Called for every event handed to the machine: the event, the recorded
    /// event it stands for (`source`), the answer, and the machine after it.
    public typealias Observer = (_ event: InputEvent, _ source: Int?, _ output: Output,
                                 _ change: MachineChange) -> Void

    /// What an observer learns of the machine around one event.
    public struct MachineChange: Sendable {
        /// The retype the fence waited for, before the event and after it.
        public var pendingBefore: UInt32?
        public var pendingAfter: UInt32?
        /// `InputMachine.lastJudgement` after the event.
        public var lastJudgement: JudgeTrace?

        public init(pendingBefore: UInt32?, pendingAfter: UInt32?, lastJudgement: JudgeTrace?) {
            self.pendingBefore = pendingBefore
            self.pendingAfter = pendingAfter
            self.lastJudgement = lastJudgement
        }
    }

    /// Seconds between the events the system posts itself.
    public static let tick = 0.0001

    /// The latest time an event carried.
    public private(set) var time = 0.0
    /// The `seq` of the last correction the machine reported: the hint's
    /// Undo goes to it.
    public private(set) var lastCorrection: UInt32?

    private var held: [(event: InputEvent, source: Int?)] = []
    private var retypes: [Retype] = []
    private var selected: [LayoutID] = []
    private var selectionsAsked: [UInt32] = []
    /// The lengths of the recorded selections, in order.
    private var selections: [Int]

    public init(selections: [Int] = []) {
        self.selections = selections
    }

    /// Hands a user's or the environment's event to the machine, then plays
    /// the system layer until nothing is left to post.
    public mutating func send(_ event: InputEvent, source: Int?, to machine: inout InputMachine,
                              observe: Observer)
    {
        if let time = RecordedEvent(event).time { self.time = max(self.time, time) }
        handle(event, source: source, machine: &machine, observe: observe)
        settle(&machine, observe: observe)
    }

    private mutating func handle(_ event: InputEvent, source: Int?, machine: inout InputMachine,
                                 observe: Observer)
    {
        let before = machine.pendingRetypeSeq
        let output = machine.handle(event)
        observe(event, source, output, MachineChange(pendingBefore: before, pendingAfter: machine.pendingRetypeSeq,
                                                     lastJudgement: machine.lastJudgement))
        if output.disposition == .hold {
            switch event {
            case .key, .flagsChanged: held.append((event, source))
            default: break
            }
        }
        for effect in output.effects {
            switch effect {
            case let .selectLayout(id): selected.append(id)
            case let .retype(retype): retypes.append(retype)
            case let .corrected(correction): lastCorrection = correction.seq
            case let .convertSelection(seq): selectionsAsked.append(seq)
            case .releaseHeld:
                let events = held
                held.removeAll()
                for (event, source) in events {
                    handle(replayed(event), source: source, machine: &machine, observe: observe)
                }
            default: break
            }
        }
    }

    private mutating func replayed(_ event: InputEvent) -> InputEvent {
        time += Self.tick
        switch event {
        case var .key(key, _):
            key.origin = .replayed
            return .key(key, time: time)
        case let .flagsChanged(keyCode, flags, _, _, location):
            return .flagsChanged(keyCode: keyCode, flags: flags, origin: .replayed, time: time, location: location)
        default:
            return event
        }
    }

    private mutating func settle(_ machine: inout InputMachine, observe: Observer) {
        while !selectionsAsked.isEmpty || !retypes.isEmpty || !selected.isEmpty {
            if !selectionsAsked.isEmpty {
                let seq = selectionsAsked.removeFirst()
                let length = selections.isEmpty ? 0 : selections.removeFirst()
                handle(.selectionRead(seq: seq, text: String(repeating: "x", count: length)), source: nil,
                       machine: &machine, observe: observe)
            } else if !retypes.isEmpty {
                let retype = retypes.removeFirst()
                // As the engine: a retype whose fence is gone is not posted.
                guard machine.pendingRetypeSeq == retype.seq else { continue }
                time += Self.tick
                handle(.retypePosted(seq: retype.seq, time: time), source: nil, machine: &machine, observe: observe)
                guard !retype.viaAccessibility else { continue }
                let count = retype.deleteCount + retype.keys.count
                for index in 0..<count {
                    time += Self.tick
                    let key = KeyEvent(.down, keyCode: 0, origin: .own(seq: retype.seq, last: index == count - 1))
                    handle(.key(key, time: time), source: nil, machine: &machine, observe: observe)
                }
            } else {
                handle(.layoutChanged(selected.removeFirst()), source: nil, machine: &machine, observe: observe)
            }
        }
    }
}
