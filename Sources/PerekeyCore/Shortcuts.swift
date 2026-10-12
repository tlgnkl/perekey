// SPDX-License-Identifier: GPL-3.0-or-later

/// The user's shortcuts: modifier-only chords (`ChordDetector`) and key
/// triggers, and the key ups of keys that ran one. Also the voice trigger:
/// a tap chord among the others, or a held key (`HoldTrigger`).
struct Shortcuts: Sendable {
    /// What a key down is to the shortcuts.
    enum KeyDown {
        /// It is a key trigger: run the action, swallow the key.
        case runs(HotkeyAction)
        /// The voice hold trigger went down: swallow the key.
        case voice(VoiceSignal)
        /// Swallow it: the repeat of a key that ran a shortcut or was dropped.
        case swallowed
        /// Not a shortcut: typing.
        case typing
    }

    /// What a modifier change fires.
    enum Fired: Hashable {
        case hotkey(HotkeyAction)
        case voice(VoiceSignal)
    }

    /// What a chord runs: one of the user's actions or the voice tap.
    private enum ChordAction: Hashable, Sendable {
        case hotkey(HotkeyAction)
        case voiceTap
    }

    private var detector = ChordDetector<ChordAction>(bindings: [])
    /// Key triggers, with modifiers as a `kindMask` so matching does not allocate.
    private var keyHotkeys: [(keyCode: UInt16, modifiers: UInt8, action: HotkeyAction)] = []
    /// Key ups of keys that ran a shortcut on key down: swallow them too.
    private var swallowedKeyUps: Set<UInt16> = []
    /// The voice hold trigger. Not cleared by `reset()`.
    private var hold = HoldTrigger()
    /// Whether any modifier is held, and where the pointer was when the first
    /// one went down: a voice tap must not move it.
    private var modifiersDown = false
    private var pressLocation: PointerLocation?

    init(_ hotkeys: [HotkeyBinding], voice: VoiceTrigger? = nil) {
        _ = apply(hotkeys, voice: voice)
    }

    /// Sets the shortcuts. The end of a hold the new voice trigger no longer
    /// recognizes, if one was under way.
    mutating func apply(_ hotkeys: [HotkeyBinding], voice: VoiceTrigger? = nil) -> VoiceSignal? {
        var chords: [ChordDetector<ChordAction>.Binding] = []
        keyHotkeys = []
        for hotkey in hotkeys {
            switch hotkey.trigger {
            case let .modifiers(chord, taps):
                guard hotkey.action.acceptsModifierOnlyTrigger else { continue }
                chords.append(.init(chord, taps: taps.rawValue, action: .hotkey(hotkey.action)))
            case let .key(keyCode, modifiers):
                let mask = modifiers.reduce(UInt8(0)) { $0 | $1.maskBit } & ~ModifierKind.function.maskBit
                keyHotkeys.append((keyCode, mask, hotkey.action))
            }
        }
        // After the user's chords: where both match, theirs wins
        // (`ShortcutConflicts.check(voice:among:)` warns about it).
        if case let .tap(chord) = voice { chords.append(.init(chord, action: .voiceTap)) }
        detector = ChordDetector(bindings: chords)
        return hold.configure(voice)
    }

    /// A modifier changed: the chord it completes, if any. Caps Lock is no
    /// modifier here, only input between taps.
    mutating func modifiersChanged(keyCode: UInt16, flags: UInt64, location: PointerLocation? = nil,
                                   at time: Double) -> Fired?
    {
        if keyCode == KeyCode.capsLock {
            detector.otherInput(at: time)
            return nil
        }
        let pressed = Self.modifiers(keyCode: keyCode, flags: flags)
        if !modifiersDown { pressLocation = location }
        modifiersDown = !pressed.isEmpty
        switch detector.modifiersChanged(to: pressed, at: time) {
        case nil:
            return nil
        case let .hotkey(action):
            return .hotkey(action)
        case .voiceTap:
            // ⌥ held while hovering (Figma, an open menu) is a gesture.
            if let pressLocation, let location, pressLocation != location { return nil }
            return .voice(.toggle)
        }
    }

    /// A modifier changed, Secure Input or not: the end of the voice hold if
    /// one of its modifiers came up.
    mutating func holdModifiersChanged(flags: UInt64) -> VoiceSignal? {
        hold.modifiersChanged(held: ModifierKind.kindMask(inEventFlags: flags) & ~ModifierKind.function.maskBit)
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
        switch hold.keyDown(keyCode: key.keyCode, isRepeat: key.isRepeat, held: held) {
        case .began: return .voice(.holdBegan)
        case .swallowed: return .swallowed
        case .other: break
        }
        // Auto-repeat of a key whose press was swallowed (the undoing Backspace).
        return key.isRepeat && swallowedKeyUps.contains(key.keyCode) ? .swallowed : .typing
    }

    /// A key up. True when its key down was swallowed: swallow it too.
    mutating func keyUp(_ keyCode: UInt16) -> Bool {
        detector.keyReleased()
        return swallowedKeyUps.remove(keyCode) != nil
    }

    /// A key up, Secure Input or not: whether it is the voice hold key's, to
    /// swallow, and the end of the hold if it was still on.
    mutating func holdKeyUp(_ keyCode: UInt16) -> (swallow: Bool, signal: VoiceSignal?) {
        hold.keyUp(keyCode: keyCode)
    }

    /// The system layer found the voice hold keys up: the end of the hold.
    mutating func holdLost() -> VoiceSignal? {
        hold.lost()
    }

    /// A key down was dropped outside the shortcuts: swallow its key up too.
    mutating func swallow(_ keyCode: UInt16) {
        swallowedKeyUps.insert(keyCode)
    }

    /// Keys pressed so far are unknown: Secure Input, lost input. The voice
    /// hold stays: it ends on its key up, a modifier up or `holdLost()`.
    mutating func reset() {
        detector.reset()
        swallowedKeyUps.removeAll()
        modifiersDown = false
        pressLocation = nil
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
