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
        /// The same range as `Snapshot.lead`, read again.
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
        /// More than the word is gone.
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
        if reading.location < snapshot.start { return .overErased }
        guard same(reading.lead, snapshot.lead) else { return .changed }
        if reading.location == snapshot.start { return .done }
        let remaining = reading.remaining
        guard remaining.utf16.count == reading.location - snapshot.start,
              CaretText.match(expected: String(decoding: snapshot.word.utf16.prefix(remaining.utf16.count), as: UTF16.self),
                              actual: remaining) != nil
        else { return .changed }
        return .pending(remaining: remaining)
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        CaretText.match(expected: a, actual: b) == .exact
    }

    /// Why a retype stopped after its Backspaces. For the log: fixed words, no text.
    public enum Failure: String, Hashable, Sendable {
        case unreadable = "the field cannot be read after the Backspaces"
        case overErased = "the Backspaces erased more than the word"
        case changed = "the app changed the text while the word was erased"
        case idle = "no Backspace worked in time"
        case stuck = "the Backspaces stopped halfway; the rest of the word could not be put back"
    }

    public enum Outcome: Hashable, Sendable {
        /// The word is erased and nothing else: type the new one.
        case erased
        /// Part of the word was erased and put back: the field is as before.
        case restored
        /// Nothing is typed. The field may hold less or other text than before.
        case stopped(Failure)
    }

    public struct Timing: Sendable {
        /// Seconds to wait for the first Backspace to work.
        public var idle = 0.4
        /// Seconds a half-erased word may stay as it is before it is put back.
        public var stall = 0.15
        /// Seconds the caret must stand still before an extra erased text is put back.
        public var settle = 0.03
        /// Seconds to wait for the put-back to show.
        public var restore = 0.3

        public init() {}
    }

    /// Waits for the Backspaces already posted to erase exactly the word. Blocks
    /// the calling thread (the AX thread; each `read` costs about a millisecond).
    ///
    /// When it is not exactly the word, nothing is typed. If the field can be
    /// put back with certainty it is: the end of the word that did get erased,
    /// or the end of the text before the word that an extra Backspace took,
    /// is typed again. Otherwise the outcome says why it stopped.
    ///
    /// - `read`: the field now, nil if it cannot be read.
    /// - `restore`: types text as it is. Called at most once.
    public static func confirm(
        _ snapshot: Snapshot, timing: Timing = Timing(),
        now: () -> Double, pause: () -> Void,
        read: () -> Reading?, restore: (String) -> Void
    ) -> Outcome {
        let started = now()
        var lastRemaining: String?
        var lastChange = started
        var lastLocation: Int?
        var restoring: Double?
        var restoringLead = false
        // The field was seen holding something other than the word being erased.
        var tainted = false
        while true {
            let time = now()
            let reading = read()
            if let reading, reading.location != lastLocation {
                lastLocation = reading.location
                lastChange = time
            }
            switch judge(snapshot, reading) {
            case .done:
                if restoring != nil {
                    return restoringLead ? .restored : .stopped(.stuck)
                }
                // After a change the Backspaces on their way may still take more: wait until it stands still.
                if tainted, time - lastChange < timing.settle { break }
                return .erased
            case .overErased:
                guard let reading else { break }
                if let restoringSince = restoring {
                    if time - restoringSince >= timing.restore { return .stopped(.stuck) }
                    break
                }
                // Backspaces still on their way would take more: wait until it stands still.
                tainted = true
                guard time - lastChange >= timing.settle else { break }
                let lost = snapshot.start - reading.location
                let units = Array(snapshot.lead.utf16)
                let tail = Array(units.suffix(lost))
                // Not in the middle of a surrogate pair, not more than was read before.
                guard lost <= units.count, Array(String(decoding: tail, as: UTF16.self).utf16) == tail else {
                    return .stopped(.overErased)
                }
                restoring = time
                restoringLead = true
                restore(String(decoding: tail, as: UTF16.self))
            case .changed:
                // Backspaces still on their way would change it again, and
                // there is nothing certain to put back: wait, then stop.
                tainted = true
                if restoring != nil || time - lastChange >= timing.settle { return .stopped(.changed) }
            case .unreadable:
                if time - started >= timing.idle { return .stopped(.unreadable) }
            case let .pending(remaining):
                if let restoringSince = restoring {
                    if restoringLead { return .stopped(.stuck) }
                    if remaining.utf16.count == snapshot.word.utf16.count { return .restored }
                    if time - restoringSince >= timing.restore { return .stopped(.stuck) }
                    break
                }
                if remaining != lastRemaining {
                    lastRemaining = remaining
                    lastChange = time
                }
                let whole = remaining.utf16.count == snapshot.word.utf16.count
                if whole {
                    // Nothing erased yet. A busy app may still get to it, and
                    // its Backspaces cannot be recalled: do not type, do not put back.
                    if time - lastChange >= timing.idle { return .stopped(.idle) }
                } else if time - lastChange >= timing.stall {
                    restoring = time
                    restore(String(decoding: snapshot.word.utf16.dropFirst(remaining.utf16.count), as: UTF16.self))
                }
            }
            pause()
        }
    }
}
