// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyModelKit

/// The pairs «typo → meant word» of real people, for the suites `typos.real.*`.
///
/// Two readers:
/// - `misspellings`: Wikipedia's «Lists of common misspellings / For
///   machines», `misspelling->correction` per line (CC BY-SA 4.0, a pinned
///   revision in `scripts/fetch-data.sh`). The list has no sentences; the
///   word goes into a Tatoeba sentence that has the meant word, and stands
///   alone when no sentence has it.
/// - `typopairs`: a file the person put there, for data whose licence is
///   not clear (RUSpellRU, GitHubTypoCorpusRu). Never fetched, never in the
///   repository. One pair per line, tab-separated: `typo<TAB>meant`, words,
///   or `sentence as typed<TAB>sentence as meant`. Lines starting with `#`
///   are comments.
///
/// Only pairs of one edit in one word (a letter more, less, other, or two
/// neighbours swapped) become cases: a typo that is two words or three
/// edits is another class.
extension CorrectionBuilder {
    /// Numbers of the pairs. A first guess, not a measurement.
    struct PairOptions {
        /// The shortest meant word: the corrector looks at words of four
        /// letters and more (`TypoCorrector.Options.minLetters`).
        var minLetters = 4
        /// Sentences kept for one meant word; the pairs of that word share them in turn.
        var carriersPerWord = 3
    }

    func pairCandidates(budget: Int, cache: String, report: inout BuildReport) throws -> [String: [Candidate]] {
        let options = PairOptions()
        var candidates: [Candidate] = []
        switch manifest.reader {
        case .misspellings:
            let pairs = try Self.readMisspellings(path: sourcePath(cache))
            report.units = pairs.count
            candidates = try withCarriers(pairs, cache: cache, options: options)
        case .typopairs:
            let lines = try String(contentsOfFile: sourcePath(cache), encoding: .utf8).split(separator: "\n")
            for (number, line) in lines.enumerated() where !line.hasPrefix("#") {
                report.units += 1
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard fields.count == 2, !fields[0].isEmpty, !fields[1].isEmpty else {
                    report.drops["badLine", default: 0] += 1
                    continue
                }
                let ref = "typopairs:\(number + 1)"
                candidates.append(Candidate(rank: SuiteBuilder.rank(ref: ref, seed: manifest.seed, epoch: manifest.epoch),
                                            ref: ref, text: String(fields[1]), slip: .typed(String(fields[0]))))
            }
        default:
            throw EvalError.input("\(manifest.suite): reader \(manifest.reader.rawValue) has no pairs")
        }
        candidates.sort { $0.rank != $1.rank ? $0.rank < $1.rank : $0.ref < $1.ref }
        return Dictionary(uniqueKeysWithValues: manifest.scenarios.map { ($0, candidates) })
    }

    func sourcePath(_ cache: String) throws -> String {
        guard let source = manifest.sources.first else { throw EvalError.input("\(manifest.suite): no source") }
        let path = (cache as NSString).appendingPathComponent(source)
        guard FileManager.default.fileExists(atPath: path) else {
            throw EvalError.input("\(manifest.suite): no source file \(path)")
        }
        return path
    }

    /// One pair of the Wikipedia list.
    struct Misspelling: Hashable {
        var typo: String
        var meant: String
    }

    /// The pairs of the list with one correction that is one word, one edit away, of `minLetters` and more,
    /// in the order of the file; the first line of a typo wins.
    static func readMisspellings(path: String, options: PairOptions = PairOptions()) throws -> [Misspelling] {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        return misspellings(in: text, options: options)
    }

    static func misspellings(in text: String, options: PairOptions = PairOptions()) -> [Misspelling] {
        var seen = Set<String>()
        var pairs: [Misspelling] = []
        for line in text.split(separator: "\n") {
            guard let arrow = line.range(of: "->") else { continue }
            let typo = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
            let meant = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
            guard isWord(typo), isWord(meant), meant.count >= options.minLetters, typo != meant,
                  Knowledge.distance(Array(typo), Array(meant)) == 1, seen.insert(typo).inserted
            else { continue }
            pairs.append(Misspelling(typo: typo, meant: meant))
        }
        return pairs
    }

    /// Plain ASCII letters, lower case: the list is English.
    static func isWord(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { (0x61...0x7A).contains($0.value) }
    }

