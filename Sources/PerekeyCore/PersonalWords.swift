// SPDX-License-Identifier: GPL-3.0-or-later

/// The personal lexicon in the classifier (docs/classifier.md, «Личный
/// словарь»): a word the user keeps typing reads as a known form, and the
/// words that may become such words are picked here. No allocation: the
/// readings go into stack buffers, as `judgeWord`'s do.
extension Classifier {
    /// Marks a reading the model does not know as personal when `personal`
    /// has it: its rank becomes `Options.personalRank`. Only a word of
    /// letters, as long as the lexicon keeps; an empty lexicon computes no
    /// fingerprint.
    /// - Parameter scalars: the buffer `reading` was read into.
    func markPersonal(_ reading: inout Reading, language: String, scalars: Slice<UnsafeMutableBufferPointer<UInt32>>,
                      _ personal: PersonalLexicon)
    {
        guard personal.hasWords, let key = personal.key, reading.isWord, reading.digits == 0,
              reading.letters >= personal.minLetters, reading.letters <= personal.maxLetters, !isKnown(reading)
        else { return }
        let buffer = UnsafeMutableBufferPointer(rebasing: scalars)
        let core = UnsafeBufferPointer(rebasing: buffer[reading.coreStart..<reading.coreEnd])
        guard personal.containsWord(key.fingerprint(.word, language: language, core)) else { return }
        reading.personal = true
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
        guard personal.hasWords, let key = personal.key, let code = layout.language,
              let language = model.language(code)
        else { return false }
        return withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 4) { start in
            var letters = 0
            for stroke in strokes {
                guard letters < 4, let text = layout.text(for: stroke) else { return false }
                var scalars = text.unicodeScalars.makeIterator()
                guard let scalar = scalars.next()?.value, scalars.next() == nil, scalar < 0x30 || scalar > 0x39,
                      language.symbol(scalar) >= 2
                else { return false }
                start[letters] = scalar
                letters += 1
            }
            guard letters == 3 || letters == 4 else { return false }
            return personal.containsStart(key.fingerprint(letters == 3 ? .start3 : .start4, language: code,
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
    /// - without a rival: no reading in `rivals` (the layouts it could have
    ///   gone to, or came from) is a known form. "ghbdtn" kept by oversight
    ///   has "привет" for a rival and never becomes a word;
    /// - no typo the corrector would fix, whether typo correction is on or
    ///   not (`corrector`): a habitual "превет" stays a typo.
    ///
    /// The caller decides the rest: the word was kept by a `.keep` decision
    /// (never `.unsure`) or switched there and the switch stood, nothing
    /// else corrected it, automatic switching could act there. Nil when
    /// `personal` is off.
    public func personalObservation(_ strokes: some Collection<KeyStroke>, in result: LayoutMap,
                                    rivals: some Collection<LayoutMap>, personal: PersonalLexicon,
                                    corrector: TypoCorrector?, sentenceStart: Bool) -> PersonalObservation?
    {
        guard let key = personal.key, let code = result.language, let language = model.language(code) else {
            return nil
        }
        let count = Self.wordLength(strokes)
        let found: PersonalObservation? = withUnsafeTemporaryAllocation(of: UInt32.self, capacity: Self.maxScalars) {
            scalars in
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: Self.maxScalars) { symbols in
                guard let reading = Reading(strokes, count: count, in: result, language: language,
                                            scalars: scalars[...], symbols: symbols[...], measuring: false),
                      reading.isWord, reading.digits == 0, reading.upperInside == 0, !reading.isPasswordLike,
                      reading.letters >= personal.minLetters, reading.letters <= personal.maxLetters,
                      reading.coreEnd - reading.coreStart == reading.letters,
                      !isKnown(reading), !model.isKept(reading.exactFingerprint)
                else { return nil }
                let core = UnsafeBufferPointer(rebasing: scalars[reading.coreStart..<reading.coreEnd])
                return PersonalObservation(
                    word: key.fingerprint(.word, language: code, core),
                    start3: key.fingerprint(.start3, language: code, core.prefix(3)),
                    start4: reading.letters >= 4 ? key.fingerprint(.start4, language: code, core.prefix(4)) : nil,
                    language: code
                )
            }
        }
        guard let found else { return nil }
        for rival in rivals where rival.language != code {
            if isKnownForm(strokes, count: count, in: rival) { return nil }
        }
        if corrector?.correct(strokes, in: result, sentenceStart: sentenceStart) != nil { return nil }
        return found
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
