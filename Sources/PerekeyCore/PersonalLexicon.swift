// SPDX-License-Identifier: GPL-3.0-or-later

/// A language code of two ASCII characters, e.g. "ru", held as one number:
/// the hot path hashes and compares it without a `String` (no reference
/// count). The model's codes are all of two letters (`LanguageModel`); a layout
/// with another code has no personal words.
public struct LanguageCode: Hashable, Comparable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    /// The first character in the low byte, the second above it.
    public let rawValue: UInt16

    init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    /// Two printable ASCII characters, nothing else: a 0 byte ends the code
    /// in the fingerprint's input (`PersonalKey.fingerprint`).
    public init?(_ text: some StringProtocol) {
        var bytes = text.utf8.makeIterator()
        guard let first = bytes.next(), let second = bytes.next(), bytes.next() == nil,
              Self.isPrintable(first), Self.isPrintable(second)
        else { return nil }
        rawValue = UInt16(first) | UInt16(second) << 8
    }

    public init(stringLiteral value: String) {
        guard let code = Self(value) else { preconditionFailure("a language code is two printable ASCII characters") }
        self = code
    }

    /// The printable ASCII range: from "!" to "~".
    private static func isPrintable(_ byte: UInt8) -> Bool {
        byte >= 0x21 && byte <= 0x7E
    }

    public var text: String {
        String(decoding: [UInt8(truncatingIfNeeded: rawValue), UInt8(truncatingIfNeeded: rawValue >> 8)], as: UTF8.self)
    }

    public var description: String { text }

    public static func < (lhs: LanguageCode, rhs: LanguageCode) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The key of the personal lexicon: 16 random bytes the app keeps in the
/// Keychain. With the key a fingerprint can be checked against a guessed
/// word; without it the fingerprints say nothing (docs/classifier.md,
/// «Личный словарь»). It prints as `<redacted>`: the value must not reach a
/// log, a crash report or a failed test's message.
public struct PersonalKey: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    /// The first and the last eight bytes, little-endian, as SipHash takes them.
    public let k0: UInt64
    public let k1: UInt64

    public init(k0: UInt64, k1: UInt64) {
        self.k0 = k0
        self.k1 = k1
    }

    /// Bytes in a key: SipHash-2-4 takes 128 bits.
    public static let byteCount = 16

    /// The key of 16 bytes; nil for any other length, and for 16 zero
    /// bytes: that is a buffer nobody filled, not a random key.
    public init?(bytes: some Collection<UInt8>) {
        guard bytes.count == Self.byteCount, bytes.contains(where: { $0 != 0 }) else { return nil }
        var k0: UInt64 = 0
        var k1: UInt64 = 0
        for (index, byte) in bytes.enumerated() {
            if index < Self.byteCount / 2 {
                k0 |= UInt64(byte) << (8 * UInt64(index))
            } else {
                k1 |= UInt64(byte) << (8 * UInt64(index - Self.byteCount / 2))
            }
        }
        self.init(k0: k0, k1: k1)
    }

    /// Whether this is the all-zero key, which no random draw gives.
    public var isZero: Bool { k0 == 0 && k1 == 0 }

    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
    public var customMirror: Mirror { Mirror(self, children: []) }

    /// What a fingerprint stands for: the hash input starts with it, so a
    /// word and the start of another one never share a fingerprint.
    public enum Domain: UInt8, Sendable {
        case word = 1
        /// The first `shortStart` letters of a word.
        case start3 = 3
        /// The first `longStart`.
        case start4 = 4
    }

    /// The lengths of the starts the early switch asks about
    /// (`WordJudge.insideWord` judges after the third and the fourth key;
    /// `Reading.prefixPossible` looks at the first `min(4, letters)`).
    public static let shortStart = 3
    public static let longStart = 4

    /// The fingerprint of `scalars` under the key: SipHash-2-4 of four
    /// bytes, the domain byte, the language code, a 0 byte, then each scalar
    /// as four bytes little-endian, folded as the model folds it
    /// (`ModelFormat.fold`) and with "ё" as "е" (`WordRules.matchKey`):
    /// one spelling for the word kept and the word looked up, "артём" and
    /// "артем" alike.
    public func fingerprint(_ domain: Domain, language: LanguageCode, _ scalars: some Sequence<UInt32>) -> UInt64 {
        var hasher = SipHash24(key: self)
        // The domain, the two characters of the language and the 0 byte are
        // four bytes: one block step, little-endian.
        hasher.append(littleEndian: UInt32(domain.rawValue) | UInt32(language.rawValue) << 8)
        for scalar in scalars {
            hasher.append(littleEndian: Self.spelling(scalar))
        }
        return hasher.finalize()
    }

    /// The fingerprint of a word as the main thread knows it: the text of
    /// its core, without quotes or marks around it. "Забыть" in the hint and
    /// the signals that drop a word find it by this (`PersonalLexiconModel.forget`).
    public func fingerprint(ofWord text: String, language: LanguageCode) -> UInt64 {
        fingerprint(.word, language: language, text.unicodeScalars.lazy.map(\.value))
    }

    /// "ё" and "е": a word is kept and looked up with one spelling.
    private static let yo: UInt32 = 0x451
    private static let ye: UInt32 = 0x435

    /// A scalar as the fingerprint takes it: folded, "ё" as "е".
    @inline(__always)
    static func spelling(_ scalar: UInt32) -> UInt32 {
        let folded = ModelFormat.fold(scalar)
        return folded == yo ? ye : folded
    }
}

