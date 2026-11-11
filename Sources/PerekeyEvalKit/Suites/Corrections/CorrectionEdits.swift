// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyModelKit

/// What the fingers type for each token of the meant sentence, and the tags
/// of the tokens the slip is in.
struct Edited {
    /// One entry per token of the sentence; a token typed with a space in it
    /// («что то» for «что-то») holds the space.
    var typed: [String]
    var tags: [[String]]

    /// The sentence as typed, tokens joined by a space.
    var text: String { typed.joined(separator: " ") }
}

/// A token cut into the marks in front of it, its word and the marks after it:
/// «(Привет,» is `(`, `Привет`, `,`.
struct Anatomy {
    var lead: String
    var core: String
    var trail: String

    init(_ token: String) {
        var characters = Substring(token)
        var lead = ""
        var trail = ""
        while let first = characters.first, !first.isLetter { lead.append(characters.removeFirst()) }
        while let last = characters.last, !last.isLetter { trail = String(characters.removeLast()) + trail }
        self.lead = lead
        core = String(characters)
        self.trail = trail
    }

    func with(core: String) -> String { lead + core + trail }

    var letters: [Character] { core.filter(\.isLetter) }
    var isWord: Bool { !core.isEmpty && core.allSatisfy(\.isLetter) }
    var isUpper: Bool { isWord && core.allSatisfy(\.isUppercase) }
    /// First letter capital, the others small.
    var isTitle: Bool { isWord && core.first?.isUppercase == true && core.dropFirst().allSatisfy(\.isLowercase) }
    /// A capital after a small letter: «McDonald», «iPhone», «YouTube».
    var hasInnerCapital: Bool {
        isWord && zip(core, core.dropFirst()).contains { $0.isLowercase && $1.isUppercase }
    }
}

/// The edits of the correction suites, one function per kind (docs/eval.md,
/// «Наборы правок слова»). Each takes the tokens of the meant sentence and
/// says what the fingers type; the case builder asks Null which tokens come
/// out wrong, so a token the edit does not change is never marked.
enum CorrectionEdits {
    /// A cheap test of the raw sentence, to keep the pool of a scenario to
    /// sentences that can give a case. It may say yes where the edit later
    /// finds nothing; it never says no where the edit would find something.
    static func prefilter(_ kind: SuiteManifest.Correction.Kind, scenario: String, text: String) -> Bool {
        switch kind {
        case .yo: return text.contains("ё") || text.contains("Ё")
        case .hyphen: return text.contains("-") || text.contains("—") || text.contains("–")
        case .abbrev, .doublecap:
            if scenario == "fix", kind == .doublecap { return true }
            // Two capitals in a row, or a capital after a small letter.
            var previous: Character?
            for character in text {
                if let before = previous, character.isUppercase, before.isLetter { return true }
                previous = character
            }
            return false
        case .typoSynth, .capslock, .typoReal: return true
        }
    }

