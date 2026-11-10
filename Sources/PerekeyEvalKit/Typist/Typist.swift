// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyCore
import PerekeyDesk

/// One event of the typist at its time, and the step it belongs to.
public struct TypedEvent: Hashable, Sendable {
    public var event: TypistEvent
    public var time: Double
    /// The index of the step in `EvalCase.allSteps`; nil for the pause at the end.
    public var step: Int?
    /// For a `type` step, the index of the character being typed.
    public var char: Int?
}

/// The model of a person at the keyboard: turns the steps of a case into key
/// events and their times (docs/eval.md, «Наборщик»). A pure function of
/// the case: the same case, the same events.
public struct Typist: Sendable {
    /// Every number is a model of a person, not a measurement.
    public struct Options: Hashable, Sendable {
        public struct Tempo: Hashable, Sendable {
            /// From the previous key up to the next key down, seconds.
            public var keyGap: Double
            /// From key down to key up, seconds.
            public var hold: Double
        }

        /// `calm` repeats `Desk.press` (Tests/PerekeyCoreTests/Desk.swift):
        /// 0.05 s, then 0.02 s.
        public var calm = Tempo(keyGap: 0.05, hold: 0.02)
        /// Fast typing: the desk falls behind when the case asks for `lag`.
        public var burst = Tempo(keyGap: 0.03, hold: 0.01)
        /// Shift goes down this long before its key, and up this long after it.
        public var shiftLead = 0.01
        /// The pause before a shortcut: `ChordDetector` takes no chord begun
        /// sooner than `minIdleAfterTyping` (0.15 s) after typing. `Desk.tap`.
        public var hotkeyPause = 0.3
        /// How long the modifiers of a shortcut are held: `Desk.tap`.
        public var hotkeyHold = 0.08
        /// Between the modifiers of one chord going down.
        public var chordStep = 0.01
        /// Between the two taps of a double tap: less than
        /// `ChordDetector.doubleTapInterval` (0.4 s).
        public var doubleTapGap = 0.1
        /// The pause after the last step: the fence's deadlines pass, the desk catches up.
        public var endPause = 2.0
        /// The time of the first event: as `Desk`.
        public var startTime = 100.0

        public init() {}

        func tempo(_ pace: Pace) -> Tempo {
            switch pace {
            case .calm: calm
            case .burst: burst
            }
        }
    }

    public let options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    /// The left key of each kind, and its key code (`kVK_*`).
    static func keyCode(_ key: ModifierKey) -> UInt16 {
        switch key {
        case .leftCommand: 55
        case .leftShift: 56
        case .leftOption: 58
        case .leftControl: 59
        case .rightShift: 60
        case .rightOption: 61
        case .rightControl: 62
        case .function: 63
        case .rightCommand: 54
        }
    }

    static func flag(_ key: ModifierKey) -> UInt64 { key.eventFlagMask | key.kind.independentFlag }

    /// The keys a person presses for a chord.
    static func keys(for chord: ModifierChord) -> [ModifierKey] {
        ModifierKind.allCases.flatMap { kind -> [ModifierKey] in
            switch chord.requirements[kind] {
            case nil: []
            case .either, .left: [kind.left]
            case .right: [kind.right]
            case .both: [kind.left, kind.right]
            }
        }
    }

