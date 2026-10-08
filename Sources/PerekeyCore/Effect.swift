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

/// A word automatic switching retyped in the other layout. The app shows it
/// at the caret (`Effect.corrected`) with an Undo button.
public struct Correction: Hashable, Sendable {
    /// The `Retype.seq` that carried it; `Effect.correctionUndone` names it.
    public var seq: UInt32
    /// What the user typed, in the layout they typed it in: "ghbdtn". Without
    /// the key that ended the word. After a switch inside the word
    /// (impossible prefix) it is the start of the word: "ghb".
    public var original: String
    /// What it became: "привет", or "при" inside the word.
    public var replacement: String
    /// The layout the word was typed in; undo selects it again.
    public var source: LayoutID
    public var target: LayoutID
    /// False when Return or Tab ended the word: the line is gone (a chat may
    /// have sent it), so Backspace and the undo action leave it alone.
    public var undoable: Bool
    /// What was corrected. A typo fixed together with the layout is `.typo`.
    public var kind: Kind

    /// The corrections of the word-boundary pipeline (docs/PLAN.md, «Этап 4»).
    public enum Kind: Hashable, Sendable {
        /// The word was typed in the wrong layout.
        case layout
        /// One key off: "прривет" → "привет" (`TypoCorrector`).
        case typo
        /// Typed with Caps Lock on by mistake: "ПРИВЕТ" → "Привет" (`CapsLockStep`).
        case capsLock
        /// Shift held a key too long: "ПРивет" → "Привет" (`DoubleCapitalsStep`).
        case doubleCapitals
        /// An abbreviation in its case: "мвд" → "МВД" (`AbbreviationStep`).
        case abbreviation
        /// "ё" where the word has it: "еще" → "ещё" (`YoStep`).
        case yo
    }

    public init(seq: UInt32, original: String, replacement: String, source: LayoutID, target: LayoutID,
                undoable: Bool = true, kind: Kind = .layout)
    {
        self.seq = seq
        self.original = original
        self.replacement = replacement
        self.source = source
        self.target = target
        self.undoable = undoable
        self.kind = kind
    }
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
    /// An automatic switch was posted: show the hint at the caret. Comes with
    /// the `.retypePosted` of its `seq`, so a cancelled switch never shows.
    case corrected(Correction)
    /// The correction with this `seq` was undone: Backspace right after it,
    /// `HotkeyAction.undoLastCorrection` or `InputEvent.undoLastCorrection`.
    /// Comes with the `.retypePosted` of the undo. Hide its hint.
    case correctionUndone(seq: UInt32)
    /// The undo of the correction with this `seq` was cancelled: the text
    /// before the caret was not the corrected word (`.retypeCancelled`). The
    /// text stays corrected and nothing is learned; a Backspace that asked
    /// for the undo is let through as an ordinary Backspace. The correction
    /// can no longer be undone: hide its hint.
    case correctionUndoFailed(seq: UInt32)
    /// The user undid an automatic switch and `Settings.learnFromUndos` is on
    /// (with the undo's `.retypePosted`, never for a cancelled undo):
    /// add the word to the learned exceptions (`WordExceptions.learn`). It is
    /// normalized, and it is the typed reading where the list takes it
    /// ("ghbdtn"), else the other one (`CorrectionUndo.learnable`). The next
    /// settings snapshot carries it in `Settings.exceptions`.
    case learned(String)
    /// A correction of a word typed with Caps Lock on by mistake was posted
    /// ("ПРИВЕТ" → "Привет"): turn Caps Lock off, on the main thread.
    case capsLockOff
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
