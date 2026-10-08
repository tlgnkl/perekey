// SPDX-License-Identifier: GPL-3.0-or-later

/// Text to retype in place of what the user typed.
public struct Retype: Hashable, Sendable {
    /// One synthetic key: the original key code, so apps that read key codes
    /// (Java, VMs, remote desktops) get the right key, and the text it types
    /// in the target layout for everyone else.
    public struct Key: Hashable, Sendable {
        public var stroke: KeyStroke
        public var text: String

        public init(stroke: KeyStroke, text: String) {
            self.stroke = stroke
            self.text = text
        }
    }

    /// How many Backspaces to send first. Zero when the retype replaces a
    /// selection: typing replaces selected text by itself.
    public var deleteCount: Int
    public var keys: [Key]
    public var target: LayoutID
    /// The text expected before the caret: the word typed in the wrong layout.
    /// Before the Backspaces, where the accessibility API can read it, compare
    /// it with the text before the caret; on mismatch (autocomplete,
    /// autocorrect, auto-closed brackets) post nothing and send
    /// `.retypeCancelled(seq:)`. For a selection it is the selected text, and
    /// there is nothing to compare: no Backspaces are sent.
    public var expected: String
    /// Mark every posted event `.own(seq:)`, and the last one with `last: true`.
    /// Post only while `InputMachine.pendingRetypeSeq` is this `seq`, then
    /// send `.retypePosted`: a retype posted after the fence was released
    /// would erase what the user typed since.
    public var seq: UInt32
    /// Replace the selection through the accessibility API instead of typing
    /// (`kAXSelectedTextAttribute`). Only for apps where the user turned it on:
    /// in many apps it breaks ⌘Z and formatting. Posts no key events: send
    /// `.retypePosted` once the text is set, or `.retypeCancelled` if it was not.
    public var viaAccessibility: Bool

    public init(deleteCount: Int, keys: [Key], target: LayoutID, expected: String, seq: UInt32,
                viaAccessibility: Bool = false)
    {
        self.deleteCount = deleteCount
        self.keys = keys
        self.target = target
        self.expected = expected
        self.seq = seq
        self.viaAccessibility = viaAccessibility
    }

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
    /// Nothing was typed and nothing is selected.
    case nothingSelected
    /// The selection has line breaks or control characters (typing Return
    /// could send a message), is longer than `SelectionConversion.maxLength`,
    /// or no enabled layout types it differently.
    case unsupportedSelection
}

/// What the input logic asks the system layer to do.
public enum Effect: Hashable, Sendable {
    /// Select this layout. Select, never toggle: toggling twice would undo it.
    case selectLayout(LayoutID)
    /// Retype a word, or the selection after `.selectionRead`. Usually comes
    /// right after the `.selectLayout` of its target: select first, then post.
    case retype(Retype)
    /// Nothing is buffered: read the selected text, off the tap thread, and
    /// answer with `.selectionRead(seq:text:)`, an empty text if nothing is
    /// selected. The fence holds user input from now on, until the machine
    /// either refuses or emits a `.retype` with this `seq`; that retype is
    /// answered like a word's: `.retypePosted` or `.retypeCancelled`.
    /// Synthetic keys posted to read the selection (⌘C) must be marked
    /// `.own(seq:last: false)`, so the tap lets them through.
    case convertSelection(seq: UInt32)
    /// Post again, marked `.replayed`, the user events held back so far, in order.
    case releaseHeld
    /// Send `.deadline` once this time has passed. A new deadline replaces the old one.
    case scheduleDeadline(at: Double)
    case autoswitchChanged(Bool)
    /// Paste the pasteboard as plain text, on the main thread (`PlainPaste`).
    case pastePlain
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