    /// Each pair on a sentence of the carrier file that has the meant word, or alone.
    func withCarriers(_ pairs: [Misspelling], cache: String, options: PairOptions) throws -> [Candidate] {
        var carriers: [String: [SuiteBuilder.Pooled]] = [:]
        let meant = Set(pairs.map(\.meant))
        if let carrier = manifest.carrier {
            let path = (cache as NSString).appendingPathComponent(carrier)
            guard FileManager.default.fileExists(atPath: path) else {
                throw EvalError.input("\(manifest.suite): no carrier file \(path)")
            }
            try TatoebaReader.forEachLazyUnit(path: path) { refHash, pending in
                let rank = SuiteBuilder.rank(refHash: refHash, seed: manifest.seed, epoch: manifest.epoch)
                // The words of the sentence, by bytes first: most sentences have none of the meant words.
                let unit = pending.make()
                var hit: [String] = []
                for token in unit.text.split(separator: " ") {
                    let word = Anatomy(String(token)).core.lowercased()
                    if meant.contains(word), !hit.contains(word) { hit.append(word) }
                }
                for word in hit {
                    var list = carriers[word, default: []]
                    if list.count >= options.carriersPerWord, let worst = list.last, rank > worst.rank { continue }
                    list.append(SuiteBuilder.Pooled(rank: rank, ref: unit.ref, text: unit.text))
                    list.sort(by: SuiteBuilder.order)
                    carriers[word] = Array(list.prefix(options.carriersPerWord))
                }
            }
        }
        var next: [String: Int] = [:]
        var result: [Candidate] = []
        for pair in pairs {
            let list = carriers[pair.meant] ?? []
            let slip = Slip.replace(word: pair.meant, with: pair.typo)
            if list.isEmpty {
                let ref = "wm:\(pair.typo)>\(pair.meant)"
                result.append(Candidate(rank: SuiteBuilder.rank(ref: ref, seed: manifest.seed, epoch: manifest.epoch),
                                        ref: ref, text: pair.meant, slip: slip))
            } else {
                let index = next[pair.meant, default: 0]
                next[pair.meant] = index + 1
                let carrier = list[index % list.count]
                let ref = "wm:\(pair.typo)>\(pair.meant)@\(carrier.ref)"
                result.append(Candidate(rank: SuiteBuilder.rank(ref: ref, seed: manifest.seed, epoch: manifest.epoch),
                                        ref: ref, text: carrier.text, slip: slip))
            }
        }
        return result
    }
}

enum PairEdits {
    /// The first token whose word is `word` (case folded) typed as `with`, in the case of the word.
    static func replace(word: String, with typo: String, tokens: [ParsedToken]) -> Result<Edited, Drop> {
        for (index, token) in tokens.enumerated() {
            let anatomy = Anatomy(token.text)
            guard anatomy.core.lowercased() == word, !token.code else { continue }
            var typed = tokens.map(\.text)
            typed[index] = anatomy.with(core: matchCase(typo, like: anatomy.core))
            var tags = [[String]](repeating: [], count: tokens.count)
            tags[index] = ["real"]
            return .success(Edited(typed: typed, tags: tags))
        }
        return .failure(.noTarget)
    }

    /// The sentence as the source typed it, against the sentence as meant: the same number of tokens, one of them
    /// different by one edit.
    static func typed(_ text: String, meant: ParsedUnit, manifest: SuiteManifest, set: LayoutSet,
                      library: LayoutLibrary) -> Result<Edited, Drop>
    {
        let typed: ParsedUnit
        switch UnitParser.parse(text, manifest: manifest, set: set, library: library) {
        case let .failure(drop): return .failure(drop)
        case let .success(unit): typed = unit
        }
        guard typed.tokens.count == meant.tokens.count else { return .failure(.noTarget) }
        let different = meant.tokens.indices.filter { meant.tokens[$0].text != typed.tokens[$0].text }
        guard different.count == 1, let index = different.first else { return .failure(.noTarget) }
        let lhs = Array(Anatomy(typed.tokens[index].text).core.lowercased())
        let rhs = Array(Anatomy(meant.tokens[index].text).core.lowercased())
        guard !lhs.isEmpty, !rhs.isEmpty, Knowledge.distance(lhs, rhs) == 1 else { return .failure(.noTarget) }
        var tags = [[String]](repeating: [], count: meant.tokens.count)
        tags[index] = ["real"]
        return .success(Edited(typed: typed.tokens.map(\.text), tags: tags))
    }

    /// The typo in the case of the word it replaces: «Beleive» for «Believe», «BELEIVE» for «BELIEVE».
    static func matchCase(_ typo: String, like word: String) -> String {
        if word.count > 1, word.allSatisfy(\.isUppercase) { return typo.uppercased() }
        if word.first?.isUppercase == true { return typo.prefix(1).uppercased() + typo.dropFirst() }
        return typo
    }
}
