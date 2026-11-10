// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyCore

/// `InputMachine` with the system around it, in memory: a text field with a
/// caret, the layout the app types in, held keys, retypes, selection reads
/// and deadlines (docs/eval.md, «Наборщик и стенд»).
///
/// It follows the test `Desk` (Tests/PerekeyCoreTests/Desk.swift), the
/// driver of `perekey-bench` and `InputEngine`: the decision about an event
/// first, its effects after. A retype alone is posted at once; a layout
/// selection with its retype and a selection read wait until the desk
/// catches up (`settle()`), the main thread of the app. When it catches up
/// is the lag rule of `Setup.lag`.
public struct EvalDesk: Sendable {
    /// Every number here is a model of the system, not a measurement: each
    /// says where it comes from.
    public struct Options: Hashable, Sendable {
        /// Seconds between two held keys posted again: `Desk` (`.releaseHeld`).
        public var replayStep = 0.0005
        /// Seconds from a retype taken up to its posting: `Desk.settle`.
        public var retypeStep = 0.001
        /// Seconds between the synthetic keys of a retype: `Desk.settle`.
        public var ownKeyStep = 0.0001
        /// Without new key downs, the desk catches up once this much model
        /// time passed between two events (docs/eval.md, «Отставание»).
        public var catchUpGap = 0.05
        /// Slack of time comparisons: times are sums of decimal steps.
        public var epsilon = 1e-9

        public init() {}
    }

    /// Whether the app lets the desk read the text before the caret.
    public enum FieldKind: String, Hashable, Sendable, CaseIterable {
        /// A field with accessibility: a retype whose expected text is not
        /// before the caret is cancelled (`retypeCancelled`).
        case plain
        /// No accessibility (Electron, terminals): no check, every retype is posted.
        case blind
    }

    public struct Setup: Sendable {
        public var settings: Settings
        public var layouts: [LayoutMap]
        public var start: LayoutID
        public var classifier: Classifier?
        public var focus: Focus
        public var mode: AppMode
        public var prior: LanguagePrior?
        public var secureInput: Bool
        public var field: FieldKind
        /// Key downs the typist sends before the desk carries out a layout
        /// selection or a retype; 0 is at once.
        public var lag: Int

        public init(settings: Settings, layouts: [LayoutMap], start: LayoutID, classifier: Classifier?,
                    focus: Focus, mode: AppMode = .auto, prior: LanguagePrior? = nil, secureInput: Bool = false,
                    field: FieldKind = .plain, lag: Int = 0)
        {
            self.settings = settings
            self.layouts = layouts
            self.start = start
            self.classifier = classifier
            self.focus = focus
            self.mode = mode
            self.prior = prior
            self.secureInput = secureInput
            self.field = field
            self.lag = lag
        }
    }

    /// An effect for the app, with the index of the typist's event it came
    /// from: for the effects of a retype, the event that asked for the retype.
    public struct Logged: Hashable, Sendable {
        public var event: Int
        public var effect: Effect
    }

    /// A retype the desk did not carry out: the text before the caret was
    /// not the expected one.
    public struct Cancelled: Hashable, Sendable {
        public var event: Int
        public var seq: UInt32
        public var origin: Retype.Origin
    }

    /// One call of the machine, for `perekey-eval case` and the replay of
    /// recorded sessions.
    public struct Record: Sendable {
        public var event: Int
        public var input: InputEvent
        public var output: Output
        public var text: String
        public var layout: LayoutID
        /// `InputMachine.pendingRetypeSeq` after the call.
        public var pendingRetypeSeq: UInt32?
        /// `InputMachine.lastJudgement` after the call.
        public var lastJudgement: JudgeTrace?
    }

    /// What the main thread does when the desk catches up.
    private enum MainWork: Sendable {
        /// Select the layout, then post the retype that came with it.
        case select(LayoutID, then: CheckedRetype?)
        case readSelection(UInt32)
    }

    private struct CheckedRetype: Sendable {
        var retype: Retype
        /// The caret check failed when the retype was asked for.
        var mismatch: Bool
    }

    public let options: Options
    public private(set) var machine: InputMachine
    public private(set) var time: Double
    public private(set) var field = TextField()
    public private(set) var appLayout: LayoutID
    public private(set) var capsLock = false
    public private(set) var log: [Logged] = []
    public private(set) var cancelled: [Cancelled] = []
    /// Every call of the machine, when `recording` is on.
    public private(set) var records: [Record] = []
    public var recording = false

