// SPDX-License-Identifier: GPL-3.0-or-later

/// Decides whether a word was typed in the wrong layout.
///
/// The word is key strokes, read twice: as the layout that was active types
/// them and as the other layout would. Each reading gets a cost in bits from
/// its language's character n-grams, minus a bonus when it is a known word
/// form. The reading with the lower cost wins when it wins by enough.
///
/// Rules before the comparison (docs/classifier.md): digits, code, URLs,
/// password-like and random strings are never switched. No allocation on the
/// hot path: two readings of 64 strokes take microseconds.
public struct Classifier: Sendable {
    public struct Options: Hashable, Sendable {
        /// Bits the other reading must win by. The default comes from the ROC
        /// sweep of `perekey-eval`.
        public var threshold: Double = 10
        /// Extra bits the other reading must win by when it is not a known
        /// form: a rare form or a name, but also a random string.
        public var unknownWordExtra: Double = 6
        /// Bits per letter above which a reading is noise unless it is a word form.
        public var noiseCost: Double = 7
        /// The same bound for a reading that must carry a switch on its own,
        /// without the dictionary.
        public var unknownNoiseCost: Double = 5
        /// Bits for each leading quote or bracket of the typed reading that
        /// is a letter in the other: "'nj" starts with "э".
        public var openerBonus: Double = 3
        /// Bonus of a known word form: `dictionaryBonus` bits plus `rankBonus`
        /// per unit of Zipf frequency (`rank / 32`) above 1.5, so the junk at
        /// the bottom of the frequency lists earns almost nothing. A form
        /// without a frequency (rank 0) counts as Zipf 2.5.
        public var dictionaryBonus: Double = 1
        public var rankBonus: Double = 2.5
        /// Below this rank (Zipf 2.5) a frequency-list token is not a known
        /// form: it does not lower the margin for a switch.
        public var knownRank: UInt8 = 80
        /// A capital inside a word (one, with small letters around) switches
        /// only to a form at least this frequent (Zipf 4): "НщгЕгиу" is
        /// "YouTube", "оФТУ" is noise. Two capitals inside never switch.
        public var mixedCaseRank: UInt8 = 128
        /// Bits in favour of the language of the previous word.
        public var contextBonus: Double = 3
        /// A 1–2 letter word switches only to a form at least this frequent
        /// (160 is Zipf 5: "а", "и", "в", "a", "i"), never after a word in its
        /// own language, after a word in the other language if the typed
        /// reading is rarer, and without context only if it is rarer by a
        /// unit of Zipf.
        public var shortWordRank: UInt8 = 160

        public init() {}
    }

    public enum Mode: Hashable, Sendable {
        /// Perekey decides on its own: every guard applies.
        case automatic
        /// The user asked which reading is right: compare, guards off.
        case manual
    }

    public struct Context: Hashable, Sendable {
        /// The language the previous word was judged to be in, e.g. "ru".
        public var previousLanguage: String?
        public var mode: Mode

        public init(previousLanguage: String? = nil, mode: Mode = .automatic) {
            self.previousLanguage = previousLanguage
            self.mode = mode
        }
    }

    public enum Verdict: Hashable, Sendable {
        case keep
        case `switch`(to: LayoutID)
        /// The other reading looks better, but not by enough.
        case unsure
    }

    public enum Reason: Hashable, Sendable, CaseIterable {
        case empty
        /// Languages unknown to the model, or the same language in both layouts.
        case unsupported
        /// Longer than a word can be.
        case tooLong
        case digits
        /// On the never-switch list: "iPhone", "Wi-Fi", "ГОСТ".
        case kept
        case passwordLike
        /// Neither reading is a word: code, URL, path, e-mail, symbols.
        case codeLike
        /// Neither reading is probable and neither is a known form: captcha.
        case noise
        /// Capitals inside the word and no frequent form to switch to: "taToG".
        case mixedCase
        /// The other reading is unknown and the typed one reads fine in its
        /// own language: nothing says it is wrong.
        case bothPlausible
        /// A 1–2 letter word, decided by the dictionary alone.
        case shortWord
        /// Decided by the costs: `score` says how.
        case compared
    }

