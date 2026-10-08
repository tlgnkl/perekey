// SPDX-License-Identifier: GPL-3.0-or-later

/// Converting selected text: which layout typed it, and the keys that retype
/// it in another layout.
///
/// Unlike a word, a selection comes without key strokes, only as text. The
/// strokes are found back through the reverse `LayoutMap` of the layout that
/// most likely typed it.
public enum SelectionConversion {
    /// Longer selections are refused. Every character is a key press, and
    /// typing hundreds of them takes visible time while input is held.
    public static let maxLength = 500

    public enum Result: Hashable, Sendable {
        case keys(source: LayoutID, [Retype.Key])
        case refused(Refusal)
    }

    /// Whether the selection can be typed at all. Return would send a
    /// message in a chat and Tab would move the focus, so line breaks and
    /// control characters are refused.
    public static func isTypable(_ text: String) -> Bool {
        text.count <= maxLength && !text.contains { character in
            character.isNewline || character.unicodeScalars.contains { $0.properties.generalCategory == .control }
        }
    }

    /// The layout that typed the most characters of `text` without ⌥; on a
    /// tie, the earlier one in `layouts`. `nil` if none types any of them.
    ///
    /// Characters every layout types (digits, space) add to every count
    /// alike, so they do not decide.
    public static func sourceLayout(of text: String, among layouts: [LayoutMap]) -> LayoutMap? {
        var best: LayoutMap?
        var bestCount = 0
        for layout in layouts {
            var count = 0
            for character in text {
                if let stroke = layout.stroke(for: character), !stroke.modifiers.contains(.option) { count += 1 }
            }
            if count > bestCount {
                best = layout
                bestCount = count
            }
        }
        return best
    }

    /// The keys that type `text` as `target` would on the keys `source` typed it with.
    ///
    /// Characters `source` does not type keep their text (digits, emoji,
    /// symbols pasted from elsewhere). Their key code is the one `target` types
    /// them with, or Space if no layout does: apps that read key codes only
    /// (Java, VMs) get a space there, everyone else the character.
    public static func keys(for text: String, from source: LayoutMap, to target: LayoutMap) -> [Retype.Key] {
        var keys: [Retype.Key] = []
        keys.reserveCapacity(text.count)
        for character in text {
            if let stroke = source.stroke(for: character), !stroke.modifiers.contains(.option),
               let converted = target.text(for: stroke)
            {
                keys.append(Retype.Key(stroke: stroke, text: converted))
            } else {
                let stroke = target.stroke(for: character) ?? KeyStroke(KeyCode.space)
                keys.append(Retype.Key(stroke: stroke, text: String(character)))
            }
        }
        return keys
    }

    /// Everything in one: checks, the source layout and the keys. `layouts`
    /// in order of preference for ties, the current layout first.
    /// `counterpart` picks the target for a source.
    public static func convert(_ text: String, layouts: [LayoutMap],
                               counterpart: (LayoutID) -> LayoutMap?) -> Result
    {
        guard !text.isEmpty else { return .refused(.nothingSelected) }
        guard isTypable(text) else { return .refused(.unsupportedSelection) }
        guard let source = sourceLayout(of: text, among: layouts), let target = counterpart(source.id) else {
            return .refused(.unsupportedSelection)
        }
        let keys = keys(for: text, from: source, to: target)
        // Digits, punctuation both layouts share: retyping would change nothing.
        guard keys.map(\.text).joined() != text else { return .refused(.unsupportedSelection) }
        return .keys(source: source.id, keys)
    }
}
