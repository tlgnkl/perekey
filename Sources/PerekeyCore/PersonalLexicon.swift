// SPDX-License-Identifier: GPL-3.0-or-later

/// The key of the personal lexicon: 16 random bytes the app keeps in the
/// Keychain. With the key a fingerprint can be checked against a guessed
/// word; without it the fingerprints say nothing (docs/classifier.md,
/// «Личный словарь»).
public struct PersonalKey: Hashable, Sendable {
    /// The first and the last eight bytes, little-endian, as SipHash takes them.
    public var k0: UInt64
    public var k1: UInt64

    public init(k0: UInt64, k1: UInt64) {
        self.k0 = k0
        self.k1 = k1
    }

    /// The key of 16 bytes; nil for any other length.
    public init?(bytes: some Collection<UInt8>) {
        guard bytes.count == 16 else { return nil }
        var k0: UInt64 = 0
        var k1: UInt64 = 0
        for (index, byte) in bytes.enumerated() {
            if index < 8 {
                k0 |= UInt64(byte) << (8 * UInt64(index))
            } else {
                k1 |= UInt64(byte) << (8 * UInt64(index - 8))
            }
        }
        self.init(k0: k0, k1: k1)
    }

    /// What a fingerprint stands for: the hash input starts with it, so a
    /// word and the start of another one never share a fingerprint.
    public enum Domain: UInt8, Sendable {
        case word = 1
        /// The first three letters of a word.
        case start3 = 3
        /// The first four.
        case start4 = 4
    }

    /// The fingerprint of `scalars` under the key: SipHash-2-4 of the domain
    /// byte, the language code in UTF-8, a 0 byte, then each scalar as
    /// four bytes little-endian, folded as the model folds it
    /// (`ModelFormat.fold`) and with "ё" as "е" (`WordRules.matchKey`):
    /// one spelling for the word kept and the word looked up, "артём" and
    /// "артем" alike.
    public func fingerprint(_ domain: Domain, language: String, _ scalars: some Sequence<UInt32>) -> UInt64 {
        var hasher = SipHash24(key: self)
        hasher.append(domain.rawValue)
        for byte in language.utf8 { hasher.append(byte) }
        hasher.append(0)
        for scalar in scalars {
            hasher.append(littleEndian: Self.spelling(scalar))
        }
        return hasher.finalize()
    }

    /// The fingerprints of a word as the main thread knows it: the text of
    /// its core, without quotes or marks around it. "Забыть" in the hint and
    /// the signals that drop a word find it by this (`PersonalLexiconModel.forget`).
    public func fingerprint(ofWord text: String, language: String) -> UInt64 {
        fingerprint(.word, language: language, text.unicodeScalars.lazy.map(\.value))
    }

    /// A scalar as the fingerprint takes it: folded, "ё" as "е".
    @inline(__always)
    static func spelling(_ scalar: UInt32) -> UInt32 {
        let folded = ModelFormat.fold(scalar)
        return folded == 0x451 ? 0x435 : folded
    }
}

/// What the personal lexicon learns from one word the user typed and kept:
/// its keyed fingerprints and its language, never its text.
public struct PersonalObservation: Hashable, Sendable {
    /// The fingerprint of the word (`PersonalKey.Domain.word`).
    public var word: UInt64
    /// The fingerprints of its first three and four letters; `start4` is
    /// nil for a word of three.
    public var start3: UInt64
    public var start4: UInt64?
    /// The language of the layout it was read in, e.g. "ru".
    public var language: String

    public init(word: UInt64, start3: UInt64, start4: UInt64?, language: String) {
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
public struct PersonalLexicon: Hashable, Sendable {
    final class Storage: Sendable {
        let key: PersonalKey
        let words: [UInt64]
        let starts: [UInt64]
        let generation: UInt32
        let minLetters: Int
        let maxLetters: Int

        init(key: PersonalKey, words: [UInt64], starts: [UInt64], generation: UInt32, minLetters: Int,
             maxLetters: Int)
        {
            self.key = key
            self.words = words
            self.starts = starts
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
    ///   - generation: the store's count of erases (`PersonalLexiconModel.generation`).
    public init(key: PersonalKey, words: some Sequence<UInt64>, starts: some Sequence<UInt64>, generation: UInt32 = 0,
                options: PersonalOptions = PersonalOptions())
    {
        storage = Storage(key: key, words: Self.sorted(words), starts: Self.sorted(starts), generation: generation,
                          minLetters: options.minLetters, maxLetters: options.maxLetters)
    }

    private static func sorted(_ values: some Sequence<UInt64>) -> [UInt64] {
        var array = Array(values)
        array.sort()
        var unique: [UInt64] = []
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
                    && left.maxLetters == right.maxLetters && left.words == right.words && left.starts == right.starts)
        default: return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(generation)
        hasher.combine(wordCount)
    }
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
        public var language: String
        public var start3: UInt64
        public var start4: UInt64?
        /// Confirmed observations.
        public var count: Int
        /// Different days among them.
        public var days: Int
        /// The day it was last seen, as the store counts days.
        public var lastDay: Int
        public var accepted: Bool

        public init(language: String, start3: UInt64, start4: UInt64?, count: Int, days: Int, lastDay: Int,
                    accepted: Bool)
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
                acceptedCount += 1
                changed = true
            }
            entries[observation.word] = entry
        } else {
            if candidateCount >= options.maxCandidates, let oldest = oldest(accepted: false) {
                entries[oldest] = nil
            }
            entries[observation.word] = Entry(language: observation.language, start3: observation.start3,
                                              start4: observation.start4, count: 1, days: 1, lastDay: day,
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

    /// What the tap gets: the accepted words and their starts under `key`.
    public func snapshot(key: PersonalKey) -> PersonalLexicon {
        var words: [UInt64] = []
        var starts: [UInt64] = []
        for (fingerprint, entry) in entries where entry.accepted {
            words.append(fingerprint)
            starts.append(entry.start3)
            if let start4 = entry.start4 { starts.append(start4) }
        }
        return PersonalLexicon(key: key, words: words, starts: starts, generation: generation, options: options)
    }
}
