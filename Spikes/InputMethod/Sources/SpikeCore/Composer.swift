// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore

/// How the input method puts a word into the field.
public enum Strategy: String, Sendable, CaseIterable {
    /// A: the word is marked text while typed and is committed, switched or
    /// not, at its end (`setMarkedText`, then `insertText`).
    case marked
    /// B: every letter is committed at once; a word to switch is replaced
    /// over its range (`insertText(_:replacementRange:)`).
    case replace
}

/// The word logic of the spike input method. It types keys through the
/// layout of the current mode, judges the word at its end and switches the
/// mode, without Backspace, fence or AX: one call to the client per word.
public final class Composer {
    /// Should the strokes, typed in `typed`, go to `other`?
    public typealias Decide = ([KeyStroke], _ typed: LayoutMap, _ other: LayoutMap) -> Bool

    public struct Stats: Sendable, Equatable {
        /// Words switched at their end.
        public var switched = 0
        /// Words replaced over their range (strategy B).
        public var replaced = 0
        /// Replacements given up: the field no longer held the typed word.
        public var refused = 0
        /// Replacements the client did not honour: the read-back differed.
        public var broken = 0
        /// Words composed as marked text because the client cannot take strategy B.
        public var fellBack = 0
        /// Words retyped by the Option tap.
        public var manual = 0
    }

    public let strategy: Strategy
    public private(set) var stats = Stats()
    public private(set) var layout: LayoutMap
    private var otherLayout: LayoutMap
    private let decide: Decide
    /// Called when the composer switches the layout, to update the mode.
    public var onSwitch: ((LayoutMap) -> Void)?

    private var strokes: [KeyStroke] = []
    /// Strategy B: where the word starts and how many UTF-16 units of it are in the field.
    private var start: Int?
    private var units = 0
    /// This word is marked text: strategy A, or B fallen back for the client.
    private var marking = false
    /// The client failed strategy B once; it gets marked text from now on.
    private var replacementBroken = false
    /// The last finished word, for the Option tap (strategy B).
    private var last: (start: Int, strokes: [KeyStroke], units: Int, trailing: String)?

    public var current: LayoutID { layout.id }

    public init(strategy: Strategy, latin: LayoutMap, cyrillic: LayoutMap, current: LayoutID?,
                decide: @escaping Decide)
    {
        self.strategy = strategy
        let cyrillicFirst = current == cyrillic.id
        layout = cyrillicFirst ? cyrillic : latin
        otherLayout = cyrillicFirst ? latin : cyrillic
        self.decide = decide
    }

    /// Selects the layout from outside (the user picked the other mode).
    public func select(_ id: LayoutID, client: TextClient) {
        guard id == otherLayout.id else { return }
        commit(client: client)
        swap(&layout, &otherLayout)
        last = nil
    }

    /// Handles a key down. Returns false when the client should handle the key itself.
    public func key(_ stroke: KeyStroke, command: Bool, client: TextClient) -> Bool {
        if command { commit(client: client); last = nil; return false }
        switch stroke.keyCode {
        case KeyCode.delete:
            return backspace(client: client)
        case KeyCode.space:
            finish(client: client)
            client.insert(" ", replacing: nil)
            if let word = last, word.trailing.isEmpty { last?.trailing = " " } else { last = nil }
            return true
        default:
            break
        }
        guard let text = layout.text(for: stroke) else {
            // Return, Tab, arrows, Escape, keys the layout types nothing for.
            finish(client: client)
            last = nil
            return false
        }
        if isLetter(stroke) {
            append(stroke, text: text, client: client)
            return true
        }
        finish(client: client)
        // The mark goes in the layout the word ended in.
        client.insert(layout.text(for: stroke) ?? text, replacing: nil)
        last = nil
        return true
    }

