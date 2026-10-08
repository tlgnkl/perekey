// SPDX-License-Identifier: GPL-3.0-or-later

/// Who produced a keyboard event.
public enum EventOrigin: Hashable, Sendable {
    case user
    /// Posted by Perekey as part of a retype.
    case own(seq: UInt32, last: Bool)
    /// User input held back during a retype and posted again.
    case replayed

    public init(mark: SyntheticMark?) {
        switch mark {
        case nil: self = .user
        case let .own(seq, last): self = .own(seq: seq, last: last)
        case .replayed: self = .replayed
        }
    }
}

/// A key press or release.
public struct KeyEvent: Hashable, Sendable {
    public enum Phase: Hashable, Sendable { case down, up }

    public var phase: Phase
    public var keyCode: UInt16
    /// Raw `CGEventFlags`.
    public var flags: UInt64
    public var isRepeat: Bool
    public var origin: EventOrigin

    public init(_ phase: Phase, keyCode: UInt16, flags: UInt64 = 0, isRepeat: Bool = false,
                origin: EventOrigin = .user)
    {
        self.phase = phase
        self.keyCode = keyCode
        self.flags = flags
        self.isRepeat = isRepeat
        self.origin = origin
    }
}

/// What the focused element is, as far as the accessibility API can tell.
public struct Focus: Hashable, Sendable {
    public var bundleID: String?
    /// A password field (`AXSecureTextField`). Perekey never retypes into it.
    public var isSecureField: Bool

    public init(bundleID: String?, isSecureField: Bool = false) {
        self.bundleID = bundleID
        self.isSecureField = isSecureField
    }
}

/// Everything the input logic reacts to. Times are seconds of
/// `CLOCK_UPTIME_RAW`, taken when the event reached the tap.
public enum InputEvent: Hashable, Sendable {
    case key(KeyEvent, time: Double)
    /// A modifier changed. Carries the raw flags and the key that changed.
    case flagsChanged(keyCode: UInt16, flags: UInt64, origin: EventOrigin, time: Double)
    /// A mouse click. Moves the caret, so the remembered word is gone.
    case click(time: Double)
    /// A scroll or trackpad gesture. Breaks a chord but keeps the word.
    case scroll(time: Double)
    case focusChanged(Focus)
    /// The system switched the layout, by Perekey or by someone else.
    /// An ID that is not among the known layouts is an input method or a
    /// broken layout: Perekey does not retype then.
    case layoutChanged(LayoutID)
    /// The set of enabled layouts changed, with tables built on the main thread.
    case layoutsChanged([LayoutMap])
    case secureInputChanged(Bool)
    case settingsChanged(Settings)
    /// Events may have been lost: the tap was disabled, the Mac woke up, or the
    /// user session changed.
    case inputLost
    /// A deadline requested with `Effect.scheduleDeadline` has passed.
    case deadline(time: Double)
}
