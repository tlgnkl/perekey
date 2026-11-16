// SPDX-License-Identifier: GPL-3.0-or-later

/// What a retype's Backspaces did to the field, checked before the new word is
/// typed.
///
/// The caret check reads the field once, *before* the Backspaces. Between that
/// read and the last Backspace the app may still change the text: macOS raises
/// a letter or finishes an autocorrection, and a Backspace right after an
/// autocorrection may take the correction back instead of erasing a character.
/// Typing the new word then leaves a mix of both ("Hell" + "hello"). So the
/// retype posts its Backspaces first, reads the field again, and types only
/// when exactly the word is gone.
///
/// Positions are UTF-16 offsets, as accessibility counts them.
public enum Erasure {
    /// The field as the caret check found it: where the word starts, what is
    /// before it, and the word as the app has it (raised or not).
    public struct Snapshot: Hashable, Sendable {
        public var start: Int
        /// Up to `leadLength` UTF-16 units right before `start`.
        public var lead: String
        public var word: String

        public static let leadLength = 8

        public init(start: Int, lead: String, word: String) {
            self.start = start
            self.lead = lead
            self.word = word
        }
    }

    /// The field right now.
    public struct Reading: Hashable, Sendable {
        public var location: Int
        public var selectionLength: Int
        /// The range of `Snapshot.lead` read again, up to the caret when the
        /// caret is before the word's start: what is left of it.
        public var lead: String
        /// The text from the snapshot's `start` to the caret; empty when the
        /// caret is not past it.
        public var remaining: String

        public init(location: Int, selectionLength: Int = 0, lead: String, remaining: String = "") {
            self.location = location
            self.selectionLength = selectionLength
            self.lead = lead
            self.remaining = remaining
        }
    }

    public enum Progress: Hashable, Sendable {
        /// The word is gone, what was before it is as it was.
        case done
        /// The Backspaces have not all worked (yet): this much of the word is
        /// left, the end of it erased. Nothing else changed.
        case pending(remaining: String)
        /// More than the word is gone. What is left of the text before it is
        /// as it was, or the caret is before all of it that was read.
        case overErased
        /// The text before the word, or the rest of the word, is not what the
        /// Backspaces would leave: the app changed it.
        case changed
        /// The field cannot be read.
        case unreadable
    }

    public static func judge(_ snapshot: Snapshot, _ reading: Reading?) -> Progress {
        guard let reading else { return .unreadable }
        guard reading.selectionLength == 0 else { return .changed }
        if reading.location < snapshot.start {
            // What is left of the text before the word must be what was there.
            let kept = reading.location - (snapshot.start - snapshot.lead.utf16.count)
            guard kept >= 0 else { return .overErased }
            let expected = String(decoding: snapshot.lead.utf16.prefix(kept), as: UTF16.self)
            return same(reading.lead, expected) ? .overErased : .changed
        }
        guard same(reading.lead, snapshot.lead) else { return .changed }
        if reading.location == snapshot.start { return .done }
        let remaining = reading.remaining
        guard remaining.utf16.count == reading.location - snapshot.start,
              CaretText.match(expected: String(decoding: snapshot.word.utf16.prefix(remaining.utf16.count), as: UTF16.self),
                              actual: remaining) != nil
        else { return .changed }
        return .pending(remaining: remaining)
    }

    /// Whether the field shows exactly the snapshot: the text before the word
    /// and the word, as the app had it, with the caret after it.
    static func isSnapshot(_ snapshot: Snapshot, _ reading: Reading?) -> Bool {
        guard case let .pending(remaining) = judge(snapshot, reading) else { return false }
        return remaining.utf16.count == snapshot.word.utf16.count && same(remaining, snapshot.word)
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        CaretText.match(expected: a, actual: b) == .exact
    }

    /// What typing back an over-erased field would take.
    enum PutBack: Equatable {
        /// The end of the text before the word that went, and the word.
        case text(String)
        /// More went than was read before the Backspaces.
        case unknown
        /// The text is not safe to type (`isSafeToType`), or it starts in the
        /// middle of a surrogate pair.
        case unsafe
    }

    static func putBack(_ snapshot: Snapshot, location: Int) -> PutBack {
        let lost = snapshot.start - location
        let units = Array(snapshot.lead.utf16)
        guard lost > 0, lost <= units.count else { return .unknown }
        let text = Array(units.suffix(lost)) + Array(snapshot.word.utf16)
        let string = String(decoding: text, as: UTF16.self)
        guard Array(string.utf16) == text, isSafeToType(string) else { return .unsafe }
        return .text(string)
    }

