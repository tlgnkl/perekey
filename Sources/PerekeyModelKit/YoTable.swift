// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyCore

/// Derives the words that take "ё" unambiguously from a Hunspell dictionary:
/// the "yo" table of the model (docs/corrections.md, «Буква ё»).
///
/// Lebedev's ru_RU lists every stem with "ё" twice: "чёрный/AZ" and
/// "черный/AZ", with the same flags. Such an "е" stem is a *twin*: it adds
/// no word, only a spelling. A form with "ё" goes into the table when its
/// "е" spelling comes from twins only. If any other stem gives the "е"
/// spelling ("все" from "весь", "шлем/K" beside "шлём"), or two forms with
/// "ё" share it, the "е" spelling stays as typed.
///
/// Stems with a capital (names: "Алёна", "Алена") give no table entries:
/// both spellings of a name are in use. Their twins are skipped too, and
/// every other stem blocks the "е" spellings of its forms.
///
/// Feed every form of every stem with `add`, before any deduplication: the
/// result depends on which stem gave a form, not on the order.
public struct YoTable {
    private enum Role { case yo, twin, other, skip }

    private let roles: [Role]
    /// The "е" spelling → the forms with "ё" it stands for.
    private var candidates: [String: Set<String>] = [:]
    /// Folded fingerprints of "е" spellings that are words of their own.
    private var blocked: Set<UInt64> = []

    public init(entries: [(stem: String, flags: Substring)]) {
        // The flags of every stem with "ё", under its "е" spelling.
        var spellings: [String: (flags: Set<Substring>, capital: Bool)] = [:]
        for entry in entries where Self.hasYo(entry.stem) {
            let plain = Self.plain(entry.stem)
            spellings[plain, default: ([], false)].flags.insert(entry.flags)
            if entry.stem.first?.isUppercase == true { spellings[plain]!.capital = true }
        }
        roles = entries.map { entry in
            if Self.hasYo(entry.stem) { return entry.stem.first?.isUppercase == true ? .skip : .yo }
            guard let twin = spellings[entry.stem], twin.flags.contains(entry.flags) else { return .other }
            return twin.capital ? .skip : .twin
        }
    }

    /// A lowercase form of the stem at `index` of the entries.
    public mutating func add(_ form: String, entry index: Int) {
        switch roles[index] {
        case .yo:
            guard Self.hasYo(form) else { return }
            candidates[Self.plain(form), default: []].insert(form)
        case .other:
            block(form)
        case .twin, .skip:
            return
        }
    }

    /// A word of its own from elsewhere (`data/ru/add.txt`): its "е"
    /// spelling must not turn into "ё".
    public mutating func block(_ word: String) {
        guard word.contains("е") else { return }
        blocked.insert(ModelFormat.Fingerprint.of(word.unicodeScalars, folded: true))
    }

    /// The largest gap in frequency rank between the "е" spelling and the
    /// form with "ё": 48 is 1.5 on the Zipf scale, the "е" spelling about
    /// 30 times as frequent. Spelling twins stay well inside (ещё/еще 0.6,
    /// учётом/учетом 1.4); homographs the dictionary lists as twins fall
    /// out (нёбо/небо 2.4, лёт/лет 4.2).
    public static let maxRankGap = 48

    /// The forms with "ё" whose "е" spelling is no other word, sorted.
    ///
    /// Lebedev's twins are not always spellings: "нёбо" and "небо" are two
    /// words with one paradigm. Usage tells them apart: `rank` gives the
    /// wordfreq rank of a form (`nil` if wordfreq does not know it). A form
    /// with "ё" must be in use, and its "е" spelling at most `maxRankGap`
    /// more frequent. Pronoun forms that pass anyway ("всё" and "все")
    /// come from `data/ru/noyo.txt` through `block`.
    public func forms(rank: (String) -> UInt8?) -> [String] {
        var result: [String] = []
        for (plain, forms) in candidates where forms.count == 1 {
            let form = forms.first!
            guard !blocked.contains(ModelFormat.Fingerprint.of(plain.unicodeScalars, folded: true)),
                  let used = rank(form), Int(rank(plain) ?? 0) - Int(used) <= Self.maxRankGap
            else { continue }
            result.append(form)
        }
        return result.sorted()
    }

    private static func hasYo(_ text: String) -> Bool {
        text.contains("ё") || text.contains("Ё")
    }

    /// The spelling with "е" for "ё", case kept.
    static func plain(_ text: String) -> String {
        String(text.map { $0 == "ё" ? "е" : $0 == "Ё" ? "Е" : $0 })
    }
}