    private var maps: [LayoutID: LayoutMap]
    private var settings: Settings
    private let fieldKind: FieldKind
    private let lag: Int
    private var mode: AppMode
    private var held: [KeyEvent] = []
    /// Work for the main thread, in order.
    private var mainQueue: [MainWork] = []
    private var deadline: Double?
    /// Key downs since work for the main thread came up.
    private var keyDownsWaiting = 0
    /// The typist's time of the last event.
    private var lastEventTime: Double?
    /// The index of the typist's event being handled.
    private var event = -1
    /// The event that asked for each retype, by `seq`.
    private var requests: [UInt32: Int] = [:]
    /// The event the effects of the retype being posted belong to.
    private var posting: Int?

    /// The event effects are logged under now.
    private var cause: Int { posting ?? event }

    public init(_ setup: Setup, time: Double = 0, options: Options = Options()) {
        self.options = options
        self.time = time
        settings = setup.settings
        fieldKind = setup.field
        lag = max(setup.lag, 0)
        mode = setup.mode
        appLayout = setup.start
        maps = Dictionary(setup.layouts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        machine = InputMachine(settings: setup.settings, layouts: setup.layouts, currentLayout: setup.start,
                               classifier: setup.classifier)
        send(.focusChanged(setup.focus))
        send(.appModeChanged(setup.mode))
        // The app takes the shortcuts away in "off" (AppModeController,
        // InputController.effectiveSettings): the machine only stays quiet.
        if setup.mode == .off { send(.settingsChanged(withoutHotkeys)) }
        if let prior = setup.prior {
            send(.languageContextChanged(LanguageContext(app: setup.focus.bundleID, prior: prior)))
        }
        if setup.secureInput { send(.secureInputChanged(true)) }
    }

    /// A desk around a machine made elsewhere: the replay of a recorded
    /// session starts one from its snapshot (`InputMachine(snapshot:)`),
    /// which already knows the focus, the mode and the layouts. The field
    /// starts empty: what was typed before the recording is not known, so a
    /// `.blind` field posts every retype.
    public init(machine: InputMachine, settings: Settings, layouts: [LayoutMap], mode: AppMode,
                field: FieldKind = .blind, time: Double = 0, options: Options = Options())
    {
        self.options = options
        self.time = time
        self.settings = settings
        fieldKind = field
        lag = 0
        self.mode = mode
        appLayout = machine.currentLayout ?? layouts.first?.id ?? LayoutID(rawValue: "")
        maps = Dictionary(layouts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.machine = machine
    }

    /// One recorded event of the user or the environment, handed to the
    /// machine as it is, at its own time; then the desk catches up. The
    /// machine's own events, replays, retypes posted or cancelled, selections
    /// and deadlines are the desk's to make, not to replay.
    public mutating func replay(_ input: InputEvent) {
        event += 1
        if let eventTime = Self.time(of: input) { time = max(time, eventTime) }
        lastEventTime = time
        deliverDeadlines(settling: true)
        switch input {
        case let .key(key, _):
            self.key(key)
        case let .layoutChanged(id):
            appLayout = id
            send(input)
        case .focusChanged:
            field = TextField()
            send(input)
        case let .appModeChanged(newMode):
            mode = newMode
            send(input)
        case let .layoutsChanged(layouts):
            // The app types keys through these maps.
            maps = Dictionary(layouts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            send(input)
        case let .settingsChanged(newSettings):
            // What the desk sends when the mode goes off or back on.
            settings = newSettings
            send(input)
        default:
            send(input)
        }
        settle()
    }

    private static func time(of input: InputEvent) -> Double? {
        switch input {
        case let .key(_, time), let .flagsChanged(_, _, _, time, _), let .click(time, _), let .scroll(time),
             let .retypePosted(_, time), let .deadline(time), let .undoLastCorrection(_, time):
            time
        default:
            nil
        }
    }

    public var text: String { field.text }

    /// Corrections shown: one hint each.
    public var corrections: [Correction] {
        log.compactMap { if case let .corrected(correction) = $0.effect { correction } else { nil } }
    }

    /// The `seq`s of corrections undone.
    public var undone: [UInt32] {
        log.compactMap { if case let .correctionUndone(seq) = $0.effect { seq } else { nil } }
    }

    /// Whether the main thread has work waiting.
    public var isBehind: Bool { !mainQueue.isEmpty }

    /// One event of the typist at the typist's `time`.
    public mutating func send(_ typed: TypistEvent, at eventTime: Double) {
        event += 1
        let wasBehind = isBehind
        if wasBehind, let last = lastEventTime, eventTime - last >= options.catchUpGap - options.epsilon {
            settle()
        }
        lastEventTime = eventTime
        time = max(time, eventTime)
        if case let .idle(seconds) = typed {
            settle()
            time += seconds
            deliverDeadlines(settling: true)
            return
        }
        deliverDeadlines(settling: false)
        let behindBefore = isBehind
        handle(typed)
        guard isBehind else {
            keyDownsWaiting = 0
            return
        }
        if !behindBefore {
            keyDownsWaiting = 0
        } else if typed.isKeyDown {
            keyDownsWaiting += 1
        }
        if keyDownsWaiting >= lag { settle() }
    }

    /// Catches up and lets every deadline pass: the end of a case.
    public mutating func finish() {
        settle()
        deliverDeadlines(settling: true)
    }

    // MARK: - Events

    private mutating func handle(_ typed: TypistEvent) {
        switch typed {
        case let .keyDown(keyCode, flags):
            key(KeyEvent(.down, keyCode: keyCode, flags: withCapsLock(flags)))
        case let .keyUp(keyCode, flags):
            key(KeyEvent(.up, keyCode: keyCode, flags: withCapsLock(flags)))
        case let .flags(keyCode, flags):
            // Modifiers are never held or posted again, whatever the answer (`Desk.tap`).
            send(.flagsChanged(keyCode: keyCode, flags: withCapsLock(flags), origin: .user, time: time))
        case let .userLayout(id):
            appLayout = id
            send(.layoutChanged(id))
        case let .click(target):
            switch target {
            case .hint:
                send(.click(time: time, onHint: true))
                return
            case .start: field.place(caret: 0)
            case .end: field.placeAtEnd()
            case let .position(position): field.place(caret: position)
            }
            send(.click(time: time))
        case let .focus(focus):
            field = TextField()
            send(.focusChanged(focus))
        case let .mode(newMode):
            let wasOff = mode == .off
            mode = newMode
            send(.appModeChanged(newMode))
            if newMode == .off, !wasOff {
                send(.settingsChanged(withoutHotkeys))
            } else if newMode != .off, wasOff {
                send(.settingsChanged(settings))
            }
        case let .secureInput(on):
            send(.secureInputChanged(on))
        case let .capsLock(on):
            guard on != capsLock else { return }
            capsLock = on
            send(.flagsChanged(keyCode: KeyCode.capsLock, flags: on ? EventFlags.capsLock : 0, origin: .user,
                               time: time))
        case let .select(chars):
            let shift = EventFlags.shift | ModifierKey.leftShift.eventFlagMask
            let leftShift: UInt16 = 56
            send(.flagsChanged(keyCode: leftShift, flags: withCapsLock(shift), origin: .user, time: time))
            for _ in 0..<max(chars, 0) {
                key(KeyEvent(.down, keyCode: KeyCode.leftArrow, flags: withCapsLock(shift)))
                key(KeyEvent(.up, keyCode: KeyCode.leftArrow, flags: withCapsLock(shift)))
            }
            send(.flagsChanged(keyCode: leftShift, flags: withCapsLock(0), origin: .user, time: time))
        case .undoButton:
            // The hint of the last correction; without one there is no button.
            guard let last = corrections.last else { return }
            send(.undoLastCorrection(seq: last.seq, time: time))
        case .idle:
            break
        }
    }

    private var withoutHotkeys: Settings {
        var settings = settings
        settings.hotkeys = []
        return settings
    }

    private func withCapsLock(_ flags: UInt64) -> UInt64 {
        capsLock ? flags | EventFlags.capsLock : flags & ~EventFlags.capsLock
    }

    // MARK: - The machine

    private mutating func send(_ input: InputEvent) {
        let output = machine.handle(input)
        record(input, output)
        run(output.effects)
    }

    /// A key: the decision first (pass, hold, drop), then the effects, or a
    /// `releaseHeld` of the same output would lose the key (`Desk.key`).
    private mutating func key(_ event: KeyEvent) {
        let output = machine.handle(.key(event, time: time))
        switch output.disposition {
        case .pass:
            if event.phase == .down, !event.origin.isOwn { typeIntoField(event) }
        case .hold:
            held.append(event)
        case .drop:
            break
        }
        record(.key(event, time: time), output)
        run(output.effects)
    }

    private mutating func record(_ input: InputEvent, _ output: Output) {
        guard recording else { return }
        records.append(Record(event: event, input: input, output: output, text: field.text, layout: appLayout,
                              pendingRetypeSeq: machine.pendingRetypeSeq, lastJudgement: machine.lastJudgement))
    }

    private mutating func typeIntoField(_ event: KeyEvent) {
        field.press(event.keyCode, flags: event.flags, in: maps[appLayout])
    }

    /// The effects of one output, as `InputEngine.execute` carries them out:
    /// a retype right after its layout selection waits for the main thread
    /// with it; a retype alone is posted at once.
    private mutating func run(_ effects: [Effect]) {
        var index = effects.startIndex
        while index < effects.endIndex {
            let effect = effects[index]
            switch effect {
            case let .selectLayout(id):
                var then: CheckedRetype?
                if index + 1 < effects.endIndex, case let .retype(retype) = effects[index + 1] {
                    then = checked(retype)
                    index += 1
                }
                mainQueue.append(.select(id, then: then))
            case let .retype(retype):
                post(checked(retype))
            case .releaseHeld:
                let events = held
                held.removeAll()
                for var heldEvent in events {
                    heldEvent.origin = .replayed
                    time += options.replayStep
                    key(heldEvent)
                }
            case let .scheduleDeadline(at):
                deadline = at
            case let .convertSelection(seq):
                mainQueue.append(.readSelection(seq))
            case .capsLockOff:
                capsLock = false
                log.append(Logged(event: cause, effect: effect))
            default:
                log.append(Logged(event: cause, effect: effect))
            }
            index += 1
        }
    }

    /// The retype with the verdict of its caret check, taken when the machine
    /// asks for it (`InputEngine.beginCheck`): the check runs beside the
    /// layout selection, not after it. A retype of a selection deletes
    /// nothing and has nothing to compare; a blind field cannot be read.
    private mutating func checked(_ retype: Retype) -> CheckedRetype {
        requests[retype.seq] = event
        let mismatch = fieldKind == .plain && retype.deleteCount > 0 && !retype.expected.isEmpty
            && !field.textBeforeCaret(endsWith: retype.expected)
        return CheckedRetype(retype: retype, mismatch: mismatch)
    }

    /// `InputEngine.postIfPending`: a retype whose fence is gone is not
    /// posted, and the machine hears `inputLost` (it believes the word was
    /// retyped); a failed caret check cancels it; else Backspaces, the
    /// text, `retypePosted` and the synthetic keys back through the tap.
    private mutating func post(_ item: CheckedRetype) {
        let retype = item.retype
        guard machine.pendingRetypeSeq == retype.seq else {
            send(.inputLost)
            return
        }
        let outer = posting
        posting = requests[retype.seq]
        defer { posting = outer }
        if item.mismatch {
            cancelled.append(Cancelled(event: cause, seq: retype.seq, origin: retype.origin))
            send(.retypeCancelled(seq: retype.seq))
            return
        }
        field.deleteLeft(retype.deleteCount)
        field.insert(retype.text)
        time += options.retypeStep
        send(.retypePosted(seq: retype.seq, time: time))
        let count = retype.deleteCount + retype.keys.count
        for index in 0..<count {
            time += options.ownKeyStep
            key(KeyEvent(.down, keyCode: 0, origin: .own(seq: retype.seq, last: index == count - 1)))
        }
    }

    /// The main thread and the app catch up, in order: a selection is read;
    /// a layout is selected, its retype posted, and the layout reaches the
    /// app (`Desk.settle`).
    public mutating func settle() {
        while !mainQueue.isEmpty {
            switch mainQueue.removeFirst() {
            case let .readSelection(seq):
                send(.selectionRead(seq: seq, text: field.selectedText))
            case let .select(id, then):
                appLayout = id
                if let then { post(then) }
                send(.layoutChanged(id))
            }
        }
        keyDownsWaiting = 0
    }

    /// Sends every deadline that has come by `time`, the earliest first.
    private mutating func deliverDeadlines(settling: Bool) {
        while let due = deadline, due <= time + options.epsilon {
            deadline = nil
            send(.deadline(time: due))
            if settling { settle() }
        }
    }
}
