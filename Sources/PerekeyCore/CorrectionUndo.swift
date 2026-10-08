// SPDX-License-Identifier: GPL-3.0-or-later

/// The last automatic correction, while it can still be taken back, and what
/// taking it back learns.
///
/// Backspace right after a correction puts the word back (`Effect.learned`
/// when the user wants Perekey to learn from that). The undo is a retype like
/// any other: it reports only once posted, and when the caret check cancels
/// it, the Backspace goes through as an ordinary one.
struct CorrectionUndo: Sendable {
    /// What it takes to undo an automatic correction.
    ///
    /// A switch at a word's end is closed at once. A switch inside the word
    /// stays open while the word goes on: the letters typed after it join
    /// it, and the key that ends the word closes it and reports it, so the
    /// hint and the undo cover the whole word ("ghbdtn" → "привет").
    struct Pending: Sendable {
        var correction: Correction
        /// The strokes to put back: the word, plus the key that ended it when
        /// that key typed a character (space, punctuation).
        var strokes: [KeyStroke]
        /// How many of `strokes` are the word itself.
        var wordLength: Int
        /// The word is still being typed.
        var isOpen: Bool
        /// Letters were typed after the switch: Backspace now fixes a typo,
        /// it does not undo, until the word ends.
        var extended = false
        /// `.corrected` went out, so an undo reports `.correctionUndone`.
        var reported = false
        /// False after a click on the hint's button: the hint's Undo still
        /// works, Backspace is an ordinary one.
        var backspaceUndoes = true
        /// A click outside the hint came while the retype was in flight: the
        /// caret may have moved, so the switch cannot be undone or extended.
        var clicked = false
        /// The strokes that stand for the word in the text now, when a word
        /// correction changed them (a typo fixed: "прривет" became "привет").
        /// Nil when they are the word's own strokes. The undo deletes these
        /// and types `strokes` back.
        var typed: [KeyStroke]?
        /// Turn Caps Lock off once posted (`CapsLockStep`).
        var capsLockOff = false
        /// The "Всегда исправлять" word that forced the switch over the
        /// classifier: undoing it withdraws the word instead of learning.
        var alwaysFix: String?
    }

    /// What an undo reports once its retype is posted. Nothing of it happens
    /// before: a cancelled undo leaves the text corrected and learns nothing.
    struct InFlight: Sendable {
        /// The `Correction.seq` being undone.
        var seq: UInt32
        /// `.corrected` went out, so the hint shows it.
        var reported: Bool
        /// Only the start of the word is known: learn it when it ends.
        var isOpen: Bool
        /// The word to learn, if `Settings.learnFromUndos`.
        var learn: String?
        /// The word to take off "Всегда исправлять" (`Pending.alwaysFix`).
        var withdraw: String?
        /// The Backspace that asked for the undo is the first held event.
        var heldKey: Bool
    }

    /// The retype that undoes a correction.
    struct Plan {
        var keys: [Retype.Key]
        var expected: String
        var deleteCount: Int
        /// The layout the word was typed in: the undo selects it again.
        var source: LayoutID
        var language: String?
        /// The keys the buffer holds after the undo, in `source`.
        var strokes: [KeyStroke]
        var inFlight: InFlight
    }

    /// What a key does to the last correction.
    enum KeyRole {
        /// Nothing: the correction can no longer be undone.
        case ends
        /// Backspace undoes it.
        case undoes
        /// The key continues a word switched inside it.
        case extends
    }

    /// The last automatic correction, while Backspace or the undo action can
    /// still take it back. Anything that may move the caret or change the
    /// text ends it: a key that does not continue the word, a click outside
    /// the hint's button, a shortcut, a focus change.
    private(set) var last: Pending?

    mutating func forget() {
        last = nil
    }

    /// The correction with this `seq` is the last one. A hint left over from
    /// an older correction must not undo a newer one.
    func isLast(seq: UInt32) -> Bool {
        last?.correction.seq == seq
    }

    /// A correction was posted: report it, unless its word is still open.
    mutating func posted(_ pending: Pending, effects: inout [Effect]) {
        var pending = pending
        if pending.capsLockOff { effects.append(.capsLockOff) }
        if pending.clicked { pending.correction.undoable = false }
        if !pending.isOpen {
            pending.reported = true
            effects.append(.corrected(pending.correction))
        }
        last = pending.clicked ? nil : pending
    }

    /// A click, on the hint's button or elsewhere.
    mutating func clicked(onHint: Bool) {
        if onHint, last?.isOpen == false {
            // The hint's button takes the click and the caret stays; the
            // Undo it sends comes next. Backspace is an ordinary one now.
            last?.backspaceUndoes = false
        } else {
            // The caret may be anywhere now: an undo would erase text there,
            // and the next letters are no part of the word.
            last = nil
        }
    }

