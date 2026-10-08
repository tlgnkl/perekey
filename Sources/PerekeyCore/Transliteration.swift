// SPDX-License-Identifier: GPL-3.0-or-later

/// Cyrillic ↔ Latin transliteration, by GOST 7.79-2000 system B (the table
/// ICAO and passports resemble), with these choices for a clean round trip:
///
///     а a   б b   в v   г g   д d   е e   ё yo  ж zh  з z
///     и i   й j   к k   л l   м m   н n   о o   п p   р r
///     с s   т t   у u   ф f   х x   ц c   ч ch  ш sh  щ shh
///     ъ ''  ы y'  ь '   э e`  ю yu  я ya
///
/// Capitals: "Zh" in Title case, "ZH" when a neighbor letter is a capital too
/// (ЖУК → ZHUK, Жук → Zhuk). Going back, Latin is matched longest first and
/// without regard to case; letters the table does not have (h, q, w) stay.
///
/// Known losses on the round trip: Ъ and Ь come back lowercase (no letter to
/// carry the case), "ch" always reads as ч, and "''" as ъ.
public enum Transliteration {
    public enum Direction: Hashable, Sendable {
        case toLatin, toCyrillic
    }

    private static let pairs: [(cyrillic: Character, latin: String)] = [
        ("а", "a"), ("б", "b"), ("в", "v"), ("г", "g"), ("д", "d"), ("е", "e"), ("ё", "yo"), ("ж", "zh"),
        ("з", "z"), ("и", "i"), ("й", "j"), ("к", "k"), ("л", "l"), ("м", "m"), ("н", "n"), ("о", "o"),
        ("п", "p"), ("р", "r"), ("с", "s"), ("т", "t"), ("у", "u"), ("ф", "f"), ("х", "x"), ("ц", "c"),
        ("ч", "ch"), ("ш", "sh"), ("щ", "shh"), ("ъ", "''"), ("ы", "y'"), ("ь", "'"), ("э", "e`"),
        ("ю", "yu"), ("я", "ya"),
    ]

    private static let toLatinTable: [Character: String] =
        Dictionary(uniqueKeysWithValues: pairs.map { ($0.cyrillic, $0.latin) })
    /// Latin keys, longest first, so "shh" wins over "sh".
    private static let toCyrillicTable: [(latin: [Character], cyrillic: Character)] =
        pairs.map { (latin: Array($0.latin), cyrillic: $0.cyrillic) }.sorted { $0.latin.count > $1.latin.count }

    /// Which way `text` goes: the script with more letters is converted. `nil`
    /// if it has no letters of either script.
    public static func direction(of text: String) -> Direction? {
        var cyrillic = 0
        var latin = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            switch scalar.value {
            case 0x0400...0x04FF: cyrillic += 1
            case 0x41...0x5A, 0x61...0x7A: latin += 1
            default: break
            }
        }
        if cyrillic == 0, latin == 0 { return nil }
        return cyrillic > latin ? .toLatin : .toCyrillic
    }

    /// `text` in the other script, or `nil` if there is nothing to convert.
    public static func convert(_ text: String) -> String? {
        guard let direction = direction(of: text) else { return nil }
        let result = convert(text, direction)
        return result == text ? nil : result
    }

    public static func convert(_ text: String, _ direction: Direction) -> String {
        switch direction {
        case .toLatin: toLatin(text)
        case .toCyrillic: toCyrillic(text)
        }
    }

    private static func toLatin(_ text: String) -> String {
        let characters = Array(text)
        var result = ""
        for (index, character) in characters.enumerated() {
            let lower = Character(character.lowercased())
            guard let latin = toLatinTable[lower] else {
                result.append(character)
                continue
            }
            guard character.isUppercase else {
                result += latin
                continue
            }
            let shout = latin.count > 1 && (isUpperCyrillic(characters, index - 1) || isUpperCyrillic(characters, index + 1))
            result += shout ? latin.uppercased() : latin.prefix(1).uppercased() + latin.dropFirst()
        }
        return result
    }

    private static func isUpperCyrillic(_ characters: [Character], _ index: Int) -> Bool {
        guard characters.indices.contains(index) else { return false }
        let character = characters[index]
        return character.isUppercase && toLatinTable[Character(character.lowercased())] != nil
    }

    private static func toCyrillic(_ text: String) -> String {
        let characters = Array(text)
        var result = ""
        var index = 0
        scan: while index < characters.count {
            for entry in toCyrillicTable where index + entry.latin.count <= characters.count {
                let slice = characters[index..<index + entry.latin.count]
                guard zip(slice, entry.latin).allSatisfy({ $0.lowercased() == String($1) }) else { continue }
                result += slice.first!.isUppercase ? entry.cyrillic.uppercased() : String(entry.cyrillic)
                index += entry.latin.count
                continue scan
            }
            result.append(characters[index])
            index += 1
        }
        return result
    }
}
