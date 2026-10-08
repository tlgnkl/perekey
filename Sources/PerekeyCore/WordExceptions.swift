// SPDX-License-Identifier: GPL-3.0-or-later

/// A word the user's undo taught Perekey to leave alone.
public struct LearnedWord: Hashable, Sendable, Codable {
    /// The normalized word (see `WordExceptions.normalize`).
    public var word: String
    /// When it was learned, in seconds since 1970. A plain number keeps the core free of `Foundation`.
    public var learnedAt: Double

    public init(word: String, learnedAt: Double) {
        self.word = word
        self.learnedAt = learnedAt
    }
}

/// Words Perekey never corrects: the user's own ("Мои") and the ones learned
/// from undone corrections ("Выученные").
///
/// Words are stored normalized: trimmed and lowercased. The autoswitch asks
/// about the word as typed in either layout reading, so a word matches in
/// whichever of the two readings the user put on the list, in any letter case.
public struct WordExceptions: Hashable, Sendable {
    public var mine: [String]
    public var learned: [LearnedWord]
    /// Whether an undone correction adds its word to `learned`.
    public var learnFromUndos: Bool

    public init(mine: [String] = [], learned: [LearnedWord] = [], learnFromUndos: Bool = true) {
        self.mine = mine
        self.learned = learned
        self.learnFromUndos = learnFromUndos
    }

    public var isEmpty: Bool { mine.isEmpty && learned.isEmpty }
    public var count: Int { mine.count + learned.count }

    /// The stored form of a word: trimmed, lowercased.
    public static func normalize(_ word: String) -> String {
        var text = Substring(word)
        while let first = text.first, first.isWhitespace { text.removeFirst() }
        while let last = text.last, last.isWhitespace { text.removeLast() }
        return text.lowercased()
    }

    /// Why a word can or cannot be added.
    public enum Validation: Hashable, Sendable {
        case ok
        case empty
        /// Not one word: it has characters other than letters, `'`, `’` and `-`.
        case invalid
        case duplicate
        /// Allowed, but the word is common: it will stop being corrected everywhere.
        case frequent
    }

    /// Checks a word before adding. `isFrequent` receives the normalized word and
    /// says whether it is among the 1000 most frequent (the classifier model will provide it).
    public func validate(_ word: String, isFrequent: (String) -> Bool = { _ in false }) -> Validation {
        let normalized = Self.normalize(word)
        if normalized.isEmpty { return .empty }
        guard normalized.contains(where: \.isLetter),
              normalized.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "\u{2019}" || $0 == "-" })
        else { return .invalid }
        if mine.contains(normalized) || learned.contains(where: { $0.word == normalized }) { return .duplicate }
        return isFrequent(normalized) ? .frequent : .ok
    }

    /// True when the word, as typed in one layout reading, is on either list.
    public func contains(_ reading: String) -> Bool {
        let normalized = Self.normalize(reading)
        guard !normalized.isEmpty else { return false }
        return mine.contains(normalized) || learned.contains { $0.word == normalized }
    }

    /// Adds a word to "Мои". A frequent word is allowed: the caller shows the
    /// warning first. A learned copy moves to "Мои". Returns false for an invalid or known word.
    @discardableResult
    public mutating func add(_ word: String) -> Bool {
        let normalized = Self.normalize(word)
        switch validate(normalized) {
        case .ok, .frequent:
            mine.append(normalized)
            return true
        case .duplicate where !mine.contains(normalized):
            learned.removeAll { $0.word == normalized }
            mine.append(normalized)
            return true
        default:
            return false
        }
    }

    /// Removes a word from "Мои".
    public mutating func remove(_ word: String) {
        let normalized = Self.normalize(word)
        mine.removeAll { $0 == normalized }
    }

    /// Learns a word from an undone correction. Does nothing when learning is off,
    /// or the word is invalid or already known. Returns true when the word was added.
    @discardableResult
    public mutating func learn(_ word: String, at seconds: Double) -> Bool {
        guard learnFromUndos else { return false }
        let normalized = Self.normalize(word)
        guard validate(normalized) == .ok else { return false }
        learned.append(LearnedWord(word: normalized, learnedAt: seconds))
        return true
    }

    /// Forgets a learned word. "Мои" words stay; use `remove` for those.
    public mutating func forget(_ word: String) {
        let normalized = Self.normalize(word)
        learned.removeAll { $0.word == normalized }
    }

    public mutating func forgetAllLearned() {
        learned.removeAll()
    }
}

extension WordExceptions: Codable {
    private enum CodingKeys: String, CodingKey {
        case mine, learned, learnFromUndos
    }

    /// Tolerant: missing keys take defaults, and one bad entry is skipped, not fatal.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var seen = Set<String>()
        var mine: [String] = []
        if let raw = try? container.decodeIfPresent([String].self, forKey: .mine) {
            for word in raw.map(Self.normalize) where !word.isEmpty && seen.insert(word).inserted {
                mine.append(word)
            }
        }
        var learned: [LearnedWord] = []
        if var list = try? container.nestedUnkeyedContainer(forKey: .learned) {
            while !list.isAtEnd {
                guard let item = try? list.decode(LearnedWord.self) else {
                    _ = try? list.decode(Skip.self)
                    continue
                }
                let word = Self.normalize(item.word)
                if !word.isEmpty, seen.insert(word).inserted {
                    learned.append(LearnedWord(word: word, learnedAt: item.learnedAt))
                }
            }
        }
        self.mine = mine
        self.learned = learned
        learnFromUndos = (try? container.decodeIfPresent(Bool.self, forKey: .learnFromUndos)) ?? true
    }
}

/// Steps past one array element that failed to decode.
private struct Skip: Decodable {
    init(from decoder: any Decoder) throws {}
}
