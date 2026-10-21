// SPDX-License-Identifier: GPL-3.0-or-later

/// Checks `data/ru/hyphen.txt`, the words people type without their hyphen
/// ("вопервых" for "во-первых"): the "hyph" table of the model
/// (docs/corrections.md, «Дефис»).
///
/// The list is written by hand: wordfreq splits words at hyphens and the
/// Lebedev dictionary has no word with one, so nothing derives it. The check
/// keeps a mistake in it from changing a right word:
///
/// - The merged spelling must be no word: not a form of the spelling
///   dictionary or of `add.txt` ("потому", "тоже", "таки"), and below
///   `maxMergedRank` in wordfreq, where typos live ("чтото" 3.26 on the Zipf
///   scale, "изза" 3.18; real words of that shape sit far above: "потому"
///   5.78, "тоже" 5.86).
/// - Each part must be a word ("что", "то"): a typo in the list fails.
/// - One hyphen, not at an end, lowercase.
///
/// A form with "ё" is checked in its "е" spelling too: the builder adds both.
public enum HyphenList {
    /// Zipf 3.5: the most frequent merged spelling of the list is "чтото",
    /// 3.26.
    public static let maxMergedRank = WordFreq.rank(zipf: 3.5)

    /// The entries that pass, in order. Throws one failure that names every
    /// bad entry and why.
    /// - Parameters:
    ///   - isWord: the word is a form of the spelling dictionary or of a hand list.
    ///   - rank: the wordfreq rank of a word, `nil` if wordfreq does not know it.
    public static func check(_ entries: [String], file: String, isWord: (String) -> Bool,
                             rank: (String) -> UInt8?) throws -> [String]
    {
        var problems: [String] = []
        for entry in entries {
            let parts = entry.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                problems.append("\(entry): needs one hyphen between two parts")
                continue
            }
            guard entry == entry.lowercased() else {
                problems.append("\(entry): not lowercase")
                continue
            }
            let missing = parts.filter { !isWord($0) && rank($0) == nil }
            if !missing.isEmpty {
                problems.append("\(entry): \(missing.joined(separator: ", ")) is no word")
            }
            for merged in Set([parts.joined(), YoTable.plain(parts.joined())]).sorted() {
                if isWord(merged) {
                    problems.append("\(entry): \(merged) is a word of the dictionary")
                } else if let found = rank(merged), found >= maxMergedRank {
                    problems.append("\(entry): \(merged) is frequent in wordfreq (rank \(found))")
                }
            }
        }
        guard problems.isEmpty else {
            throw ModelBuild.Failure(description: "\(file): " + problems.joined(separator: "; "))
        }
        return entries
    }
}
