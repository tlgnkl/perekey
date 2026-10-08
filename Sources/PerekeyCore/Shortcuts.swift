// SPDX-License-Identifier: GPL-3.0-or-later

/// The user's shortcuts: modifier-only chords (`ChordDetector`) and key
/// triggers, and the key ups of keys that ran one.
struct Shortcuts: Sendable {
    /// What a key down is to the shortcuts.
    enum KeyDown {
        /// It is a key trigger: run the action, swallow the key.
        case runs(HotkeyAction)
        /// Swallow it: the repeat of a key that ran a shortcut or was dropped.
        case swallowed
        /// Not a shortcut: typing.
        case typing
    }

    private var detector = ChordDetector<HotkeyAction>(bindings: [])
    /// Key triggers, with modifiers as a `kindMask` so matching does not allocate.
    private var keyHotkeys: [(keyCode: UInt16, modifiers: UInt8, action: HotkeyAction)] = []
    /// Key ups of keys that ran a shortcut on key down: swallow them too.
    private var swallowedKeyUps: Set<UInt16> = []

    init(_ hotkeys: [HotkeyBinding]) {
        apply(hotkeys)
    }

    mutating func apply(_ hotkeys: [HotkeyBinding]) {
        var chords: [ChordDetector<HotkeyAction>.Binding] = []
        keyHotkeys = []
        for hotkey in hotkeys {
            switch hotkey.trigger {
            case let .modifiers(chord, taps):
                guard hotkey.action.acceptsModifierOnlyTrigger else { continue }
                chords.append(.init(chord, taps: taps.rawValue, action: hotkey.action))
            case let .key(keyCode, modifiers):
                let mask = modifiers.reduce(UInt8(0)) { $0 | $1.maskBit } & ~ModifierKind.function.maskBit
                keyHotkeys.append((keyCode, mask, hotkey.action))
            }
        }
        detector = ChordDetector(bindings: chords)
    }

    /// A modifier changed: the chord it completes, if any. Caps Lock is no
    /// modifier here, only input between taps.
    mutating func modifiersChanged(keyCode: UInt16, flags: UInt64, at time: Double) -> HotkeyAction? {
        if keyCode == KeyCode.capsLock {
            detector.otherInput(at: time)
            return nil
        }
        return detector.modifiersChanged(to: Self.modifiers(keyCode: keyCode, flags: flags), at: time)
    }

    /// Input that breaks a chord: a click, a scroll.
    mutating func otherInput(at time: Double) {
        detector.otherInput(at: time)
    }

    /// A key down by the user with these modifiers `held` (a `kindMask`).
    mutating func keyDown(_ key: KeyEvent, held: UInt8, at time: Double) -> KeyDown {
        detector.otherInput(at: time)
        if let hotkey = keyHotkeys.first(where: { $0.keyCode == key.keyCode && $0.modifiers == held }) {
            swallowedKeyUps.insert(key.keyCode)
            return key.isRepeat ? .swallowed : .runs(hotkey.action)
        }
        // Auto-repeat of a key whose press was swallowed (the undoing Backspace).
        return key.isRepeat && swallowedKeyUps.contains(key.keyCode) ? .swallowed : .typing
    }

    /// A key up. True when its key down was swallowed: swallow it too.
    mutating func keyUp(_ keyCode: UInt16) -> Bool {
        detector.keyReleased()
        return swallowedKeyUps.remove(keyCode) != nil
    }

    /// A key down was dropped outside the shortcuts: swallow its key up too.
    mutating func swallow(_ keyCode: UInt16) {
        swallowedKeyUps.insert(keyCode)
    }

    /// Keys pressed so far are unknown: Secure Input, lost input.
    mutating func reset() {
        detector.reset()
        swallowedKeyUps.removeAll()
    }

    /// The modifiers held after a `flagsChanged` event.
    ///
    /// Reads the device-dependent side bits. Some virtual keyboards and
    /// synthetic events set only the device-independent bits; then the key that
    /// changed gives its side, and other held kinds count as their left key.
    static func modifiers(keyCode: UInt16, flags: UInt64) -> Set<ModifierKey> {
        let pressed = ModifierKey.pressed(inEventFlags: flags)
        guard pressed.isEmpty else { return pressed }
        let changed = ModifierKey(keyCode: keyCode)
        return Set(ModifierKind.held(inEventFlags: flags).map { kind in
            if let changed, changed.kind == kind { return changed }
            return ModifierKey.allCases.first { $0.kind == kind && !$0.isRight }!
        })
    }
}
