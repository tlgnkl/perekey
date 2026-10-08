// SPDX-License-Identifier: GPL-3.0-or-later

/// Text to retype in place of what the user typed.
public struct Retype: Hashable, Sendable {
    /// One synthetic key: the original key code, so apps that read key codes
    /// (Java, VMs, remote desktops) get the right key, and the text it types
    /// in the target layout for everyone else.
    public struct Key: Hashable, Sendable {
        public var stroke: KeyStroke
        public var text: String
    }

    /// How many Backspaces to send first.
    public var deleteCount: Int
    public var keys: [Key]
    public var target: LayoutID
    /// The text expected before the caret. Where the accessibility API can
    /// read it, compare first and cancel the retype on mismatch
    /// (autocomplete, autocorrect, auto-closed brackets).
    public var expected: String
    /// Mark every posted event `.own(seq:)`, and the last one with `last: true`.
    public var seq: UInt32

    public var text: String { keys.map(\.text).joined() }
}

/// Why Perekey refused to act on a shortcut.
public enum Refusal: Hashable, Sendable {
    /// The word was typed with ⌥ or contains a dead key.
    case unconvertibleWord
    /// The current input source is not a known keyboard layout.
    case unsupportedLayout
    /// The word has keys the target layout does not type.
    case missingKeys
    /// A password field has focus.
    case secureField
}

/// What the input logic asks the system layer to do.
public enum Effect: Hashable, Sendable {
    /// Select this layout. Select, never toggle: toggling twice would undo it.
    case selectLayout(LayoutID)
    case retype(Retype)
    /// Nothing is buffered: convert the selected text, if any, into the other layout.
    case convertSelection
    /// Post again, marked `.replayed`, the user events held back so far, in order.
    case releaseHeld
    /// Send `.deadline` once this time has passed. A new deadline replaces the old one.
    case scheduleDeadline(at: Double)
    case autoswitchChanged(Bool)
    case refused(Refusal)
}

/// What to do with the event that was handled.
public enum Disposition: Hashable, Sendable {
    case pass
    /// Swallow it: it ran a shortcut.
    case drop
    /// Copy it, swallow it, and post the copy on `.releaseHeld`.
    /// Apply the disposition before the effects: a held event can be released
    /// by the same output.
    case hold
}

public struct Output: Hashable, Sendable {
    public var disposition: Disposition
    public var effects: [Effect]

    public init(_ disposition: Disposition = .pass, _ effects: [Effect] = []) {
        self.disposition = disposition
        self.effects = effects
    }
}
