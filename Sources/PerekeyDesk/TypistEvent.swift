// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyCore

/// Where a click lands.
public enum ClickTarget: Hashable, Sendable {
    case start
    case end
    /// The caret goes after this many characters.
    case position(Int)
    /// The hint's button: it takes the click without moving the caret.
    case hint
}

/// One low-level event from the typist, the model of a person at the
/// keyboard (docs/eval.md, «Наборщик и стенд»). Every system under test gets
/// the same events.
public enum TypistEvent: Hashable, Sendable {
    case keyDown(keyCode: UInt16, flags: UInt64)
    case keyUp(keyCode: UInt16, flags: UInt64)
    /// A modifier went down or up: `flags` are the flags after the change.
    case flags(keyCode: UInt16, flags: UInt64)
    /// The person chose a layout in the system by themselves.
    case userLayout(LayoutID)
    case click(ClickTarget)
    case focus(Focus)
    case mode(AppMode)
    case secureInput(Bool)
    /// Caps Lock on or off. The system under test keeps the state and adds
    /// its flag to the keys.
    case capsLock(Bool)
    /// ⇧← this many times.
    case select(chars: Int)
    /// The Undo button of the hint of the last correction.
    case undoButton
    /// Time passes and nothing is pressed.
    case idle(seconds: Double)

    public var isKeyDown: Bool {
        if case .keyDown = self { true } else { false }
    }
}