    /// What a reading is worth as a word of its language, for explaining a
    /// decision (`Explanation`).
    public enum Form: Hashable, Sendable {
        /// Symbols, digits or no letters: no word to measure.
        case notWord
        /// Shaped like a word, but not in the dictionary.
        case unknown
        /// In the dictionary, rarely.
        case rare
        /// A frequent word, or a known form.
        case known
    }

    public struct Decision: Hashable, Sendable {
        public var verdict: Verdict
        /// Bits in favour of the other reading; `-infinity` when it is no word.
        public var score: Double
        public var reason: Reason
        /// The language the word is in, if the classifier is sure.
        public var language: String?
        /// The score the switch needed: the threshold, raised for an unknown
        /// other reading. Set by every judgement of two readings.
        public var margin: Double = 0
        /// What the typed reading and the other one are as words.
        public var typedForm = Form.notWord
        public var otherForm = Form.notWord
        /// The languages of the two layouts, e.g. "en" and "ru".
        public var typedLanguage: String?
        public var otherLanguage: String?
    }

    /// A word longer than this is no word.
    public static let maxScalars = 128

    public let model: LanguageModel
    public var options: Options

    public init(model: LanguageModel, options: Options = Options()) {
        self.model = model
        self.options = options
    }

    /// Judges a word. Trailing spaces are ignored.
    /// - Parameters:
    ///   - typed: the layout that was active while typing.
    ///   - other: the layout the word may have been meant for.
    public func classify(_ strokes: some Collection<KeyStroke>, typed: LayoutMap, other: LayoutMap,
                         context: Context = Context()) -> Decision
    {
        let count = Self.wordLength(strokes)
        guard count > 0 else { return Decision(verdict: .keep, score: 0, reason: .empty, language: nil) }
        guard let typedCode = typed.language, let otherCode = other.language, typedCode != otherCode,
              let typedLanguage = model.language(typedCode), let otherLanguage = model.language(otherCode)
        else { return Decision(verdict: .keep, score: 0, reason: .unsupported, language: nil) }

        return withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 2 * Self.maxScalars) { scalars in
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 2 * Self.maxScalars) { symbols in
                let half = Self.maxScalars
                guard let typedReading = Reading(strokes, count: count, in: typed, language: typedLanguage,
                                                 scalars: scalars[0..<half], symbols: symbols[0..<half]),
                      let otherReading = Reading(strokes, count: count, in: other, language: otherLanguage,
                                                 scalars: scalars[half...], symbols: symbols[half...])
                else { return Decision(verdict: .keep, score: 0, reason: .tooLong, language: nil) }
                return decide(typedReading, otherReading, typed: typed, other: other, context: context)
            }
        }
    }

    /// Whether the word so far cannot start a word in the active layout's
    /// language, but can in the other's: "ghb" is no English start, "при" is a
    /// Russian one. Cheap enough for every key stroke; needs 3 or 4 letters.
    public func impossiblePrefix(_ strokes: some Collection<KeyStroke>, typed: LayoutMap, other: LayoutMap) -> Bool {
        let count = Self.wordLength(strokes)
        guard count >= 3, let typedCode = typed.language, let otherCode = other.language, typedCode != otherCode,
              let typedLanguage = model.language(typedCode), let otherLanguage = model.language(otherCode)
        else { return false }
        return withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 2 * Self.maxScalars) { scalars in
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 2 * Self.maxScalars) { symbols in
                let half = Self.maxScalars
                guard let typedReading = Reading(strokes, count: count, in: typed, language: typedLanguage,
                                                 scalars: scalars[0..<half], symbols: symbols[0..<half]),
                      let otherReading = Reading(strokes, count: count, in: other, language: otherLanguage,
                                                 scalars: scalars[half...], symbols: symbols[half...]),
                      typedReading.isWord, otherReading.isWord,
                      typedReading.coreStart == 0, typedReading.letters == typedReading.count,
                      otherReading.coreStart == 0, otherReading.letters == otherReading.count,
                      typedReading.upperInside == 0
                else { return false }
                let length = min(4, typedReading.letters)
                let typedPrefix = UnsafeBufferPointer(rebasing: symbols[0..<length])
                let otherPrefix = UnsafeBufferPointer(rebasing: symbols[half..<half + length])
                return !typedLanguage.isPossiblePrefix(typedPrefix) && otherLanguage.isPossiblePrefix(otherPrefix)
            }
        }
    }

    /// Strokes up to the last one that is not a space.
    private static func wordLength(_ strokes: some Collection<KeyStroke>) -> Int {
        var length = 0
        var index = 0
        for stroke in strokes {
            index += 1
            if stroke.keyCode != KeyCode.space { length = index }
        }
        return length
    }

    private func decide(_ typed: Reading, _ other: Reading, typed typedLayout: LayoutMap, other otherLayout: LayoutMap,
                        context: Context) -> Decision
    {
        var decision = compare(typed, other, typed: typedLayout, other: otherLayout, context: context)
        decision.margin = isKnown(other) ? options.threshold : options.threshold + options.unknownWordExtra
        decision.typedForm = form(of: typed)
        decision.otherForm = form(of: other)
        decision.typedLanguage = typedLayout.language
        decision.otherLanguage = otherLayout.language
        return decision
    }

    private func form(of reading: Reading) -> Form {
        guard reading.isWord else { return .notWord }
        if isKnown(reading) { return .known }
        return reading.rank == nil ? .unknown : .rare
    }

    private func compare(_ typed: Reading, _ other: Reading, typed typedLayout: LayoutMap, other otherLayout: LayoutMap,
                         context: Context) -> Decision
    {
        let typedCode = typedLayout.language
        let otherCode = otherLayout.language
        let automatic = context.mode == .automatic

        if automatic, typed.digits > 0 || other.digits > 0 {
            return Decision(verdict: .keep, score: 0, reason: .digits, language: nil)
        }
        if automatic, model.isKept(typed.exactFingerprint) {
            return Decision(verdict: .keep, score: 0, reason: .kept, language: nil)
        }
        // Both readings must look like a password: a closing quote typed in
        // the wrong layout reads as a capital in the other ("water?\"" is "цфеук?Э").
        if automatic, typed.isPasswordLike, other.isPasswordLike {
            return Decision(verdict: .keep, score: 0, reason: .passwordLike, language: nil)
        }
        guard other.isWord else {
            // The other reading is no word, so there is nothing to switch to.
            let language = typed.isWord && plausible(typed) ? typedCode : nil
            return Decision(verdict: .keep, score: -.infinity, reason: typed.isWord ? .compared : .codeLike,
                            language: language)
        }

        // Costs in bits. A typed reading that is no word costs as much as noise.
        let typedCost = typed.isWord ? typed.cost - bonus(typed) : Double(typed.count) * options.noiseCost
        let otherCost = other.cost - bonus(other)
        var score = typedCost - otherCost
        score += options.openerBonus * Double(typed.openers - other.openers)
        if let previous = context.previousLanguage {
            if previous == otherCode { score += options.contextBonus }
            if previous == typedCode { score -= options.contextBonus }
        }

        guard automatic else {
            let wins = !typed.isWord || score > 0
            return Decision(verdict: wins ? .switch(to: otherLayout.id) : .keep, score: score, reason: .compared,
                            language: wins ? otherCode : typedCode)
        }

        guard plausible(other, carries: true) else {
            let typedPlausible = typed.isWord && plausible(typed)
            return Decision(verdict: .keep, score: score, reason: typedPlausible ? .compared : .noise,
                            language: typedPlausible ? typedCode : nil)
        }
        let known = isKnown(other)
        let margin = known ? options.threshold : options.threshold + options.unknownWordExtra
        if other.letters <= 2 {
            // Too short for the n-grams: the dictionary and the context decide.
            // The typed reading may carry a symbol ("t`" is "её") but must
            // have a letter: "{" is no reason to type "х".
            let frequent = (other.rank ?? 0) >= options.shortWordRank
            let typedRank = typed.isWord ? (typed.rank ?? 0) : 0
            let wins: Bool
            if typed.letters == 0 || context.previousLanguage == typedCode {
                wins = false
            } else if context.previousLanguage == otherCode {
                wins = frequent && typedRank < (other.rank ?? 0)
            } else {
                wins = frequent && Int(typedRank) + 32 <= Int(other.rank ?? 0)
            }
            return Decision(verdict: wins ? .switch(to: otherLayout.id) : .keep, score: score, reason: .shortWord,
                            language: wins ? otherCode : (typed.isWord && plausible(typed) ? typedCode : nil))
        }
        if !typed.isWord {
            // "ghbdtn^" against "привет,": the typed reading has a symbol, so
            // the other one must carry the switch by itself.
            let wins = score >= margin
            return Decision(verdict: wins ? .switch(to: otherLayout.id) : .keep, score: score, reason: .compared,
                            language: wins ? otherCode : nil)
        }
        if typed.upperInside > 0, typed.lower > 0,
           typed.upperInside > 1 || (other.rank ?? 0) < options.mixedCaseRank
        {
            // Shift inside a word, and nothing frequent to switch to: a captcha,
            // a product name, an identifier.
            return Decision(verdict: .keep, score: score, reason: .mixedCase, language: nil)
        }
        if !known, typed.cost / Double(typed.letters + 1) < options.noiseCost {
            // Switching to an unknown word needs the typed reading to be noise
            // in its own language: "cokef" reads like English, so it stays.
            return Decision(verdict: .keep, score: score, reason: .bothPlausible, language: nil)
        }
        if score >= margin {
            return Decision(verdict: .switch(to: otherLayout.id), score: score, reason: .compared, language: otherCode)
        }
        if score > 0 {
            return Decision(verdict: .unsure, score: score, reason: .compared, language: nil)
        }
        return Decision(verdict: .keep, score: score, reason: .compared,
                        language: plausible(typed) ? typedCode : nil)
    }

    /// A known form, or cheap enough per letter not to be noise. A reading
    /// that `carries` a switch without the dictionary must be cheaper still
    /// and start like some word of the language.
    private func plausible(_ reading: Reading, carries: Bool = false) -> Bool {
        if isKnown(reading) { return true }
        let bound = carries ? options.unknownNoiseCost : options.noiseCost
        // Unknown and short: too little to go on.
        if carries, !reading.prefixPossible || reading.letters < 4 { return false }
        return reading.cost / Double(reading.letters + 1) <= bound
    }

    /// In the dictionary with a frequency worth the name, or a form without one.
    private func isKnown(_ reading: Reading) -> Bool {
        guard let rank = reading.rank else { return false }
        return rank == 0 || rank >= options.knownRank
    }

    private func bonus(_ reading: Reading) -> Double {
        guard let rank = reading.rank else { return 0 }
        let zipf = rank == 0 ? 2.5 : Double(rank) / 32
        return options.dictionaryBonus + options.rankBonus * max(0, zipf - 1.5)
    }
}

