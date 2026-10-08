// SPDX-License-Identifier: GPL-3.0-or-later

/// The keys of the word just typed, with the spaces after it, and of a few
/// words before it (`history`) for the phrase retype.
///
/// The buffer keeps key strokes, not text: the same strokes read as "ghbdtn"
/// in English and "привет" in Russian. Keys `,` `.` `;` `'` `[` `]` are letters
/// in Russian, so they belong to the word too: ",eltn" is "будет".
///
/// Typed text lives here only, in memory. It is never written anywhere.
public struct WordBuffer: Hashable, Sendable {
    public struct Entry: Hashable, Sendable {
        public var stroke: KeyStroke
        /// The layout that was selected when the key was typed.
        public var layout: LayoutID

        public init(_ stroke: KeyStroke, in layout: LayoutID) {
            self.stroke = stroke
            self.layout = layout
        }

        public var isSpace: Bool { stroke.keyCode == KeyCode.space }
    }

    /// Longer runs are not words: a pasted token, a key held down. Retyping
    /// the tail of one would surprise the user, so the buffer gives up on it.
    public static let capacity = 64

    /// How many words before the current one the buffer keeps: a phrase
    /// retype reaches this far back.
    public static let historyWords = 7

    public private(set) var entries: [Entry] = []
    /// The words typed right before `entries`, oldest first, each with the
    /// spaces after it: "ghbdtn vbh " before "tot". Only text the caret has
    /// not left: everything that clears the word clears these too.
    public private(set) var history: [Entry] = []
    /// How many words `history` holds.
    public private(set) var historyCount = 0
    /// Too many keys without a space: ignore keys until the next space.
    private var overflowed = false

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    /// The layout of the word itself, ignoring the spaces after it.
    public var wordLayout: LayoutID? {
        entries.first { !$0.isSpace }?.layout
    }

    public mutating func type(_ stroke: KeyStroke, in layout: LayoutID) {
        let entry = Entry(stroke, in: layout)
        if overflowed {
            if entry.isSpace { overflowed = false }
            return
        }
        if entry.isSpace {
            // Spaces only follow a word; leading spaces are nothing to retype.
            if !entries.isEmpty { entries.append(entry) }
            return
        }
        if entries.last?.isSpace == true {
            pushHistory()
            entries.removeAll(keepingCapacity: true)
        }
        guard entries.count < Self.capacity else {
            clear()
            overflowed = true
            return
        }
        entries.append(entry)
    }

    public mutating func deleteBackward() {
        if !overflowed, !entries.isEmpty {
            entries.removeLast()
        } else {
            // Into the words before: no longer known to be what they were.
            clearHistory()
        }
    }

    /// Forget the word and ignore keys until the next space.
    public mutating func abandonWord() {
        clear()
        overflowed = true
    }

    public mutating func clear() {
        entries.removeAll(keepingCapacity: true)
        clearHistory()
        overflowed = false
    }

    private mutating func clearHistory() {
        history.removeAll(keepingCapacity: true)
        historyCount = 0
    }

    /// The finished word goes to `history`. Old words drop out in batches,
    /// once twice `historyWords` are kept, so a word costs no shift of the
    /// whole history on the tap thread.
    private mutating func pushHistory() {
        history.append(contentsOf: entries)
        historyCount += 1
        guard historyCount > 2 * Self.historyWords else { return }
        var end = history.startIndex
        for _ in 0..<(historyCount - Self.historyWords) {
            while end < history.endIndex, !history[end].isSpace { end += 1 }
            while end < history.endIndex, history[end].isSpace { end += 1 }
        }
        history.removeSubrange(..<end)
        historyCount = Self.historyWords
    }

    /// The last `words` words, the current one included, each with the
    /// spaces after it; `nil` when fewer are known or more than
    /// `historyWords` before the current one are asked for.
    public func phrase(words: Int) -> [Entry]? {
        guard words >= 1, !entries.isEmpty, words - 1 <= min(historyCount, Self.historyWords) else { return nil }
        var start = history.endIndex
        for _ in 0..<(words - 1) {
            // Back over the spaces after the word, then over the word.
            while start > history.startIndex, history[start - 1].isSpace { start -= 1 }
            while start > history.startIndex, !history[start - 1].isSpace { start -= 1 }
        }
        return Array(history[start...]) + entries
    }

    /// Puts other layouts on the last `entries.count` keys: the phrase as a
    /// retype left it. The keys themselves must be the same.
    public mutating func relabelPhrase(_ phrase: [Entry]) {
        let fromHistory = phrase.count - entries.count
        guard fromHistory >= 0, fromHistory <= history.count else { return }
        for (offset, entry) in phrase.prefix(fromHistory).enumerated() {
            history[history.count - fromHistory + offset].layout = entry.layout
        }
        for (index, entry) in zip(entries.indices, phrase.suffix(entries.count)) {
            entries[index].layout = entry.layout
        }
    }

    /// After a correction the word is other keys, possibly more or fewer,
    /// in `layout`. The spaces after it, if any, stay.
    public mutating func replaceWord(_ strokes: [KeyStroke], in layout: LayoutID) {
        let spaces = entries.reversed().prefix(while: \.isSpace).count
        let tail = entries.suffix(spaces)
        entries = strokes.map { Entry($0, in: layout) } + tail
    }

    /// After a case change the word's keys are other strokes in the same layout.
    /// `strokes` must have one stroke per entry.
    public mutating func replaceStrokes(_ strokes: [KeyStroke]) {
        guard strokes.count == entries.count else { return }
        for index in entries.indices { entries[index].stroke = strokes[index] }
    }

    /// After a retype the same keys stand for the word in the new layout, so a
    /// second retype brings the word back.
    public mutating func relabel(to layout: LayoutID) {
        for index in entries.indices { entries[index].layout = layout }
    }
}