    static func apply(_ kind: SuiteManifest.Correction.Kind, scenario: String, tokens: [ParsedToken], language: String,
                      weights: SuiteManifest.TypoWeights?, random: inout SplitMix64) -> Result<Edited, Drop>
    {
        let plain = tokens.map(\.text)
        let none = [[String]](repeating: [], count: plain.count)
        switch kind {
        case .typoSynth:
            guard let weights else { return .failure(.noTarget) }
            let eligible = plain.indices.filter {
                let anatomy = Anatomy(plain[$0])
                return anatomy.isWord && anatomy.letters.count >= TypoMaker.Options().minLetters && !tokens[$0].code
            }
            guard !eligible.isEmpty else { return .failure(.noTarget) }
            let index = eligible[Int(random.next() % UInt64(eligible.count))]
            let anatomy = Anatomy(plain[index])
            guard let made = TypoMaker.make(word: anatomy.core, language: language, weights: weights, random: &random)
            else { return .failure(.noTypo) }
            var typed = plain
            typed[index] = anatomy.with(core: made.typo)
            var tags = none
            tags[index] = [made.kind.rawValue]
            return .success(Edited(typed: typed, tags: tags))

        case .yo:
            var tags = none
            let typed = plain.enumerated().map { index, token -> String in
                let changed = token.replacingOccurrences(of: "ё", with: "е").replacingOccurrences(of: "Ё", with: "Е")
                if changed != token { tags[index] = ["yo"] }
                return changed
            }
            return tags.contains { !$0.isEmpty } ? .success(Edited(typed: typed, tags: tags)) : .failure(.noTarget)

        case .hyphen:
            var tags = none
            var typed = plain
            for (index, token) in plain.enumerated() {
                let anatomy = Anatomy(token)
                let parts = anatomy.core.split(separator: "-", omittingEmptySubsequences: false)
                guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isLetter) }) else { continue }
                tags[index] = ["hyphen"]
                switch scenario {
                case "fix.merged": typed[index] = anatomy.with(core: parts.joined())
                case "fix.spaced": typed[index] = anatomy.with(core: parts.joined(separator: " "))
                default: break
                }
            }
            return tags.contains { !$0.isEmpty } ? .success(Edited(typed: typed, tags: tags)) : .failure(.noTarget)

        case .doublecap:
            if scenario == "keep" {
                // Words that really have two capitals: ГОСТ, USA, McDonald, iPhone. Typed as they are.
                var tags = none
                for (index, token) in plain.enumerated() {
                    let anatomy = Anatomy(token)
                    if (anatomy.isUpper && anatomy.letters.count >= 2) || anatomy.hasInnerCapital { tags[index] = ["capitals"] }
                }
                return tags.contains { !$0.isEmpty } ? .success(Edited(typed: plain, tags: tags)) : .failure(.noTarget)
            }
            let eligible = plain.indices.filter {
                let anatomy = Anatomy(plain[$0])
                return anatomy.isTitle && anatomy.letters.count >= 3 && !tokens[$0].code
            }
            guard !eligible.isEmpty else { return .failure(.noTarget) }
            let index = eligible[Int(random.next() % UInt64(eligible.count))]
            let anatomy = Anatomy(plain[index])
            var typed = plain
            typed[index] = anatomy.with(core: anatomy.core.prefix(2).uppercased() + anatomy.core.dropFirst(2))
            var tags = none
            tags[index] = [index == 0 ? "initial" : "inside"]
            return .success(Edited(typed: typed, tags: tags))

        case .capslock:
            // The person forgot Caps Lock: the whole sentence comes out in capitals unless the program
            // turns it off. It can turn it off only at the first word, so that word must be fixable.
            let first = Anatomy(plain[0])
            guard first.isTitle, first.letters.count >= 2 else { return .failure(.noTarget) }
            var tags = none
            tags[0] = ["lead"]
            return .success(Edited(typed: plain, tags: tags))

        case .abbrev:
            let anatomies = plain.map(Anatomy.init)
            // A sentence with a word in capitals longer than an abbreviation is shouting: the person meant it.
            if anatomies.contains(where: { $0.isUpper && $0.letters.count > abbreviationMaxLetters }) {
                return .failure(.noTarget)
            }
            var typed = plain
            var tags = none
            for (index, anatomy) in anatomies.enumerated()
                where anatomy.isUpper && (2...abbreviationMaxLetters).contains(anatomy.letters.count) && !tokens[index].code
            {
                tags[index] = ["abbreviation"]
                if scenario == "fix" { typed[index] = anatomy.with(core: anatomy.core.lowercased()) }
            }
            return tags.contains { !$0.isEmpty } ? .success(Edited(typed: typed, tags: tags)) : .failure(.noTarget)

        case .typoReal:
            return .failure(.noTarget)
        }
    }

    /// The most letters of an abbreviation: МВД, ВрИО, USA, NASA, UNESCO. A first guess, not a measurement:
    /// longer words in capitals in the corpus are mostly shouting.
    static let abbreviationMaxLetters = 5
}
