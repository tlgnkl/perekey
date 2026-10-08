// SPDX-License-Identifier: GPL-3.0-or-later

/// Turns what the user presses in the shortcut recorder into a `Trigger`.
///
/// - Modifiers alone are recorded on release. A second tap of the same
///   modifiers within `doubleTapInterval` records a double tap, so a single
///   tap is final only once the interval has passed: the caller schedules
///   `deadline` and calls `deadlinePassed(at:)`.
/// - A key with modifiers is recorded on key down. A key without modifiers is
///   recorded only if it does not type text (F13–F19 and the like).
/// - Esc cancels, Delete clears the shortcut.
public struct ShortcutRecorder: Sendable {
    public enum Result: Hashable, Sendable {
        case recorded(Trigger)
        case cancelled
        case cleared
        /// A plain key that types text would stop typing it. Keep recording.
        case needsModifier
    }

    public var doubleTapInterval: Double
    /// When to call `deadlinePassed(at:)`, if a single tap is waiting.
    public private(set) var deadline: Double?
    /// The modifiers held right now, to show while recording.
    public private(set) var held: Set<ModifierKey> = []

    private let sidedKinds: Set<ModifierKind>
    private var peak: Set<ModifierKey> = []
    private var interrupted = false
    private var lastTap: Set<ModifierKey>?

    /// - Parameter otherBindings: the shortcuts of the other actions. When one
    ///   of them needs a specific side of a modifier (right ⌘ for English),
    ///   the recorder keeps the side of that kind too. Otherwise one key of a
    ///   kind records "either side": the user may press left or right Shift.
    public init(otherBindings: [HotkeyBinding] = [], doubleTapInterval: Double = 0.4) {
        self.doubleTapInterval = doubleTapInterval
        var sided: Set<ModifierKind> = []
        for binding in otherBindings {
            guard case let .modifiers(chord, _) = binding.trigger else { continue }
            for (kind, side) in chord.requirements where side == .left || side == .right {
                sided.insert(kind)
            }
        }
        sidedKinds = sided
    }

    public mutating func modifiersChanged(to pressed: Set<ModifierKey>, at time: Double) -> Result? {
        held = pressed
        if !pressed.isEmpty {
            if peak.isEmpty { interrupted = false }
            peak.formUnion(pressed)
            return nil
        }
        let tapped = peak
        peak = []
        guard !tapped.isEmpty, !interrupted else { return nil }

        if lastTap == tapped {
            finish()
            return .recorded(.modifiers(chord(of: tapped), taps: .double))
        }
        lastTap = tapped
        deadline = time + doubleTapInterval
        return nil
    }

    public mutating func keyDown(keyCode: UInt16, flags: UInt64, at time: Double) -> Result? {
        let kinds = ModifierKind.held(inEventFlags: flags).subtracting([.function])
        if peak.isEmpty == false { interrupted = true }
        if kinds.isEmpty {
            switch keyCode {
            case KeyCode.escape:
                finish()
                return .cancelled
            case KeyCode.delete, KeyCode.forwardDelete:
                finish()
                return .cleared
            case _ where !KeyCode.nonTyping.contains(keyCode):
                return .needsModifier
            default:
                break
            }
        }
        finish()
        return .recorded(.key(keyCode: keyCode, modifiers: kinds))
    }

    public mutating func deadlinePassed(at time: Double) -> Result? {
        guard let deadline, time >= deadline, let tapped = lastTap else { return nil }
        finish()
        return .recorded(.modifiers(chord(of: tapped), taps: .single))
    }

    private mutating func finish() {
        deadline = nil
        lastTap = nil
        peak = []
        interrupted = false
    }

    private func chord(of keys: Set<ModifierKey>) -> ModifierChord {
        var requirements: [ModifierKind: SideRequirement] = [:]
        for kind in ModifierKind.allCases {
            let ofKind = keys.filter { $0.kind == kind }
            switch ofKind.count {
            case 0: continue
            case 2: requirements[kind] = .both
            default:
                let key = ofKind.first!
                requirements[kind] = !sidedKinds.contains(kind) || kind == .function ? .either
                    : key.isRight ? .right : .left
            }
        }
        return ModifierChord(requirements)
    }
}

public extension KeyCode {
    /// Keys that type no text, so they can be a shortcut on their own:
    /// F1–F20 (F18 is Caps Lock remapped by `hidutil`), Help, keypad Clear.
    static let nonTyping: Set<UInt16> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, // F1–F12
        105, 107, 113, 106, 64, 79, 80, 90, // F13–F20
        114, 71, // Help, Clear
    ]

    static let f18: UInt16 = 79
}
