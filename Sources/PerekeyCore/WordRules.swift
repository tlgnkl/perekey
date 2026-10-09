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
/// ("артём", not "fhn`v"): typed in the other layout it switches to it, typed
/// in its own it stays. It matches with "ё" as "е" and "’" as "'"
/// (`matchKey`), and comes out spelt as stored.
///
/// Never-touch beats always-fix, in either reading of the word: adding to
/// "Мои" takes the word off "Всегда исправлять", `alwaysFix` refuses a word
/// of "Мои", and `AppSettings.snapshot` drops from the always list whatever
/// is on a never-touch one (an import may bring both). The other readings
/// come from the installed layouts (`readings(of:in:)`); the core has none of
/// its own, so the callers pass them.
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

    /// "Всегда исправлять" takes words of this many letters and more: a
    /// shorter one is too often meant as typed.
    public static let alwaysFixMinLetters = 3

    public init(mine: [String] = [], learned: [LearnedWord] = [], always: [String] = [], learnFromUndos: Bool = true) {
        self.mine = mine
        self.learned = learned
        self.always = always
        self.learnFromUndos = learnFromUndos
    }

    public var isEmpty: Bool { mine.isEmpty && learned.isEmpty && always.isEmpty }
    public var count: Int { mine.count + learned.count + always.count }

    /// The stored form of a word: trimmed, lowercased.
    /// The Ukrainian apostrophe `ʼ` (U+02BC, what Ukrainian-PC types) is
    /// `'`, as the model reads it (`ModelFormat.fold`): «м'ясо» on a list
    /// matches «мʼясо» typed.
    public static func normalize(_ word: String) -> String {
        var text = Substring(word)
        while let first = text.first, first.isWhitespace { text.removeFirst() }
        while let last = text.last, last.isWhitespace { text.removeLast() }
        let lowered = text.lowercased()
        guard lowered.contains("\u{2BC}") else { return lowered }
        return String(lowered.map { $0 == "\u{2BC}" ? "'" : $0 })
    }

    /// The form "Всегда исправлять" matches by: normalized (so `ʼ` as "'"),
    /// "ё" as "е", "’" as "'".
    public static func matchKey(_ word: String) -> String {
        String(normalize(word).map { character -> Character in
            switch character {
            case "ё": "е"
            case "\u{2019}": "'"
            default: character
            }
        })
    }

    /// The always-fix words by `matchKey`, each with its stored spelling.
    public var alwaysFixTable: [String: String] {
        var table: [String: String] = [:]
        for word in always { table[Self.matchKey(word)] = word }
        return table
    }

    /// The word typed on the same keys in the other installed layouts,
    /// normalized: "аня" gives "fyz" with ABC and Russian.
    public static func readings(of word: String, in layouts: [LayoutMap]) -> [String] {
        let normalized = normalize(word)
        guard !normalized.isEmpty else { return [] }
        var readings: [String] = []
        for source in layouts where normalized.allSatisfy({ source.stroke(for: $0) != nil }) {
            for target in layouts where target.id != source.id && target.language != source.language {
                let reading = normalize(target.convert(normalized, from: source))
                if reading != normalized, !readings.contains(reading) { readings.append(reading) }
            }
        }
        return readings
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
        /// Not for "Всегда исправлять": the word, in some reading, is on
        /// "Не трогать: мои", which wins.
        case neverTouch
        /// Not for "Всегда исправлять": fewer than `alwaysFixMinLetters` letters.
        case tooShort
    }

    /// Checks a word before adding it to `section`. `readings` are the word
    /// typed on the same keys in the other layouts (`readings(of:in:)`).
    /// `isFrequent` receives the normalized word and says whether it is among
    /// the 1000 most frequent; only a never-touch list warns about that.
    ///
    /// For "Мои" a word on a never-touch list, in any reading, is a
    /// duplicate; an always-fix one is fine, `add` moves it: never-touch wins.
    /// For "Всегда исправлять" a learned word is fine, `alwaysFix` forgets it;
    /// a word of "Мои" is not.
    public func validate(_ word: String, for section: Section = .mine, readings: [String] = [],
                         isFrequent: (String) -> Bool = { _ in false }) -> Validation
    {
        let normalized = Self.normalize(word)
        if normalized.isEmpty { return .empty }
        guard normalized.contains(where: \.isLetter),
              normalized.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "\u{2019}" || $0 == "-" })
        else { return .invalid }
        let forms = [normalized] + readings.map(Self.normalize)
        switch section {
        case .mine, .learned:
            if forms.contains(where: contains) { return .duplicate }
            return isFrequent(normalized) ? .frequent : .ok
        case .always:
            if normalized.filter(\.isLetter).count < Self.alwaysFixMinLetters { return .tooShort }
            if forms.contains(where: { self.section(of: $0) == .always }) { return .duplicate }
            if forms.contains(where: mine.contains) { return .neverTouch }
            return .ok
        }
    }

    /// The list a word is on, if any. Never-touch lists come first.
    public func section(of word: String) -> Section? {
        let normalized = Self.normalize(word)
        guard !normalized.isEmpty else { return nil }
        if mine.contains(normalized) { return .mine }
        if learned.contains(where: { $0.word == normalized }) { return .learned }
        let key = Self.matchKey(normalized)
        if always.contains(where: { Self.matchKey($0) == key }) { return .always }
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
    /// warning first. A learned or always-fix copy, in any of `readings`,
    /// gives way to it. Returns false for an invalid word or one already
    /// there in some reading.
    @discardableResult
    public mutating func add(_ word: String, readings: [String] = []) -> Bool {
        let normalized = Self.normalize(word)
        let forms = [normalized] + readings.map(Self.normalize)
        guard validate(normalized) != .empty, validate(normalized) != .invalid,
              !forms.contains(where: mine.contains)
        else { return false }
        learned.removeAll { forms.contains($0.word) }
        let keys = Set(forms.map(Self.matchKey))
        always.removeAll { keys.contains(Self.matchKey($0)) }
        mine.append(normalized)
        return true
    }

    /// Removes a word from "Мои".
    public mutating func remove(_ word: String) {
        let normalized = Self.normalize(word)
        mine.removeAll { $0 == normalized }
    }

    /// Adds a word to "Всегда исправлять", in the form it should come out in.
    /// `readings` are its other readings (`readings(of:in:)`); `typed` is the
    /// one the user typed, when known (the hint after a manual retype passes
    /// it). The user says now that those are wrong, so a learned copy of any
    /// of them is forgotten. Returns false when `validate(_:for: .always)`
    /// refuses the word or `typed` is on "Мои".
    @discardableResult
    public mutating func alwaysFix(_ word: String, typed: String? = nil, readings: [String] = []) -> Bool {
        let normalized = Self.normalize(word)
        let others = (typed.map { [$0] } ?? []) + readings
        guard validate(normalized, for: .always, readings: others) == .ok else { return false }
        let forms = [normalized] + others.map(Self.normalize)
        learned.removeAll { forms.contains($0.word) }
        always.append(normalized)
        return true
    }

    /// Removes a word from "Всегда исправлять", whatever its "ё" and apostrophe.
    public mutating func stopFixing(_ word: String) {
        let key = Self.matchKey(word)
        always.removeAll { Self.matchKey($0) == key }
    }

    /// Learns a word from an undone correction. Does nothing when learning is
    /// off, or the word is invalid or on another list. A word learned before
    /// counts one more undo. When the word or one of its `readings` is on
    /// "Всегда исправлять", the undo withdraws that instead and learns
    /// nothing: the latest explicit signal wins. Returns true when the word
    /// was added, not when it was counted or withdrawn.
    @discardableResult
    public mutating func learn(_ word: String, at seconds: Double, readings: [String] = []) -> Bool {
        guard learnFromUndos else { return false }
        let normalized = Self.normalize(word)
        let forms = [normalized] + readings.map(Self.normalize)
        if forms.contains(where: { section(of: $0) == .always }) {
            for form in forms { stopFixing(form) }
            return false
        }
        if let index = learned.firstIndex(where: { $0.word == normalized }) {
            learned[index].undoCount += 1
            learned[index].lastUndoneAt = seconds
            return false
        }
        guard validate(normalized, readings: readings) == .ok else { return false }
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
    /// A 1–2 letter word (`shortWord`) is a doubt but is not offered: the
    /// list does not take it (`alwaysFixMinLetters`).
    public static func offerAlwaysFix(decision: Classifier.Decision, context: OfferContext) -> Bool {
        context.autoswitch && context.appMode == .auto && !context.listed && decision.reason != .shortWord
            && overrides(decision)
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
