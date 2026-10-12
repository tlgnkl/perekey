// SPDX-License-Identifier: GPL-3.0-or-later

/// A key with modifiers held as a trigger (`VoiceTrigger.hold`, ⌥Space).
///
/// The hold begins on the key down with exactly these modifiers and ends on
/// the first of: the key up, the release of one of the modifiers (a
/// `flagsChanged` arrives even under Secure Input, a key up does not), or
/// `lost()`. It outlives `Shortcuts.reset()`: losing the end of a hold would
/// leave the microphone on, so a hold ends only on evidence that the keys are up.
///
/// The key's own events are swallowed while it is down: its repeats, and its
/// key up even after the modifiers were released.
struct HoldTrigger: Sendable {
    /// What a key down is to the hold trigger.
    enum KeyDown {
        case began
        /// The key is already down as the trigger: a repeat, or a press whose
        /// key up was lost.
        case swallowed
        case other
    }

    /// The trigger key; nil when there is no hold trigger.
    private var keyCode: UInt16?
    /// The trigger's modifiers as a `kindMask`.
    private var modifiers: UInt8 = 0
    /// Between `holdBegan` and `holdEnded`.
    private(set) var isHolding = false
    /// The trigger key went down as the trigger and its key up has not come.
    private var keyIsDown = false

    init(_ trigger: VoiceTrigger? = nil) {
        _ = configure(trigger)
    }

    /// Sets the trigger. A hold under way of another trigger is over: its
    /// key up would no longer be recognized.
    mutating func configure(_ trigger: VoiceTrigger?) -> VoiceSignal? {
        var newKeyCode: UInt16?
        var newModifiers: UInt8 = 0
        if case let .hold(keyCode, modifiers) = trigger {
            newKeyCode = keyCode
            newModifiers = modifiers.reduce(UInt8(0)) { $0 | $1.maskBit } & ~ModifierKind.function.maskBit
        }
        guard newKeyCode != keyCode || newModifiers != modifiers else { return nil }
        keyCode = newKeyCode
        modifiers = newModifiers
        keyIsDown = false
        return endHold(.lost)
    }

    /// A key down by the user with these modifiers `held` (a `kindMask`
    /// without fn).
    mutating func keyDown(keyCode: UInt16, isRepeat: Bool, held: UInt8) -> KeyDown {
        guard keyCode == self.keyCode else { return .other }
        if keyIsDown, isRepeat || isHolding { return .swallowed }
        guard !isRepeat, held == modifiers else {
            keyIsDown = false
            return .other
        }
        keyIsDown = true
        isHolding = true
        return .began
    }

    /// A key up: whether it is the trigger key's, to swallow, and the end of
    /// the hold if it was still on.
    mutating func keyUp(keyCode: UInt16) -> (swallow: Bool, signal: VoiceSignal?) {
        guard keyIsDown, keyCode == self.keyCode else { return (false, nil) }
        keyIsDown = false
        return (true, endHold(.released))
    }

    /// The modifiers held now changed (a `kindMask`, fn ignored).
    mutating func modifiersChanged(held: UInt8) -> VoiceSignal? {
        guard isHolding, held & modifiers != modifiers else { return nil }
        return endHold(.released)
    }

    /// The system layer found the trigger's keys up while the hold went on.
    mutating func lost() -> VoiceSignal? {
        keyIsDown = false
        return endHold(.lost)
    }

    private mutating func endHold(_ reason: HoldEndReason) -> VoiceSignal? {
        guard isHolding else { return nil }
        isHolding = false
        return .holdEnded(reason: reason)
    }
}