/// What the personal lexicon learns from one word the user typed and kept:
/// its keyed fingerprints and its language, never its text. Only plain
/// numbers: the machine holds one per word without a reference count.
public struct PersonalObservation: Hashable, Sendable {
    /// The fingerprint of the word (`PersonalKey.Domain.word`).
    public var word: UInt64
    /// The fingerprints of its first three and four letters; `start4` is
    /// nil for a word of three. Both nil for a word the snapshot has
    /// already: its starts are in the snapshot, and the count needs only
    /// the word (`Classifier.personalObservation`, `known`). The store keeps
    /// them only when the word is accepted (`PersonalLexiconModel.Entry`).
    public var start3: UInt64?
    public var start4: UInt64?
    /// The language of the layout it was read in.
    public var language: LanguageCode

    public init(word: UInt64, start3: UInt64?, start4: UInt64?, language: LanguageCode) {
        self.word = word
        self.start3 = start3
        self.start4 = start4
        self.language = language
    }
}

/// The observations confirmed since the last batch (`Effect.wordsKept`).
public struct PersonalTally: Hashable, Sendable, Codable {
    public var observations: [PersonalObservation]
    /// The `PersonalLexicon.generation` they were made under: a batch made
    /// before an erase is dropped (`PersonalLexiconModel.record`).
    public var generation: UInt32

    public init(observations: [PersonalObservation], generation: UInt32) {
        self.observations = observations
        self.generation = generation
    }
}

/// The numbers of the personal lexicon. Every one is a first guess, to be
/// fitted on recorded sessions (`perekey-eval replay`, plan 7.2): nothing
/// measured them yet. `perekey-eval personal` checks that the corpus's
/// "user" gets their names in and that no poison gets in with them.
public struct PersonalOptions: Hashable, Sendable {
    /// Confirmed observations of a word before it is accepted.
    public var promoteCount = 5
    /// Different calendar days among them: a word typed five times in one
    /// message is no habit.
    public var promoteDays = 3
    /// Days a candidate stays without being seen again.
    public var candidateLifetime = 60
    /// Days an accepted word stays without being seen again.
    public var wordLifetime = 365
    /// Accepted words and candidates kept at most: the ones seen longest
    /// ago go first.
    public var maxWords = 5000
    public var maxCandidates = 20000
    /// Shorter words are left to the rule of short words
    /// (`Classifier.Options.shortWordRank`), longer ones are no words: the
    /// typo corrector's bound (`TypoCorrector.Options.maxLetters`).
    public var minLetters = 3
    public var maxLetters = 24

    public init() {}
}

/// The personal lexicon as the tap thread sees it: the key and the sorted
/// fingerprints of the accepted words and of their starts. Immutable and
/// shared: a copy is a copy of one reference, and a lookup is a binary
/// search, without allocation.
///
/// `.off` has no key: nothing is looked up and nothing is observed. A
/// snapshot with a key and no words is on and empty: words are observed,
/// none is looked up.
///
/// It prints as `<redacted>`, as its key does.
public struct PersonalLexicon: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    final class Storage: Sendable {
        let key: PersonalKey
        let words: [UInt64]
        let starts: [UInt64]
        /// The languages of the accepted words, or nil when not known (a
        /// snapshot made by hand): a reading in another language is not
        /// hashed (`mayHold`).
        let languages: [LanguageCode]?
        let generation: UInt32
        let minLetters: Int
        let maxLetters: Int

