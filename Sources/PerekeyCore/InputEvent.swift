// SPDX-License-Identifier: GPL-3.0-or-later

/// Who produced a keyboard event.
public enum EventOrigin: Hashable, Sendable {
    case user
    /// Posted by Perekey as part of a retype.
    case own(seq: UInt32, last: Bool)
    /// User input held back during a retype and posted again.
    case replayed

    public var isOwn: Bool {
        if case .own = self { true } else { false }
    }

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
    /// False when the focused element is not known: right after an app switch,
    /// before accessibility reports it, and whenever accessibility is
    /// unavailable (no permission, the app does not answer). `isSecureField` is
    /// then false only for lack of knowledge. Automatic switching must not act
    /// on an unknown focus. A manual shortcut still may: the user asked for it,
    /// and a password field normally turns Secure Input on anyway.
    public var isKnown: Bool

    public init(bundleID: String?, isSecureField: Bool = false, isKnown: Bool = true) {
        self.bundleID = bundleID
        self.isSecureField = isSecureField
        self.isKnown = isKnown
    }

    /// The app is known, its focused element is not.
    public static func unknown(bundleID: String?) -> Focus {
        Focus(bundleID: bundleID, isKnown: false)
    }
}

/// Everything the input logic reacts to. Times are seconds of
/// `CLOCK_UPTIME_RAW`, taken when the event reached the tap.
///
/// Not `Hashable`: `.classifierChanged` carries a memory-mapped model.
public enum InputEvent: Sendable {
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
    /// The system layer posted the retype with this `seq`. The fence
    /// timeout starts now.
    case retypePosted(seq: UInt32, time: Double)
    /// The system layer did not carry out the retype with this `seq`: the text
    /// before the caret differed from `Retype.expected`, or the layout could
    /// not be selected.
    case retypeCancelled(seq: UInt32)
    /// The answer to `Effect.convertSelection`: the selected text, empty if
    /// nothing is selected. `viaAccessibility` asks to replace it through the
    /// accessibility API (`Retype.viaAccessibility`); the system layer sets it
    /// only for apps where the user turned that on and AX read the text.
    case selectionRead(seq: UInt32, text: String, viaAccessibility: Bool = false)
    /// Events may have been lost: the tap was disabled, the Mac woke up, or the
    /// user session changed.
    case inputLost
    /// A deadline requested with `Effect.scheduleDeadline` has passed.
    case deadline(time: Double)
    /// The mode of the frontmost app. Only `.auto` switches by itself; the
    /// app removes the shortcuts for `.off`.
    case appModeChanged(AppMode)
    /// The language model was loaded, replaced or dropped. Without a
    /// classifier there is no automatic switching.
    case classifierChanged(Classifier?)
    /// Undo the last automatic switch, as the hint's Undo button asks. Works
    /// while the switch is the last thing typed; a click (on the hint) does not
    /// count as typing. The pre-Backspace check guards a caret that moved.
    case undoLastCorrection(time: Double)
}
