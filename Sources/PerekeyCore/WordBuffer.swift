// SPDX-License-Identifier: GPL-3.0-or-later

/// The keys of the word just typed, with the spaces after it.
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

    public private(set) var entries: [Entry] = []
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
        if entries.last?.isSpace == true { entries.removeAll(keepingCapacity: true) }
        guard entries.count < Self.capacity else {
            clear()
            overflowed = true
            return
        }
        entries.append(entry)
    }

    public mutating func deleteBackward() {
        if !overflowed, !entries.isEmpty { entries.removeLast() }
    }

    /// Forget the word and ignore keys until the next space.
    public mutating func abandonWord() {
        clear()
        overflowed = true
    }

    public mutating func clear() {
        entries.removeAll(keepingCapacity: true)
        overflowed = false
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