/// One reading of the strokes: the text a layout types for them, measured
/// against one language.
struct Reading {
    /// Scalars typed, wrappers included.
    var count = 0
    /// The word without wrapping quotes, brackets and trailing punctuation.
    var coreStart = 0
    var coreEnd = 0
    /// Letters and joiners of the language inside the core.
    var letters = 0
    /// Characters inside the core that are neither letters nor digits.
    var coreSymbols = 0
    /// Characters anywhere that are neither letters nor digits, wrappers included.
    var symbols = 0
    /// Quotes and brackets stripped from the start.
    var openers = 0
    var digits = 0
    var upper = 0
    var lower = 0
    /// Capitals after the first character of the core.
    var upperInside = 0
    /// Folded fingerprint of the core, for the dictionary.
    var fingerprint: UInt64 = 0
    /// Exact fingerprint of the core, for the never-switch list.
    var exactFingerprint: UInt64 = 0
    /// n-gram cost in bits; meaningful when `isWord`.
    var cost = 0.0
    var rank: UInt8?
    /// Whether some word of the language starts with its first 3–4 letters.
    var prefixPossible = true

    /// Only letters (and digits, which the automatic mode refuses earlier)
    /// inside the core: a word the model can measure.
    var isWord: Bool { letters > 0 && coreSymbols == 0 }