    public func events(for item: EvalCase, layouts: LayoutLibrary) throws -> [TypedEvent] {
        let settings = try EvalSettings.settings(for: item.effectiveEnv)
        var clock = Clock(now: micro(options.startTime))
        var tempo = options.tempo(item.effectiveEnv.effectivePace)
        var result: [TypedEvent] = []
        /// Whether a key has been typed: the first event needs no gap before it.
        var started = false
        /// The character of a `type` step being typed.
        var char: Int?

        func emit(_ event: TypistEvent, at time: Int, step: Int?) {
            result.append(TypedEvent(event: event, time: Double(time) / 1_000_000, step: step, char: char))
        }
        /// The time of the next event: a key gap after the last one.
        func next() -> Int {
            if started { clock.now += micro(tempo.keyGap) }
            started = true
            return clock.now
        }
        func press(_ keyCode: UInt16, flags: UInt64, step: Int) {
            let down = next()
            emit(.keyDown(keyCode: keyCode, flags: flags), at: down, step: step)
            clock.now = down + micro(tempo.hold)
            emit(.keyUp(keyCode: keyCode, flags: flags), at: clock.now, step: step)
        }
        func modifiers(_ keys: [ModifierKey], down: Bool, flags: inout UInt64, step: Int) {
            for key in down ? keys : keys.reversed() {
                if down { flags |= Self.flag(key) } else { flags &= ~Self.flag(key) }
                // Keep the device-independent bit while the other key of the kind is held.
                var sent = flags
                for kind in ModifierKind.allCases where sent & (kind.left.eventFlagMask | kind.right.eventFlagMask) != 0 {
                    sent |= kind.independentFlag
                }
                emit(.flags(keyCode: Self.keyCode(key), flags: sent), at: clock.now, step: step)
                clock.now += micro(options.chordStep)
            }
            clock.now -= micro(options.chordStep)
        }

        for (index, step) in item.allSteps.enumerated() {
            switch step {
            case let .type(text, on):
                guard let map = layouts[on] else { throw EvalError.input("\(item.id): unknown layout \(on)") }
                var shiftHeld = false
                let shift = Self.flag(.leftShift)
                for (offset, character) in text.enumerated() {
                    char = offset
                    guard let stroke = LayoutLibrary.printableStroke(character, in: map) else {
                        throw EvalError.input("\(item.id): \(on) does not type \"\(character)\" without ⌥")
                    }
                    let needsShift = stroke.modifiers.contains(.shift)
                    if needsShift != shiftHeld {
                        if needsShift {
                            let down = next()
                            emit(.flags(keyCode: Self.keyCode(.leftShift), flags: shift), at: down, step: index)
                            clock.now = down + micro(options.shiftLead)
                            started = false
                        } else {
                            clock.now += micro(options.shiftLead)
                            emit(.flags(keyCode: Self.keyCode(.leftShift), flags: 0), at: clock.now, step: index)
                        }
                        shiftHeld = needsShift
                    }
                    press(stroke.keyCode, flags: needsShift ? shift : 0, step: index)
                }
                if shiftHeld {
                    clock.now += micro(options.shiftLead)
                    emit(.flags(keyCode: Self.keyCode(.leftShift), flags: 0), at: clock.now, step: index)
                }
                char = nil
            case let .layout(name):
                guard let map = layouts[name] else { throw EvalError.input("\(item.id): unknown layout \(name)") }
                emit(.userLayout(map.id), at: next(), step: index)
            case let .hotkey(name):
                guard let binding = settings.hotkeys.first(where: { $0.action == name.action }) else {
                    throw EvalError.input("\(item.id): \(name.rawValue) has no shortcut in the case's settings")
                }
                clock.now += micro(options.hotkeyPause)
                started = true
                var flags: UInt64 = 0
                switch binding.trigger {
                case let .modifiers(chord, taps):
                    let keys = Self.keys(for: chord)
                    for tap in 0..<taps.rawValue {
                        if tap > 0 { clock.now += micro(options.doubleTapGap) }
                        modifiers(keys, down: true, flags: &flags, step: index)
                        clock.now += micro(options.hotkeyHold)
                        modifiers(keys, down: false, flags: &flags, step: index)
                    }
                case let .key(keyCode, kinds):
                    let keys = ModifierKind.allCases.filter { kinds.contains($0) }.map(\.left)
                    modifiers(keys, down: true, flags: &flags, step: index)
                    clock.now += micro(options.chordStep)
                    emit(.keyDown(keyCode: keyCode, flags: flags), at: clock.now, step: index)
                    clock.now += micro(options.hotkeyHold)
                    emit(.keyUp(keyCode: keyCode, flags: flags), at: clock.now, step: index)
                    clock.now += micro(options.chordStep)
                    modifiers(keys, down: false, flags: &flags, step: index)
                }
            case let .key(name, n, mods):
                let keys = Step.ModName.allCases.filter { mods?.contains($0) ?? false }.map(\.key)
                var flags: UInt64 = 0
                if !keys.isEmpty {
                    clock.now = next()
                    started = false
                    modifiers(keys, down: true, flags: &flags, step: index)
                    clock.now += micro(options.shiftLead)
                }
                for _ in 0..<max(n ?? 1, 1) { press(name.keyCode, flags: flags, step: index) }
                if !keys.isEmpty {
                    clock.now += micro(options.shiftLead)
                    modifiers(keys, down: false, flags: &flags, step: index)
                }
            case let .click(target):
                emit(.click(target.desk), at: next(), step: index)
            case let .focus(spec):
                emit(.focus(spec.focus), at: next(), step: index)
            case let .mode(mode):
                emit(.mode(mode), at: next(), step: index)
            case let .capsLock(on):
                emit(.capsLock(on), at: next(), step: index)
            case let .select(count):
                emit(.select(chars: count), at: next(), step: index)
            case let .secureInput(on):
                emit(.secureInput(on), at: next(), step: index)
            case let .wait(seconds):
                emit(.idle(seconds: seconds), at: next(), step: index)
                clock.now += micro(seconds)
            case let .pace(pace):
                tempo = options.tempo(pace)
            case .undo:
                emit(.undoButton, at: next(), step: index)
            }
        }
        emit(.idle(seconds: options.endPause), at: next(), step: nil)
        return result
    }

    /// Microseconds: times add up exactly.
    private func micro(_ seconds: Double) -> Int { Int((seconds * 1_000_000).rounded()) }

    private struct Clock {
        var now: Int
    }
}

extension ModifierKind {
    var left: ModifierKey {
        switch self {
        case .shift: .leftShift
        case .control: .leftControl
        case .option: .leftOption
        case .command: .leftCommand
        case .function: .function
        }
    }

    var right: ModifierKey {
        switch self {
        case .shift: .rightShift
        case .control: .rightControl
        case .option: .rightOption
        case .command: .rightCommand
        case .function: .function
        }
    }

    /// The device-independent `CGEventFlags` bit of the kind.
    var independentFlag: UInt64 {
        switch self {
        case .shift: EventFlags.shift
        case .control: EventFlags.control
        case .option: EventFlags.option
        case .command: EventFlags.command
        case .function: EventFlags.function
        }
    }
}

extension Step.ModName {
    var key: ModifierKey {
        switch self {
        case .shift: .leftShift
        case .option: .leftOption
        case .command: .leftCommand
        case .control: .leftControl
        }
    }
}

extension Step.ClickSpec {
    var desk: ClickTarget {
        switch self {
        case .start: .start
        case .end: .end
        case .hint: .hint
        case let .position(position): .position(position)
        }
    }
}
