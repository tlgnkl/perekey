// SPDX-License-Identifier: GPL-3.0-or-later

/// The personal lexicon in the classifier (docs/classifier.md, «Личный
/// словарь»): a word the user keeps typing reads as a known form, and the
/// words that may become such words are picked here. No allocation: the
/// readings go into stack buffers, as `judgeWord`'s do.
/// What the typo corrector needs to say whether it would fix a word
/// (condition 6): the same inputs `WordJudge.correctWord` gives it.
public struct TypoCheck {
    public var corrector: TypoCorrector
    public var sentenceStart: Bool
    /// The fingerprint of the word before (`TypoCorrector.correct(previous:)`).
    public var previous: UInt64?
    public var realWords: Bool

    public init(corrector: TypoCorrector, sentenceStart: Bool, previous: UInt64? = nil, realWords: Bool = false) {
        self.corrector = corrector
        self.sentenceStart = sentenceStart
        self.previous = previous
        self.realWords = realWords
    }
}

extension Classifier {
    /// Marks a reading the model does not know as personal when `personal`
    /// has it: its rank becomes `Options.personalRank`. Only a word of
    /// letters, as long as the lexicon keeps, in a language the lexicon has
    /// words in, and not costlier than a candidate may be; an empty lexicon
    /// computes no fingerprint, and the cheap checks come before the hash.
    /// - Parameter scalars: the buffer `reading` was read into.
    func markPersonal(_ reading: inout Reading, language: String, scalars: Slice<UnsafeMutableBufferPointer<UInt32>>,
                      _ personal: PersonalLexicon)
    {
        guard personal.hasWords, reading.isWord, reading.digits == 0, reading.letters >= personal.minLetters,
              reading.letters <= personal.maxLetters, !isKnown(reading), let key = personal.key,
              // A word costs no more than the limit to become a candidate
              // (`personalObservation`): a reading above it, the wrong
              // layout's gibberish for one, is no word of the lexicon.
              !reading.measured || reading.cost / Double(reading.letters + 1) <= options.personalNoiseCost,
              let code = LanguageCode(language), personal.mayHold(code)
        else { return }
        let buffer = UnsafeMutableBufferPointer(rebasing: scalars)
        let core = UnsafeBufferPointer(rebasing: buffer[reading.coreStart..<reading.coreEnd])
        let fingerprint = key.fingerprint(.word, language: code, core)
        guard personal.containsWord(fingerprint) else { return }
        reading.personal = true
        reading.personalFingerprint = fingerprint
        reading.rank = options.personalRank
    }