    /// Longer than 6, a capital after the first character, small letters and
    /// a symbol: the plan's rule for a password in an ordinary field. A
    /// capital only at the start is a sentence start, not a password.
    var isPasswordLike: Bool { count > 6 && upperInside > 0 && lower > 0 && symbols > 0 }

    /// Leading and trailing characters that wrap a word in text. A character
    /// that is a letter of the language (`[` is `х` in Russian) is not a wrapper.
    private static func isOpening(_ scalar: UInt32) -> Bool {
        switch scalar {
        case 0x22, 0x27, 0x28, 0x5B, 0x7B, 0xAB, 0x2018, 0x201C, 0x201E, 0x2039, 0xBF, 0xA1: true
        default: false
        }
    }

    private static func isClosing(_ scalar: UInt32) -> Bool {
        switch scalar {
        case 0x22, 0x27, 0x29, 0x5D, 0x7D, 0xBB, 0x2019, 0x201D, 0x203A, 0x2C, 0x2E, 0x3B, 0x3A, 0x21, 0x3F, 0x2026: true
        default: false
        }
    }

    /// Reads `count` strokes. `nil` when they type more scalars than fit.
    init?(_ strokes: some Collection<KeyStroke>, count: Int, in layout: LayoutMap, language: LanguageModel.Language,
          scalars: Slice<UnsafeMutableBufferPointer<UInt32>>, symbols: Slice<UnsafeMutableBufferPointer<UInt8>>)
    {
        let scalars = UnsafeMutableBufferPointer(rebasing: scalars)
        let symbols = UnsafeMutableBufferPointer(rebasing: symbols)
        var index = 0
        for stroke in strokes.prefix(count) {
            if let text = layout.text(for: stroke) {
                for scalar in text.unicodeScalars {
                    guard index < scalars.count else { return nil }
                    scalars[index] = scalar.value
                    index += 1
                }
            } else {
                // A dead key or a key that types nothing: not a letter.
                guard index < scalars.count else { return nil }
                scalars[index] = 0xFFFF
                index += 1
            }
        }
        self.count = index
        coreEnd = index
        // An apostrophe is a letter inside an English word ("don't") but a
        // quote at its edge ('verb').
        func isWrapper(_ scalar: UInt32, opening: Bool) -> Bool {
            guard opening ? Self.isOpening(scalar) : Self.isClosing(scalar) else { return false }
            return scalar == 0x27 || !language.isLetter(scalar)
        }
        while coreStart < coreEnd, isWrapper(scalars[coreStart], opening: true) {
            coreStart += 1
            self.symbols += 1
            openers += 1
        }
        while coreEnd > coreStart, isWrapper(scalars[coreEnd - 1], opening: false) {
            coreEnd -= 1
            self.symbols += 1
        }

        var folded = ModelFormat.Fingerprint()
        var exact = ModelFormat.Fingerprint()
        for position in coreStart..<coreEnd {
            let scalar = scalars[position]
            let foldedScalar = ModelFormat.fold(scalar)
            folded.add(foldedScalar)
            exact.add(scalar)
            if scalar >= 0x30, scalar <= 0x39 {
                digits += 1
                continue
            }
            let symbol = language.symbol(scalar)
            if symbol >= 2 {
                symbols[letters] = symbol
                letters += 1
                if foldedScalar != scalar {
                    upper += 1
                    if position > coreStart { upperInside += 1 }
                } else {
                    lower += 1
                }
            } else {
                coreSymbols += 1
                self.symbols += 1
            }
        }
        fingerprint = folded.value
        exactFingerprint = exact.value
        guard isWord else { return }
        rank = language.rank(of: fingerprint)
        if letters >= 3 {
            prefixPossible = language.isPossiblePrefix(UnsafeBufferPointer(rebasing: symbols[0..<min(4, letters)]))
        }

        // Hyphens join words: "кто-то", "out-of-date". The word lists rarely
        // have them, so each part is measured and looked up on its own.
        let hyphen = language.symbol(0x2D)
        var start = 0
        var parts = 0
        var partRank: UInt8 = 255
        var partsKnown = true
        for position in 0...letters where position == letters || symbols[position] == hyphen {
            if position > start {
                cost += language.cost(UnsafeBufferPointer(rebasing: symbols[start..<position]))
                parts += 1
                if rank == nil, partsKnown {
                    var part = ModelFormat.Fingerprint()
                    var index = coreStart
                    var seen = 0
                    while index < coreEnd, seen < position {
                        let scalar = ModelFormat.fold(scalars[index])
                        if language.symbol(scalar) >= 2 {
                            if seen >= start { part.add(scalar) }
                            seen += 1
                        }
                        index += 1
                    }
                    if let known = language.rank(of: part.value) {
                        partRank = min(partRank, known)
                    } else {
                        partsKnown = false
                    }
                }
            }
            start = position + 1
        }
        if rank == nil, parts >= 2, partsKnown { rank = partRank }
    }
}
