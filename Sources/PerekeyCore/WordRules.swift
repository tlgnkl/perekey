// SPDX-License-Identifier: GPL-3.0-or-later

/// A word the user's undo taught Perekey to leave alone.
public struct LearnedWord: Hashable, Sendable {
    /// The normalized word (see `WordRules.normalize`).
    public var word: String
    /// When it was learned, in seconds since 1970. A plain number keeps the core free of `Foundation`.
    public var learnedAt: Double
    /// How many times a correction of it was undone, the first one included.
    public var undoCount: Int
    /// When the last undo was, in seconds since 1970.
    public var lastUndoneAt: Double

    public init(word: String, learnedAt: Double, undoCount: Int = 1, lastUndoneAt: Double? = nil) {
        self.word = word
        self.learnedAt = learnedAt
        self.undoCount = undoCount
        self.lastUndoneAt = lastUndoneAt ?? learnedAt
    }
}

extension LearnedWord: Codable {
    private enum CodingKeys: String, CodingKey {
        case word, learnedAt, undoCount, lastUndoneAt
    }

    /// Settings from before the undo count have only `word` and `learnedAt`:
    /// that is one undo, at the time it was learned.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let word = try container.decode(String.self, forKey: .word)
        let learnedAt = try container.decode(Double.self, forKey: .learnedAt)
        let count = (try? container.decodeIfPresent(Int.self, forKey: .undoCount)) ?? 1
        let last = (try? container.decodeIfPresent(Double.self, forKey: .lastUndoneAt)) ?? learnedAt
        self.init(word: word, learnedAt: learnedAt, undoCount: max(1, count), lastUndoneAt: last)
    }
}

/// The user's rules for single words, in three lists:
/// - "Не трогать: мои" (`mine`): typed in by the user, never corrected;
/// - "Не трогать: выученные" (`learned`): taught by undone corrections, never corrected;
/// - "Всегда исправлять" (`always`): switched to at the end of the word whatever
///   the classifier's score, unless a guard keeps it (`Classifier.Reason.isGuard`).
///
/// Words are stored normalized: trimmed and lowercased. The autoswitch asks
/// about the word as typed in either layout reading, so a never-touch word
/// matches in whichever of the two readings the user put on the list, in any
/// letter case. An always-fix word is the form the word should come out in
/// ("аня", not "fyz"): typed in the other layout it switches to it, typed in
/// its own it stays.
///
/// Never-touch beats always-fix: `alwaysFix` refuses a word on `mine`, and
/// `AppSettings.snapshot` drops from the always list whatever is on a
/// never-touch one (an import may bring both).
public struct WordRules: Hashable, Sendable {
    public var mine: [String]
    public var learned: [LearnedWord]
    public var always: [String]
    /// Whether an undone correction adds its word to `learned`.
    public var learnFromUndos: Bool

    /// One of the three lists.
    public enum Section: Hashable, Sendable {
        case mine, learned, always
    }

    public init(mine: [String] = [], learned: [LearnedWord] = [], always: [String] = [], learnFromUndos: Bool = true) {
        self.mine = mine
        self.learned = learned
        self.always = always
        self.learnFromUndos = learnFromUndos
    }

