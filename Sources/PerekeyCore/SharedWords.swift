// SPDX-License-Identifier: GPL-3.0-or-later

/// The words other settings of the app name as the user's own, taken into the
/// personal lexicon as accepted from the start: the right side of the voice
/// dictionary («перекей» → «Perekey», docs/classifier.md, «Общие слова»). They
/// are never counted and never written to `lexicon.json`: the store adds their
/// fingerprints to the snapshot it publishes (`PersonalLexiconModel.snapshot`),
/// so a word leaves the snapshot the moment its source does.
extension PersonalKey {
    /// The languages of the model that have words in each script. A word has
    /// no language of its own, and the fingerprint has one
    /// (`fingerprint(_:language:_:)`): the word is put in under all the
    /// languages its letters can be typed in, the layouts the user has or not.
    /// Latin is English alone: the model has no other Latin language.
    static func languages(ofScript scalar: UInt32) -> [LanguageCode] {
        switch scalar {
        case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F: ["en"]
        case 0x400...0x52F: ["ru", "uk", "be", "kk"]
        default: []
        }
    }

    /// How the record of a word is told from another, apart from the key: its
    /// core, folded as the fingerprint folds it, with no language (a Cyrillic
    /// word is put in under four). «Артём» and «артем» are one word.
    public static func sharedIdentity(ofWord text: String) -> String {
        identity(of: text.unicodeScalars.filter { $0.properties.isAlphabetic }.map(\.value))
    }

    /// The identities (`sharedIdentity(ofWord:)`) of the words `texts` hold, in
    /// the order and number `sharedObservations` takes them, with no key.
    public static func sharedIdentities(of texts: some Sequence<String>,
                                        options: PersonalOptions = PersonalOptions()) -> Set<String>
    {
        Set(sharedCores(of: texts, options: options).map(\.identity))
    }

    private static func identity(of core: [UInt32]) -> String {
        var folded = String.UnicodeScalarView()
        for scalar in core { folded.append(Unicode.Scalar(spelling(scalar)) ?? "?") }
        return String(folded)
    }

    /// A text counts as a word only when it is one: a record of several words
    /// («Ministry of Health») is a phrase, not a word of the user's, and is left
    /// out. The piece counts when it is a word the classifier could ever read as
    /// one: letters of a single script (Latin, or Cyrillic; the letters of any
    /// other script are left out without a word), between `options.minLetters`
    /// and `options.maxLetters` of them, with no digit and no mark inside; marks
    /// around it are cut (`Reading.coreStart`). A word listed twice is one.
    /// No more than `options.maxWords` words are taken, the first ones of
    /// `texts` in the order they come, so the snapshot has a limit of its own
    /// kind, like the words the user taught.
    private static func sharedCores(of texts: some Sequence<String>,
                                    options: PersonalOptions) -> [(identity: String, core: [UInt32])]
    {
        var found: [(identity: String, core: [UInt32])] = []
        var seen: Set<String> = []
        for text in texts {
            guard found.count < options.maxWords else { break }
            let pieces = text.split(whereSeparator: \.isWhitespace)
            guard pieces.count == 1 else { continue }
            let scalars = Array(pieces[0].unicodeScalars)
            guard let first = scalars.firstIndex(where: { $0.properties.isAlphabetic }),
                  let last = scalars.lastIndex(where: { $0.properties.isAlphabetic }),
                  !scalars[..<first].contains(where: { $0.properties.numericType != nil }),
                  !scalars[(last + 1)...].contains(where: { $0.properties.numericType != nil })
            else { continue }
            let core = scalars[first...last].map(\.value)
            guard core.count >= options.minLetters, core.count <= options.maxLetters,
                  scalars[first...last].allSatisfy({ $0.properties.isAlphabetic })
            else { continue }
            let languages = Self.languages(ofScript: core[0])
            guard !languages.isEmpty, core.allSatisfy({ Self.languages(ofScript: $0) == languages }) else { continue }
            let id = identity(of: core)
            if seen.insert(id).inserted { found.append((id, core)) }
        }
        return found
    }

    /// The observations that stand for `texts` in the lexicon: for each word
    /// (`sharedCores`), its fingerprints and the fingerprints of its starts, one
    /// observation per language. The same key, the same domains and the same
    /// spelling as a word the user typed (`Classifier.personalObservation`),
    /// so «Perekey» and «perekey» are one word, and so are «Артём» and «артем».
    /// The words whose identity is in `suppressing` are left out.
    public func sharedObservations(of texts: some Sequence<String>,
                                   options: PersonalOptions = PersonalOptions(),
                                   suppressing: Set<String> = []) -> [PersonalObservation]
    {
        var found: [PersonalObservation] = []
        for (identity, core) in Self.sharedCores(of: texts, options: options) where !suppressing.contains(identity) {
            for language in Self.languages(ofScript: core[0]) {
                found.append(PersonalObservation(
                    word: fingerprint(.word, language: language, core),
                    start3: fingerprint(.start3, language: language, core.prefix(Self.shortStart)),
                    start4: core.count >= Self.longStart
                        ? fingerprint(.start4, language: language, core.prefix(Self.longStart)) : nil,
                    language: language))
            }
        }
        return found
    }
}