    /// Text Perekey types back must not do anything but appear: no line
    /// break or tab (a messenger sends on Return, a form moves on Tab), no
    /// other control character, no half of a surrogate pair (it reads back
    /// as U+FFFD, and typing that is a wrong character).
    public static func isSafeToType(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            !(scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .lineSeparator
                || scalar.properties.generalCategory == .paragraphSeparator || scalar.value == 0xFFFD)
        }
    }

    /// Why a retype stopped after its Backspaces. For the log: fixed words, no text.
    public enum Failure: String, Hashable, Sendable {
        case unreadable = "the field cannot be read after the Backspaces"
        case overErased = "the Backspaces erased more than the word, and it cannot be put back for certain; the word is lost"
        case changed = "the app changed the text while the word was erased"
        case idle = "no Backspace worked in time"
        case stalled = "the Backspaces stopped halfway; nothing is typed back, a Backspace still on its way would mix with it"
        case unsafeText = "the Backspaces erased more than the word, and the text to put back holds a line break, a tab or a broken character; nothing is typed back"
        case restoreFailed = "the text typed back does not read as before; the field may differ"
        case late = "the check would not end before the input fence lets the held keys go"
    }

    public enum Outcome: Hashable, Sendable {
        /// The word is erased and nothing else: type the new one.
        case erased
        /// More than the word was erased; it was typed back, and the field
        /// was read again exactly as in the snapshot.
        case restored
        /// Nothing is typed. The field may hold less or other text than before.
        case stopped(Failure)
    }

    public struct Timing: Sendable {
        /// Seconds to wait for the first Backspace to work.
        public var idle = 0.4
        /// Seconds a half-erased word may stay as it is before the retype stops.
        /// An over-erased field must stand still this long before it is typed back.
        public var stall = 0.15
        /// Seconds the caret must stand still after a change before the word counts as erased.
        public var settle = 0.03
        /// Seconds to wait for the typed-back text to show.
        public var restore = 0.3
        /// Seconds the field must stay as in the snapshot after typing back.
        public var verify = 0.1
        /// The longest one read may take: three AX calls at
        /// `TextProbe.messagingTimeout` (0.1 s) each.
        public var read = 0.3

        public init() {}

        /// The least time the check needs once the Backspaces are posted:
        /// the wait for the first one and the read that sees it.
        public var least: Double { idle + read }
    }

    /// Whether a check started at `time` can end before `deadline`. When it
    /// cannot, post no Backspace: they would erase the word with nobody to
    /// look at the field.
    public static func hasTime(at time: Double, deadline: Double, timing: Timing = Timing()) -> Bool {
        time + timing.least < deadline
    }

    /// Waits for the Backspaces already posted to erase exactly the word. Blocks
    /// the calling thread (the AX thread; each `read` costs about a millisecond).
    ///
    /// When it is not exactly the word, the new word is not typed. Text is
    /// typed back in one case only: the Backspaces erased more than the word,
    /// what is left before it is as it was, the caret stood still for
    /// `stall`, and the text that went is safe to type. Then the field is
    /// read again until it stays exactly as in the snapshot (`.restored`), or
    /// the outcome says it does not (`.restoreFailed`).
    ///
    /// A half-erased word is not typed back: its missing Backspaces may still
    /// be on their way, and they would reach the app before the text typed
    /// back ("hel" + a late Backspace + "lo" is "hlo"). The word stays
    /// half-erased and the log says so.
    ///
    /// Returns before `deadline`, the moment the fence would let the user's
    /// input go: after it the user's keys would mix with the text typed back.
    /// A read may take `timing.read`, so the last one starts before
    /// `deadline - timing.read`, and text is typed back only when the wait for
    /// it fits too.
    ///
    /// - `read`: the field now, nil if it cannot be read.
    /// - `restore`: types text as it is. Called at most once.
    public static func confirm(
        _ snapshot: Snapshot, timing: Timing = Timing(), deadline: Double,
        now: () -> Double, pause: () -> Void,
        read: () -> Reading?, restore: (String) -> Void
    ) -> Outcome {
        let started = now()
        var lastReading: Reading?
        var lastChange = started
        var restoredAt: Double?
        // The field was seen holding something other than the word being erased.
        var tainted = false
        while true {
            let time = now()
            guard time + timing.read < deadline else { return .stopped(restoredAt == nil ? .late : .restoreFailed) }
            let reading = read()
            if let reading, reading != lastReading {
                lastReading = reading
                lastChange = time
            }
            let progress = judge(snapshot, reading)
            if let restoredAt {
                // Only the field exactly as in the snapshot, standing still, counts.
                if isSnapshot(snapshot, reading), time - lastChange >= timing.verify { return .restored }
                if time - restoredAt >= timing.restore + timing.verify { return .stopped(.restoreFailed) }
                pause()
                continue
            }
            switch progress {
            case .done:
                // After a change the Backspaces on their way may still take more: wait until it stands still.
                if tainted, time - lastChange < timing.settle { break }
                return .erased
            case .overErased:
                guard let reading else { break }
                tainted = true
                // Backspaces still on their way would take more: wait until it stands still.
                guard time - lastChange >= timing.stall else { break }
                let text: String
                switch putBack(snapshot, location: reading.location) {
                case let .text(safe): text = safe
                case .unknown: return .stopped(.overErased)
                case .unsafe: return .stopped(.unsafeText)
                }
                // Typing back and the wait to see it must end before the fence does.
                guard time + timing.restore + timing.verify + timing.read < deadline else {
                    return .stopped(.overErased)
                }
                restoredAt = time
                restore(text)
            case .changed:
                // Backspaces still on their way would change it again, and
                // there is nothing certain to put back: wait, then stop.
                tainted = true
                if time - lastChange >= timing.settle { return .stopped(.changed) }
            case .unreadable:
                if time - started >= timing.idle { return .stopped(.unreadable) }
            case let .pending(remaining):
                if remaining.utf16.count == snapshot.word.utf16.count {
                    // Nothing erased yet. A busy app may still get to it, and
                    // its Backspaces cannot be recalled: do not type.
                    if time - lastChange >= timing.idle { return .stopped(.idle) }
                } else if time - lastChange >= timing.stall {
                    return .stopped(.stalled)
                }
            }
            pause()
        }
    }
}