    public var isEmpty: Bool { mine.isEmpty && learned.isEmpty && always.isEmpty }
    public var count: Int { mine.count + learned.count + always.count }

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
        /// Not for "Всегда исправлять": the word is on "Не трогать: мои", which wins.
        case neverTouch
    }

    /// Checks a word before adding it to `section`. `isFrequent` receives the
    /// normalized word and says whether it is among the 1000 most frequent;
    /// only a never-touch list warns about that.
    ///
    /// For "Мои" a word on a never-touch list is a duplicate; an always-fix
    /// one is fine, `add` moves it: never-touch wins. For "Всегда исправлять"
    /// a learned word is fine, `alwaysFix` moves it; a word of "Мои" is not.
    public func validate(_ word: String, for section: Section = .mine,
                         isFrequent: (String) -> Bool = { _ in false }) -> Validation
    {
        let normalized = Self.normalize(word)
        if normalized.isEmpty { return .empty }
        guard normalized.contains(where: \.isLetter),
              normalized.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "\u{2019}" || $0 == "-" })
        else { return .invalid }
        switch section {
        case .mine, .learned:
            if contains(normalized) { return .duplicate }
            return isFrequent(normalized) ? .frequent : .ok
        case .always:
            switch self.section(of: normalized) {
            case .always: return .duplicate
            case .mine: return .neverTouch
            case .learned, nil: return .ok
            }
        }
    }

    /// The list a word is on, if any. Never-touch lists come first.
    public func section(of word: String) -> Section? {
        let normalized = Self.normalize(word)
        guard !normalized.isEmpty else { return nil }
        if mine.contains(normalized) { return .mine }
        if learned.contains(where: { $0.word == normalized }) { return .learned }
        if always.contains(normalized) { return .always }
        return nil
    }

    /// True when the word, as typed in one layout reading, is on a never-touch list.
    public func contains(_ reading: String) -> Bool {
        switch section(of: reading) {
        case .mine, .learned: true
        case .always, nil: false
        }
    }

    /// Adds a word to "Мои". A frequent word is allowed: the caller shows the
    /// warning first. A learned or always-fix copy moves to "Мои". Returns
    /// false for an invalid word or one already there.
    @discardableResult
    public mutating func add(_ word: String) -> Bool {
        let normalized = Self.normalize(word)
        switch validate(normalized) {
        case .ok, .frequent: break
        case .duplicate where !mine.contains(normalized): break
        default: return false
        }
        learned.removeAll { $0.word == normalized }
        always.removeAll { $0 == normalized }
        mine.append(normalized)
        return true
    }

    /// Removes a word from "Мои".
    public mutating func remove(_ word: String) {
        let normalized = Self.normalize(word)
        mine.removeAll { $0 == normalized }
    }

    /// Adds a word to "Всегда исправлять", in the form it should come out in.
    /// `typed` is the other reading the user typed, when known (the hint
    /// after a manual retype passes it): the user says now that it is wrong,
    /// so a learned copy of either reading is forgotten. Returns false when
    /// the word is invalid, already there, or either reading is on "Мои".
    @discardableResult
    public mutating func alwaysFix(_ word: String, typed: String? = nil) -> Bool {
        let normalized = Self.normalize(word)
        let other = typed.map(Self.normalize)
        guard validate(normalized, for: .always) == .ok, other.map({ !mine.contains($0) }) ?? true else {
            return false
        }
        learned.removeAll { $0.word == normalized || $0.word == other }
        always.append(normalized)
        return true
    }

    /// Removes a word from "Всегда исправлять".
    public mutating func stopFixing(_ word: String) {
        let normalized = Self.normalize(word)
        always.removeAll { $0 == normalized }
    }

    /// Learns a word from an undone correction. Does nothing when learning is
    /// off, or the word is invalid or on another list. A word learned before
    /// counts one more undo. Returns true when the word was added, not when
    /// it was counted.
    @discardableResult
    public mutating func learn(_ word: String, at seconds: Double) -> Bool {
        guard learnFromUndos else { return false }
        let normalized = Self.normalize(word)
        if let index = learned.firstIndex(where: { $0.word == normalized }) {
            learned[index].undoCount += 1
            learned[index].lastUndoneAt = seconds
            return false
        }
        guard validate(normalized) == .ok, section(of: normalized) == nil else { return false }
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

    // MARK: - Offering "Всегда исправлять"

    /// What `offerAlwaysFix` needs besides the classifier's decision.
    public struct OfferContext: Hashable, Sendable {
        /// Automatic switching was on when the word was typed.
        public var autoswitch: Bool
        /// The mode of the app the word was typed in.
        public var appMode: AppMode
        /// The word, in either reading, is on one of the lists already.
        public var listed: Bool

        public init(autoswitch: Bool, appMode: AppMode, listed: Bool = false) {
            self.autoswitch = autoswitch
            self.appMode = appMode
            self.listed = listed
        }
    }

    /// Whether the hint after a manual retype offers "Исправлять всегда"
    /// (docs/PLAN.md, stage 7, «Когда предлагать»): only when automatic
    /// switching could act on the word and left it out of doubt, not because
    /// of a guard. A word on a list was decided by the user already.
    public static func offerAlwaysFix(decision: Classifier.Decision, context: OfferContext) -> Bool {
        context.autoswitch && context.appMode == .auto && !context.listed && overrides(decision)
    }

    /// Whether an always-fix word switches over this decision: the
    /// classifier kept the word or was unsure, and not because of a guard.
    /// A score of `-infinity` means the other reading is no word: nothing to switch to.
    public static func overrides(_ decision: Classifier.Decision) -> Bool {
        if case .switch = decision.verdict { return false }
        return !decision.reason.isGuard && decision.score > -.infinity
    }
}

extension Classifier.Reason {
    /// A reason no list overrides: it is about the shape of the token, not
    /// about how likely each reading is (docs/PLAN.md, stage 7, «Когда предлагать»).
    ///
    /// Guards: digits, password-like, code-like, mixed case (a capital inside
    /// the word: captchas, identifiers, product names), the model's
    /// never-switch list (`kept`), and the cases where there is no pair to
    /// compare (`empty`, `unsupported`, `tooLong`).
    ///
    /// Not guards: `noise`, `bothPlausible`, `shortWord` and `compared` below
    /// the threshold. They say how probable the readings are, and a word the
    /// user listed outweighs that. `noise` is a cost per letter above a bound,
    /// a score like the others; a random captcha is caught by the guards or
    /// never matches a listed word.
    public var isGuard: Bool {
        switch self {
        case .empty, .unsupported, .tooLong, .digits, .kept, .passwordLike, .codeLike, .mixedCase: true
        case .noise, .bothPlausible, .shortWord, .compared: false
        }
    }
}

extension WordRules: Codable {
    private enum CodingKeys: String, CodingKey {
        case mine, learned, always, learnFromUndos
    }

    /// Tolerant: missing keys take defaults, and one bad entry is skipped, not
    /// fatal. Settings from before "Всегда исправлять" have no `always`. A word
    /// on two lists stays on the first of `mine`, `learned`, `always`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var seen = Set<String>()
        func words(_ key: CodingKeys) -> [String] {
            guard let raw = try? container.decodeIfPresent([String].self, forKey: key) else { return [] }
            var words: [String] = []
            for word in raw.map(Self.normalize) where !word.isEmpty && seen.insert(word).inserted {
                words.append(word)
            }
            return words
        }
        let mine = words(.mine)
        var learned: [LearnedWord] = []
        if var list = try? container.nestedUnkeyedContainer(forKey: .learned) {
            while !list.isAtEnd {
                guard var item = try? list.decode(LearnedWord.self) else {
                    _ = try? list.decode(Skip.self)
                    continue
                }
                item.word = Self.normalize(item.word)
                if !item.word.isEmpty, seen.insert(item.word).inserted {
                    learned.append(item)
                }
            }
        }
        self.mine = mine
        self.learned = learned
        always = words(.always)
        learnFromUndos = (try? container.decodeIfPresent(Bool.self, forKey: .learnFromUndos)) ?? true
    }
}

/// Steps past one array element that failed to decode.
private struct Skip: Decodable {
    init(from decoder: any Decoder) throws {}
}
