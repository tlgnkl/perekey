// SPDX-License-Identifier: GPL-3.0-or-later

/// Turns a stream of modifier-state changes into shortcut actions.
///
/// A chord fires on release, and only when:
/// - no other input happened while modifiers were held
///   (so ⌘⇧4 never counts as ⌘⇧, and ⌘-scroll never counts as ⌘);
/// - the press started at least `minIdleAfterTyping` after the last other input
///   (a Shift tapped mid-word while typing fast is not a shortcut);
/// - the press was shorter than `maxHoldDuration`.
///
/// A double-tap binding fires when the same chord is tapped twice within
/// `doubleTapInterval`. A single-tap binding of the same chord fires on the
/// first tap without waiting, so actions bound to a double tap must not depend
/// on the single-tap action being undone.
public struct ChordDetector<Action: Hashable & Sendable>: Sendable {
    public struct Binding: Hashable, Sendable {
        public var chord: ModifierChord
        public var taps: Int
        public var action: Action

        public init(_ chord: ModifierChord, taps: Int = 1, action: Action) {
            self.chord = chord
            self.taps = taps
            self.action = action
        }
    }

    public var bindings: [Binding]
    public var maxHoldDuration: Double
    public var doubleTapInterval: Double
    public var minIdleAfterTyping: Double

    private var sessionStart: Double?
    private var peak: Set<ModifierKey> = []
    private var interrupted = false
    private var lastTap: (keys: Set<ModifierKey>, time: Double)?
    private var lastOtherInput = -Double.infinity

    public init(
        bindings: [Binding],
        maxHoldDuration: Double = 0.5,
        doubleTapInterval: Double = 0.4,
        minIdleAfterTyping: Double = 0.15
    ) {
        self.bindings = bindings
        self.maxHoldDuration = maxHoldDuration
        self.doubleTapInterval = doubleTapInterval
        self.minIdleAfterTyping = minIdleAfterTyping
    }

    /// Call on every modifier change with the full set of modifiers held now.
    /// Build the set from the event flags with `ModifierKey.pressed(inEventFlags:)`.
    public mutating func modifiersChanged(to pressed: Set<ModifierKey>, at time: Double) -> Action? {
        guard let start = sessionStart else {
            if !pressed.isEmpty {
                sessionStart = time
                peak = pressed
                interrupted = time - lastOtherInput < minIdleAfterTyping
            }
            return nil
        }
        peak.formUnion(pressed)
        guard pressed.isEmpty else { return nil }

        let tapped = peak
        sessionStart = nil
        peak = []
        guard !interrupted, time - start <= maxHoldDuration else {
            lastTap = nil
            return nil
        }

        if let last = lastTap, last.keys == tapped, time - last.time <= doubleTapInterval {
            if let action = action(for: tapped, taps: 2) {
                lastTap = nil
                return action
            }
        }
        lastTap = (tapped, time)
        return action(for: tapped, taps: 1)
    }

    /// Call on any other input: a key press or release that is not a modifier
    /// (Caps Lock included), a mouse click, a scroll, or a trackpad gesture.
    /// Never call it for Perekey's own synthetic events.
    public mutating func otherInput(at time: Double) {
        if sessionStart != nil { interrupted = true }
        lastTap = nil
        lastOtherInput = time
    }

    /// Forget the current press and the last tap.
    ///
    /// Call when events may have been lost: the event tap was disabled by the
    /// system, or Secure Input started. While Secure Input is on, key presses do
    /// not reach the tap but modifier changes do, so every capital letter of a
    /// password would look like a clean Shift tap; keep the detector reset and
    /// unused until Secure Input ends.
    public mutating func reset() {
        sessionStart = nil
        peak = []
        interrupted = false
        lastTap = nil
    }

    private func action(for keys: Set<ModifierKey>, taps: Int) -> Action? {
        bindings.first { $0.taps == taps && $0.chord.matches(keys) }?.action
    }
}
