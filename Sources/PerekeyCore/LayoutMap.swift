// SPDX-License-Identifier: GPL-3.0-or-later

/// What one keyboard layout types for each key stroke, and back.
///
/// Built on the main thread from `UCKeyTranslate` and handed to the event tap
/// thread ready-made. Immutable, so sharing it is safe.
public struct LayoutMap: Hashable, Sendable {
    public let id: LayoutID
    /// The primary language, e.g. "ru" or "en".
    public let language: String?
    private let table: [KeyStroke: String]
    private let deadKeys: Set<KeyStroke>
    private let reverse: [Character: KeyStroke]

    /// - Parameters:
    ///   - table: the text each stroke types. Leave out strokes that type nothing.
    ///   - deadKeys: strokes that start a dead-key sequence (´, ¨ on ⌥E and ⌥U in ABC).
    public init(id: LayoutID, language: String?, table: [KeyStroke: String], deadKeys: Set<KeyStroke> = []) {
        self.id = id
        self.language = language
        self.table = table
        self.deadKeys = deadKeys

        // Prefer the stroke with the fewest modifiers, then the lowest key code,
        // so the result does not depend on dictionary order.
        var reverse: [Character: KeyStroke] = [:]
        for modifiers in LayoutModifiers.allCombinations {
            for (stroke, text) in table.filter({ $0.key.modifiers == modifiers }).sorted(by: { $0.key.keyCode < $1.key.keyCode }) {
                guard text.count == 1, let character = text.first, reverse[character] == nil else { continue }
                reverse[character] = stroke
            }
        }
        self.reverse = reverse
    }

    /// The text this stroke types, or `nil` if it types nothing or starts a dead-key sequence.
    public func text(for stroke: KeyStroke) -> String? {
        table[stroke]
    }

    public func isDeadKey(_ stroke: KeyStroke) -> Bool {
        deadKeys.contains(stroke)
    }

    /// The stroke that types this character.
    public func stroke(for character: Character) -> KeyStroke? {
        reverse[character]
    }

    /// Types `text` on the keys that typed it in `source`, as this layout would.
    /// Characters `source` cannot type stay as they are: digits, emoji, symbols
    /// pasted from elsewhere.
    public func convert(_ text: String, from source: LayoutMap) -> String {
        String(text.flatMap { character -> [Character] in
            guard let stroke = source.stroke(for: character), let converted = table[stroke] else {
                return [character]
            }
            return Array(converted)
        })
    }
}

extension LayoutMap: Codable {
    // Compact on disk: for each key code, the text for every modifier
    // combination in `LayoutModifiers.allCombinations` order, null where the
    // stroke types nothing. Dead keys are listed as "keyCode/modifiers".
    private enum CodingKeys: String, CodingKey {
        case id, language, keys, dead
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rows = try container.decode([String: [String?]].self, forKey: .keys)
        var table: [KeyStroke: String] = [:]
        for (key, texts) in rows {
            guard let keyCode = UInt16(key) else {
                throw DecodingError.dataCorruptedError(forKey: .keys, in: container,
                                                       debugDescription: "Bad key code \(key)")
            }
            for (index, text) in texts.enumerated() where index < 8 {
                if let text { table[KeyStroke(keyCode, LayoutModifiers(rawValue: UInt8(index)))] = text }
            }
        }
        let dead = try container.decodeIfPresent([String].self, forKey: .dead) ?? []
        let deadKeys = try Set(dead.map { item in
            let parts = item.split(separator: "/")
            guard parts.count == 2, let keyCode = UInt16(parts[0]), let modifiers = UInt8(parts[1]) else {
                throw DecodingError.dataCorruptedError(forKey: .dead, in: container,
                                                       debugDescription: "Bad dead key \(item)")
            }
            return KeyStroke(keyCode, LayoutModifiers(rawValue: modifiers))
        })
        try self.init(id: container.decode(LayoutID.self, forKey: .id),
                      language: container.decodeIfPresent(String.self, forKey: .language),
                      table: table, deadKeys: deadKeys)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(language, forKey: .language)
        var rows: [String: [String?]] = [:]
        for keyCode in Set(table.keys.map(\.keyCode)) {
            rows[String(keyCode)] = LayoutModifiers.allCombinations.map { table[KeyStroke(keyCode, $0)] }
        }
        try container.encode(rows, forKey: .keys)
        try container.encode(deadKeys.map(\.description).sorted(), forKey: .dead)
    }
}