        init(key: PersonalKey, words: [UInt64], starts: [UInt64], languages: [LanguageCode]?, generation: UInt32,
             minLetters: Int, maxLetters: Int)
        {
            self.key = key
            self.words = words
            self.starts = starts
            self.languages = languages
            self.generation = generation
            self.minLetters = minLetters
            self.maxLetters = maxLetters
        }
    }

    private let storage: Storage?

    /// No lexicon: the default, and what the app sends while «Мои слова» is off.
    public static let off = PersonalLexicon()

    public init() {
        storage = nil
    }

    /// - Parameters:
    ///   - words: fingerprints of accepted words (`PersonalKey.Domain.word`).
    ///   - starts: fingerprints of their starts (`.start3`, `.start4`).
    ///   - languages: the languages the words are in; nil does not say, and
    ///     every language is looked up.
    ///   - generation: the store's count of erases (`PersonalLexiconModel.generation`).
    public init(key: PersonalKey, words: some Sequence<UInt64>, starts: some Sequence<UInt64>,
                languages: [LanguageCode]? = nil, generation: UInt32 = 0,
                options: PersonalOptions = PersonalOptions())
    {
        storage = Storage(key: key, words: Self.sorted(words), starts: Self.sorted(starts),
                          languages: languages.map { Self.sorted($0) },
                          generation: generation, minLetters: options.minLetters, maxLetters: options.maxLetters)
    }

    private static func sorted<Element: Comparable>(_ values: some Sequence<Element>) -> [Element] {
        var array = Array(values)
        array.sort()
        var unique: [Element] = []
        unique.reserveCapacity(array.count)
        for value in array where unique.last != value { unique.append(value) }
        return unique
    }

    /// The key, nil when off.
    public var key: PersonalKey? { storage?.key }
    /// Words are observed: the lexicon is on.
    public var isOn: Bool { storage != nil }
    /// Words are looked up: on, with some accepted.
    public var hasWords: Bool { !(storage?.words.isEmpty ?? true) }
    public var wordCount: Int { storage?.words.count ?? 0 }
    public var generation: UInt32 { storage?.generation ?? 0 }
    public var minLetters: Int { storage?.minLetters ?? PersonalOptions().minLetters }
    public var maxLetters: Int { storage?.maxLetters ?? PersonalOptions().maxLetters }
    /// The sorted fingerprints, for the session format and the tests.
    public var words: [UInt64] { storage?.words ?? [] }
    public var starts: [UInt64] { storage?.starts ?? [] }
    public var languages: [LanguageCode]? { storage?.languages }

    /// Whether a word of `language` can be here: a reading in a language
    /// none of the words is in is not hashed.
    public func mayHold(_ language: LanguageCode) -> Bool {
        guard let languages = storage?.languages else { return true }
        for held in languages where held == language { return true }
        return false
    }

    public func containsWord(_ fingerprint: UInt64) -> Bool {
        guard let storage else { return false }
        return Self.search(storage.words, fingerprint)
    }

    public func containsStart(_ fingerprint: UInt64) -> Bool {
        guard let storage else { return false }
        return Self.search(storage.starts, fingerprint)
    }

    private static func search(_ values: [UInt64], _ value: UInt64) -> Bool {
        var low = 0
        var high = values.count
        while low < high {
            let middle = (low + high) / 2
            let found = values[middle]
            if found == value { return true }
            if found < value { low = middle + 1 } else { high = middle }
        }
        return false
    }

    public static func == (lhs: PersonalLexicon, rhs: PersonalLexicon) -> Bool {
        switch (lhs.storage, rhs.storage) {
        case (nil, nil): return true
        case let (left?, right?):
            return left === right
                || (left.key == right.key && left.generation == right.generation && left.minLetters == right.minLetters
                    && left.maxLetters == right.maxLetters && left.words == right.words && left.starts == right.starts
                    && left.languages == right.languages)
        default: return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(generation)
        hasher.combine(wordCount)
    }

    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

/// The count behind the personal lexicon: candidates and accepted words by
/// fingerprint, with how often and on how many days each was seen. Pure:
/// the app's store runs it on the main thread, gives it the day of each
/// batch and sends the tap a new snapshot when the accepted set changes
/// (plan 7.3).
///
/// Strong signals drop a word at once, the latest explicit signal winning
/// as for «Всегда исправлять»: the undo of a switch to it, a manual retype
/// of it into another layout, «Забыть» in the hint (`forget`).
public struct PersonalLexiconModel: Hashable, Sendable {
    public struct Entry: Hashable, Sendable {
        public var language: LanguageCode
        /// The fingerprints of the first three and four letters: kept for an
        /// accepted word only, and nil for a candidate. The early switch
        /// (`WordJudge.insideWord`) needs the starts of the words it holds
        /// back, and a start is a small thing to try with a key in hand
        /// (26³ and 26⁴ strings): a candidate, which may be any string the
        /// user typed twice, does not get one stored.
        public var start3: UInt64?
        public var start4: UInt64?
        /// Confirmed observations.
        public var count: Int
        /// Different days among them.
        public var days: Int
        /// The day it was last seen, as the store counts days.
        public var lastDay: Int
        public var accepted: Bool

        public init(language: LanguageCode, start3: UInt64? = nil, start4: UInt64? = nil, count: Int, days: Int,
                    lastDay: Int, accepted: Bool)
        {
            self.language = language
            self.start3 = start3
            self.start4 = start4
            self.count = count
            self.days = days
            self.lastDay = lastDay
            self.accepted = accepted
        }
    }

    public var options: PersonalOptions
    /// By the fingerprint of the word.
    public private(set) var entries: [UInt64: Entry]
    /// Bumped by `erase()`: batches made before it are dropped.
    public private(set) var generation: UInt32
    public private(set) var acceptedCount: Int
    public var candidateCount: Int { entries.count - acceptedCount }

    public init(options: PersonalOptions = PersonalOptions(), entries: [UInt64: Entry] = [:], generation: UInt32 = 0) {
        self.options = options
        self.entries = entries
        self.generation = generation
        acceptedCount = entries.values.filter(\.accepted).count
    }

    /// Counts a batch seen on `day`. Returns whether the set of accepted
    /// words changed: then the tap needs a new snapshot. A batch of another
    /// generation counts nothing.
    @discardableResult
    public mutating func record(_ tally: PersonalTally, day: Int) -> Bool {
        guard tally.generation == generation else { return false }
        var changed = false
        for observation in tally.observations {
            if record(observation, day: day) { changed = true }
        }
        return changed
    }

    private mutating func record(_ observation: PersonalObservation, day: Int) -> Bool {
        var changed = false
        if var entry = entries[observation.word] {
            entry.count += 1
            if day > entry.lastDay {
                entry.days += 1
                entry.lastDay = day
            }
            if !entry.accepted, entry.count >= options.promoteCount, entry.days >= options.promoteDays {
                if acceptedCount >= options.maxWords, let oldest = oldest(accepted: true) {
                    entries[oldest] = nil
                    acceptedCount -= 1
                }
                entry.accepted = true
                // The starts come with the acceptance, from the observation
                // that carries them; a word the tap already had has none.
                entry.start3 = observation.start3
                entry.start4 = observation.start4
                acceptedCount += 1
                changed = true
            }
            entries[observation.word] = entry
        } else {
            if candidateCount >= options.maxCandidates, let oldest = oldest(accepted: false) {
                entries[oldest] = nil
            }
            entries[observation.word] = Entry(language: observation.language, count: 1, days: 1, lastDay: day,
                                              accepted: false)
        }
        return changed
    }

    /// The entry seen longest ago among the accepted words or the
    /// candidates; of two seen the same day, the smaller fingerprint, so
    /// the choice does not depend on the order of the table.
    private func oldest(accepted: Bool) -> UInt64? {
        var found: (fingerprint: UInt64, day: Int)?
        for (fingerprint, entry) in entries where entry.accepted == accepted {
            if let best = found, (best.day, best.fingerprint) <= (entry.lastDay, fingerprint) { continue }
            found = (fingerprint, entry.lastDay)
        }
        return found?.fingerprint
    }

    /// Drops the word at once: a strong signal against it. Returns whether
    /// the set of accepted words changed.
    @discardableResult
    public mutating func forget(_ word: UInt64) -> Bool {
        guard let entry = entries.removeValue(forKey: word) else { return false }
        if entry.accepted { acceptedCount -= 1 }
        return entry.accepted
    }

    /// Drops the candidates and the words not seen for their lifetime.
    /// Returns whether the set of accepted words changed.
    @discardableResult
    public mutating func expire(today: Int) -> Bool {
        var changed = false
        for (fingerprint, entry) in entries {
            let lifetime = entry.accepted ? options.wordLifetime : options.candidateLifetime
            guard today - entry.lastDay > lifetime else { continue }
            entries[fingerprint] = nil
            if entry.accepted {
                acceptedCount -= 1
                changed = true
            }
        }
        return changed
    }

    /// Forgets everything; batches counted before come in under the old
    /// generation and are dropped.
    public mutating func erase() {
        entries = [:]
        acceptedCount = 0
        generation &+= 1
    }

    /// What the tap gets: the accepted words, their starts and their
    /// languages under `key`.
    public func snapshot(key: PersonalKey) -> PersonalLexicon {
        var words: [UInt64] = []
        var starts: [UInt64] = []
        var languages: [LanguageCode] = []
        for (fingerprint, entry) in entries where entry.accepted {
            words.append(fingerprint)
            languages.append(entry.language)
            if let start3 = entry.start3 { starts.append(start3) }
            if let start4 = entry.start4 { starts.append(start4) }
        }
        return PersonalLexicon(key: key, words: words, starts: starts, languages: languages, generation: generation,
                               options: options)
    }
}