    /// Whether the strokes read in `layout` are a word of `personal` the
    /// model does not know. The word corrections leave such a word alone
    /// (`WordJudge.correctWord`), and `perekey-eval` does as they do.
    public func isPersonal(_ strokes: some Collection<KeyStroke>, in layout: LayoutMap,
                           personal: PersonalLexicon) -> Bool
    {
        guard personal.hasWords, let code = layout.language, let language = model.language(code) else { return false }
        let count = Self.wordLength(strokes)
        return withUnsafeTemporaryAllocation(of: UInt32.self, capacity: Self.maxScalars) { scalars in
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: Self.maxScalars) { symbols in
                // `measuring: false`: only the word's letters are read, as the
                // personal lookup needs them; the n-gram cost is the
                // classifier's own question and is not asked here.
                guard var reading = Reading(strokes, count: count, in: layout, language: language,
                                            scalars: scalars[...], symbols: symbols[...], measuring: false)
                else { return false }
                markPersonal(&reading, language: code, scalars: scalars[...], personal)
                return reading.personal
            }
        }
    }

    /// Whether the 3 or 4 strokes so far, read in `layout`, start a word
    /// of `personal`: a switch inside the word must wait for its end
    /// (`WordJudge.insideWord`). Only letters of the language, from the first
    /// key; no reading of the word, so asking it on every early switch costs
    /// a key lookup and a hash.
    public func startsPersonalWord(_ strokes: some Collection<KeyStroke>, in layout: LayoutMap,
                                   personal: PersonalLexicon) -> Bool
    {
        guard personal.hasWords, let key = personal.key, let name = layout.language, let code = LanguageCode(name),
              personal.mayHold(code), let language = model.language(name)
        else { return false }
        return withUnsafeTemporaryAllocation(of: UInt32.self, capacity: PersonalKey.longStart) { start in
            var letters = 0
            for stroke in strokes {
                guard letters < PersonalKey.longStart, let text = layout.text(for: stroke) else { return false }
                var scalars = text.unicodeScalars.makeIterator()
                guard let scalar = scalars.next()?.value, scalars.next() == nil, !Reading.isDigit(scalar),
                      language.symbol(scalar) >= 2
                else { return false }
                start[letters] = scalar
                letters += 1
            }
            guard letters == PersonalKey.shortStart || letters == PersonalKey.longStart else { return false }
            let domain: PersonalKey.Domain = letters == PersonalKey.shortStart ? .start3 : .start4
            return personal.containsStart(key.fingerprint(domain, language: code,
                                                          UnsafeBufferPointer(rebasing: start[0..<letters])))
        }
    }

    /// Whether the word is a known form of the model by its exact keys,
    /// without a reading: the cheap answer for the common word. False for a
    /// word with marks around it, which a reading has to strip.
    func isPlainlyKnown(_ strokes: some Collection<KeyStroke>, in layout: LayoutMap) -> Bool {
        guard let code = layout.language, let language = model.language(code) else { return false }
        var fingerprint = ModelFormat.Fingerprint()
        for stroke in strokes where stroke.keyCode != KeyCode.space {
            guard let text = layout.text(for: stroke) else { return false }
            for scalar in text.unicodeScalars { fingerprint.add(ModelFormat.fold(scalar.value)) }
        }
        guard let rank = language.rank(of: fingerprint.value) else { return false }
        return rank == 0 || rank >= options.knownRank
    }

    /// What the personal lexicon may learn from a word kept as it reads in
    /// `result`, or nil when the word is no candidate. The word must be
    /// (docs/classifier.md, «Личный словарь», conditions 3–6):
    /// - a word of letters, `PersonalOptions.minLetters` to `maxLetters`
    ///   long, without digits, without a capital inside, not like a
    ///   password, not on the model's never-switch list;
    /// - unknown to the model (not `isKnown`): a known word needs no lexicon;
    /// - no random string: its n-gram cost per letter is at most
    ///   `Options.personalNoiseCost`;
    /// - without a rival: no reading in `rivals` (the layouts it could have
    ///   gone to, or came from) is a known form. "ghbdtn" kept by oversight
    ///   has "привет" for a rival and never becomes a word;
    /// - no typo the corrector would fix, whether typo correction is on or
    ///   not (`typo`), asked as `WordJudge.correctWord` asks: a habitual
    ///   "превет" stays a typo.
    ///
    /// The cheap checks come first, then the rival, the corrector and, last,
    /// the hashes: the word the model knows (the common one) costs one
    /// reading. The caller decides the rest: the word was kept by a `.keep`
    /// decision (never `.unsure`) or switched there and the switch stood,
    /// nothing else corrected it, automatic switching could act there. Nil
    /// when `personal` is off.
    /// - Parameters:
    ///   - typo: the corrector and what it is asked with; nil asks none.
    ///   - known: the fingerprint of the word when the classifier found it in
    ///     `personal` already (`Decision.typedPersonalWord`): the word is
    ///     accepted, so its rival, its noise and its typo were looked at, and
    ///     the observation is only its count. No hash, no rival, no corrector;
    ///     its starts are in the snapshot, so they are left out.
    public func personalObservation(_ strokes: some Collection<KeyStroke>, in result: LayoutMap,
                                    rivals: some Collection<LayoutMap>, personal: PersonalLexicon,
                                    typo: TypoCheck?, known: UInt64? = nil) -> PersonalObservation?
    {
        guard let key = personal.key, let name = result.language, let code = LanguageCode(name),
              let language = model.language(name)
        else { return nil }
        let count = Self.wordLength(strokes)
        return withUnsafeTemporaryAllocation(of: UInt32.self, capacity: Self.maxScalars) { scalars in
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: Self.maxScalars) { symbols in
                guard let reading = Reading(strokes, count: count, in: result, language: language,
                                            scalars: scalars[...], symbols: symbols[...], measuring: false),
                      reading.isWord, reading.digits == 0, reading.upperInside == 0, !reading.isPasswordLike,
                      reading.letters >= personal.minLetters, reading.letters <= personal.maxLetters,
                      reading.coreEnd - reading.coreStart == reading.letters,
                      !isKnown(reading), !model.isKept(reading.exactFingerprint)
                else { return nil }
                if let known {
                    return PersonalObservation(word: known, start3: nil, start4: nil, language: code)
                }
                let cost = Self.cost(of: UnsafeBufferPointer(rebasing: symbols[0..<reading.letters]), in: language)
                guard cost / Double(reading.letters + 1) <= options.personalNoiseCost else { return nil }
                for rival in rivals where rival.language != name {
                    if isKnownForm(strokes, count: count, in: rival) { return nil }
                }
                if let typo,
                   typo.corrector.correct(strokes, in: result, sentenceStart: typo.sentenceStart,
                                          previous: typo.previous, realWords: typo.realWords) != nil
                {
                    return nil
                }
                let core = UnsafeBufferPointer(rebasing: scalars[reading.coreStart..<reading.coreEnd])
                return PersonalObservation(
                    word: key.fingerprint(.word, language: code, core),
                    start3: key.fingerprint(.start3, language: code, core.prefix(PersonalKey.shortStart)),
                    start4: reading.letters >= PersonalKey.longStart
                        ? key.fingerprint(.start4, language: code, core.prefix(PersonalKey.longStart)) : nil,
                    language: code
                )
            }
        }
    }

    /// The n-gram cost of a word's letters in bits, as `Reading` measures it:
    /// each part between hyphens on its own.
    private static func cost(of symbols: UnsafeBufferPointer<UInt8>, in language: LanguageModel.Language) -> Double {
        let hyphen = language.symbol(Reading.hyphen)
        var cost = 0.0
        var start = 0
        for position in 0...symbols.count where position == symbols.count || symbols[position] == hyphen {
            if position > start { cost += language.cost(UnsafeBufferPointer(rebasing: symbols[start..<position])) }
            start = position + 1
        }
        return cost
    }

    /// The strokes read in `layout` are a known form of its language, by
    /// the model alone.
    private func isKnownForm(_ strokes: some Collection<KeyStroke>, count: Int, in layout: LayoutMap) -> Bool {
        guard let code = layout.language, let language = model.language(code) else { return false }
        return withUnsafeTemporaryAllocation(of: UInt32.self, capacity: Self.maxScalars) { scalars in
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: Self.maxScalars) { symbols in
                guard let reading = Reading(strokes, count: count, in: layout, language: language,
                                            scalars: scalars[...], symbols: symbols[...], measuring: false)
                else { return false }
                return reading.isWord && isKnown(reading)
            }
        }
    }
}
