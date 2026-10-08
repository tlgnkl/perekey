// SPDX-License-Identifier: GPL-3.0-or-later

/// Turns a stream of modifier-state changes into shortcut actions.
///
/// A chord fires on release, and only when:
/// - no other key or mouse button was used while modifiers were held
///   (so ⌘⇧4 never counts as ⌘⇧);
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

    private var sessionStart: Double?
    private var peak: Set<ModifierKey> = []
    private var interrupted = false
    private var lastTap: (keys: Set<ModifierKey>, time: Double)?

    public init(bindings: [Binding], maxHoldDuration: Double = 0.8, doubleTapInterval: Double = 0.4) {
        self.bindings = bindings
        self.maxHoldDuration = maxHoldDuration
        self.doubleTapInterval = doubleTapInterval
    }

    /// Call on every modifier change with the full set of modifiers held now.
    public mutating func modifiersChanged(to pressed: Set<ModifierKey>, at time: Double) -> Action? {
        guard let start = sessionStart else {
            if !pressed.isEmpty {
                sessionStart = time
                peak = pressed
                interrupted = false
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

    /// Call on any non-modifier key press or mouse click.
    public mutating func otherInput() {
        if sessionStart != nil { interrupted = true }
        lastTap = nil
    }

    private func action(for keys: Set<ModifierKey>, taps: Int) -> Action? {
        bindings.first { $0.taps == taps && $0.chord.matches(keys) }?.action
    }
}