    /// The Option tap: retypes the word in progress or the last word in the other layout.
    public func optionTap(client: TextClient) -> Bool {
        if !strokes.isEmpty {
            swap(&layout, &otherLayout)
            onSwitch?(layout)
            stats.manual += 1
            let text = reading(strokes, in: layout)
            if marking {
                client.mark(text)
            } else if let start, replace(NSRange(location: start, length: units), typed: reading(strokes, in: otherLayout),
                                           with: text, client: client)
            {
                units = (text as NSString).length
            }
            return true
        }
        guard strategy == .replace, let last, !replacementBroken else { return false }
        // The word and the space after it, so the caret stays where it was.
        let typed = reading(last.strokes, in: layout) + last.trailing
        let other = reading(last.strokes, in: otherLayout)
        let range = NSRange(location: last.start, length: last.units + (last.trailing as NSString).length)
        guard replace(range, typed: typed, with: other + last.trailing, client: client) else { return false }
        swap(&layout, &otherLayout)
        onSwitch?(layout)
        stats.manual += 1
        self.last = (last.start, last.strokes, (other as NSString).length, last.trailing)
        return true
    }

    /// Commits the word in progress as typed: focus moves, a command key, the session ends.
    public func commit(client: TextClient) {
        if marking, !strokes.isEmpty { client.insert(reading(strokes, in: layout), replacing: nil) }
        reset()
    }

    // MARK: - Private

    private func isLetter(_ stroke: KeyStroke) -> Bool {
        [layout, otherLayout].contains { map in
            map.text(for: stroke)?.unicodeScalars.contains { CharacterSet.letters.contains($0) } ?? false
        }
    }

    private func append(_ stroke: KeyStroke, text: String, client: TextClient) {
        if strokes.isEmpty {
            let canReplace = strategy == .replace && client.supportsDocumentAccess && !replacementBroken
            marking = !canReplace
            if strategy == .replace, !canReplace { stats.fellBack += 1 }
            start = canReplace ? client.selectedRange()?.location : nil
            if canReplace, start == nil { marking = true; stats.fellBack += 1 }
            units = 0
        }
        strokes.append(stroke)
        if marking {
            client.mark(reading(strokes, in: layout))
        } else {
            client.insert(text, replacing: nil)
            units += (text as NSString).length
        }
    }

    private func backspace(client: TextClient) -> Bool {
        guard !strokes.isEmpty else { last = nil; return false }
        let removed = strokes.removeLast()
        if marking {
            client.mark(reading(strokes, in: layout))
            if strokes.isEmpty { reset() }
            return true
        }
        units -= ((layout.text(for: removed) ?? "") as NSString).length
        if strokes.isEmpty { reset() }
        return false
    }

    /// Ends the word: judges it and puts it in the field in its final layout.
    private func finish(client: TextClient) {
        guard !strokes.isEmpty else { return }
        let typed = reading(strokes, in: layout)
        let switching = decide(strokes, layout, otherLayout)
        let final = switching ? reading(strokes, in: otherLayout) : typed
        var wordStart = start
        if marking {
            if let selection = client.selectedRange() { wordStart = selection.location }
            client.insert(final, replacing: nil)
        } else if switching, let start {
            _ = replace(NSRange(location: start, length: units), typed: typed, with: final, client: client)
        }
        if switching {
            stats.switched += 1
            swap(&layout, &otherLayout)
            onSwitch?(layout)
        }
        let finished = strokes
        reset()
        last = wordStart.map { ($0, finished, (final as NSString).length, "") }
    }

    /// Replaces `range`, which must hold `typed`, and checks that the client did.
    private func replace(_ range: NSRange, typed: String, with text: String, client: TextClient) -> Bool {
        guard let found = client.text(in: range), found == typed else {
            stats.refused += 1
            return false
        }
        client.insert(text, replacing: range)
        let written = NSRange(location: range.location, length: (text as NSString).length)
        guard client.text(in: written) == text else {
            stats.broken += 1
            replacementBroken = true
            return false
        }
        stats.replaced += 1
        return true
    }

    private func reading(_ strokes: [KeyStroke], in map: LayoutMap) -> String {
        strokes.compactMap { map.text(for: $0) }.joined()
    }

    private func reset() {
        strokes.removeAll(keepingCapacity: true)
        start = nil
        units = 0
        marking = false
    }
}