    /// A key down by the user. Any key but Backspace ends the chance to
    /// undo, except the rest of a word switched inside it.
    mutating func keyDown(_ keyCode: UInt16, held: UInt8) -> KeyRole {
        guard let last else { return .ends }
        self.last = nil
        if keyCode == KeyCode.delete, held == 0, last.backspaceUndoes, !(last.isOpen && last.extended) {
            self.last = last
            return .undoes
        }
        if last.isOpen, keyCode != KeyCode.delete, !KeyCode.navigation.contains(keyCode),
           held & (ModifierKind.command.maskBit | ModifierKind.control.maskBit) == 0
        {
            self.last = last
            return .extends
        }
        return .ends
    }

    /// Takes the last correction back: the retype that puts the word in its
    /// layout, or nil when there is nothing to undo. Either way the
    /// correction can no longer be undone.
    mutating func takeBack(layouts: LayoutState, learnFromUndos: Bool, heldKey: Bool) -> Plan? {
        guard let last else { return nil }
        self.last = nil
        let correction = last.correction
        guard correction.undoable, let source = layouts[correction.source], let target = layouts[correction.target]
        else { return nil }

        var keys: [Retype.Key] = []
        var expected = ""
        keys.reserveCapacity(last.strokes.count)
        for stroke in last.strokes {
            guard let back = source.text(for: stroke) else { return nil }
            keys.append(Retype.Key(stroke: stroke, text: back))
        }
        // What stands in the text: the corrected word, then the held key.
        var deleteCount = last.strokes.count
        if let typed = last.typed {
            deleteCount = typed.count + last.strokes.count - last.wordLength
            for stroke in typed {
                guard let now = target.text(for: stroke) else { return nil }
                expected += now
            }
        }
        for stroke in last.strokes.dropFirst(last.typed == nil ? 0 : last.wordLength) {
            guard let now = target.text(for: stroke) else { return nil }
            expected += now
        }
        // Undoing a Caps Lock or double-capitals fix is a typing accident, not
        // a word preference: "привет" on the exception list would also stop
        // "ghbdtn" from ever switching. A typo undo learns the typed word only.
        // Abbreviations and «ё» are about the word itself, so they learn.
        let learn: String? = switch correction.kind {
        case _ where last.isOpen || !learnFromUndos || last.alwaysFix != nil: nil
        case .layout, .abbreviation, .yo: Self.learnable(correction.original, or: correction.replacement)
        case .typo: Self.learnable(correction.original, or: nil)
        case .capsLock, .doubleCapitals: nil
        }
        return Plan(keys: keys, expected: expected, deleteCount: deleteCount, source: source.id,
                    language: source.language, strokes: last.strokes,
                    inFlight: InFlight(seq: correction.seq, reported: last.reported, isOpen: last.isOpen,
                                       learn: learn, withdraw: last.alwaysFix, heldKey: heldKey))
    }

    /// A key typed while a switch inside the word is open, after it went into
    /// `buffer`: a letter joins the word, a key that ends the word closes the
    /// correction and reports it.
    mutating func extend(with key: KeyEvent, buffer: WordBuffer, layouts: LayoutState, effects: inout [Effect]) {
        guard var last, last.isOpen else { return }
        self.last = nil
        let stroke = KeyStroke(key.keyCode, LayoutModifiers(eventFlags: key.flags))
        if WordJudge.endsLine(key) {
            last.correction.undoable = false
        } else {
            // The key must have gone into the word, in the new layout.
            guard let entry = buffer.entries.last, entry.stroke == stroke, entry.layout == last.correction.target,
                  let source = layouts[last.correction.source], let target = layouts[last.correction.target]
            else { return }
            last.strokes.append(stroke)
            if !entry.isSpace, !WordJudge.endsWord(stroke, typed: target, other: source) {
                last.wordLength += 1
                last.extended = true
                Self.describe(&last, layouts: layouts)
                self.last = last
                return
            }
        }
        last.isOpen = false
        last.extended = false
        last.reported = true
        effects.append(.corrected(last.correction))
        self.last = last
    }

    /// Fills the correction's texts from its word strokes.
    static func describe(_ pending: inout Pending, layouts: LayoutState) {
        guard let source = layouts[pending.correction.source], let target = layouts[pending.correction.target]
        else { return }
        var original = ""
        var replacement = ""
        for stroke in pending.strokes.prefix(pending.wordLength) {
            original += source.text(for: stroke) ?? ""
            if pending.typed == nil { replacement += target.text(for: stroke) ?? "" }
        }
        for stroke in pending.typed ?? [] { replacement += target.text(for: stroke) ?? "" }
        pending.correction.original = original
        pending.correction.replacement = replacement
    }

    /// The word to put on the learned list: the typed reading if
    /// `WordRules` takes it ("ghbdtn"), else the same without the
    /// punctuation around it ("[jhjij" gives "jhjij"), else the other reading
    /// ("ds,jh" gives "выбор"). Either reading keeps the word: the check
    /// looks at both.
    static func learnable(_ typed: String?, or other: String?) -> String? {
        let list = WordRules()
        for candidate in [typed, typed.map(WordJudge.exceptionKey), other.map(WordJudge.exceptionKey)] {
            guard let candidate else { continue }
            switch list.validate(candidate) {
            case .ok, .frequent: return WordRules.normalize(candidate)
            default: continue
            }
        }
        return nil
    }
}
