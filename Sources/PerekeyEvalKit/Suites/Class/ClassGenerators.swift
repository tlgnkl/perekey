// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyModelKit

/// The protect suites: text that must not change, made by generators. `url`, `password` and `captcha` are ports
/// of `Synthetic` (`Sources/PerekeyModelKit/Corpus.swift`): the same logic, seeded by the manifest. The
/// evaluation of the model keeps its own copy and is not touched (rule 2.1).
extension ClassRules {
    static let urlTLDs = ["com", "ru", "org", "io", "net", "dev", "su"]
    static let cyrillicTLD = "рф"
    static let passwordSymbols = Array("!@#$%^&*_-+=?")
    /// The letters of a captcha by language: the ones the language's layout has a key for. Latin when absent.
    static let alphabets: [String: String] = [
        "ru": "абвгдежзиклмнопрстуфхцчшщыэюя", "uk": "абвгґдеєжзиіїйклмнопрстуфхцчшщьюя",
    ]

    /// The items of a generator suite: as many as the tier says, from the seed of the manifest.
    func generated() throws -> [ClassItem] {
        var random = SplitMix64(seed: FNV1a.hash64(manifest.suite) ^ UInt64(truncatingIfNeeded: manifest.seed + manifest.epoch))
        var vocabularies: [String: [String]] = [:]
        for language in spec.languages {
            vocabularies[language] = try lexiconWords(language, minimum: 0).lazy
                .filter { options.vocabularyLetters.contains($0.word.count) }.prefix(options.vocabularySize).map(\.word)
        }
        var items: [ClassItem] = []
        var made = Set<String>()
        var attempts = 0
        while items.count < cap, attempts < cap * 20 {
            attempts += 1
            let language = spec.languages[attempts % spec.languages.count]
            guard let vocabulary = vocabularies[language], !vocabulary.isEmpty else { continue }
            let produced: [ClassItem]
            switch spec.rule {
            case .url: produced = [url(vocabulary: vocabulary, language: language, random: &random)]
            case .password: produced = password(vocabulary: vocabulary, language: language, random: &random)
            case .captcha: produced = [captcha(language: language, random: &random)]
            case .numbers: produced = [numbers(random: &random)]
            default: produced = []
            }
            for item in produced where made.insert(item.key).inserted { items.append(item) }
        }
        return items
    }

    static func pick<T>(_ items: [T], _ random: inout SplitMix64) -> T {
        items[Int(random.next() % UInt64(items.count))]
    }

    // MARK: - url

    /// `Synthetic.url`; a Cyrillic vocabulary gets the Cyrillic TLD too, a Latin one does not (a host half in each
    /// script is not an address a person types). A Cyrillic address has no `@` and no `~`: the Cyrillic layouts have
    /// no key for them, and the person would switch layout in the middle of the word.
    func url(vocabulary: [String], language: String, random: inout SplitMix64) -> ClassItem {
        let cyrillic = script(of: language) == .cyrillic
        let tlds = cyrillic ? Self.urlTLDs + [Self.cyrillicTLD] : Self.urlTLDs
        func word() -> String { Self.pick(vocabulary, &random) }
        let host = "\(word()).\(Self.pick(tlds, &random))"
        let text: String
        var shape = random.next() % 5
        if cyrillic, shape == 2 || shape == 3 { shape = 1 }
        switch shape {
        case 0: text = "https://\(host)/\(word())/\(word())"
        case 1: text = "www.\(host)"
        case 2: text = "\(word())@\(host)"
        case 3: text = "~/\(word())/\(word()).txt"
        default: text = "\(host)/\(word())?id=\(random.next() % 1000)"
        }
        return ClassItem(text: text, weight: 1, tags: ["url", "url:\(cyrillic ? "cyrillic" : "latin")"])
    }

    // MARK: - password

    /// `Synthetic.password` for the Latin vocabulary, and the Russian word typed on Latin keys with a digit and a
    /// symbol («Ghbdtn123!»). Each password is also given as typed on the Cyrillic layout of the set.
    func password(vocabulary: [String], language: String, random: inout SplitMix64) -> [ClassItem] {
        var text: String
        var tag = "random"
        if script(of: language) == .cyrillic {
            // The word the person means is Russian, the keys are Latin: «ghbdtn».
            guard let set = sets.first, let latin = library[set.latin], let cyrillic = library[set.cyrillic] else { return [] }
            let typed = latin.convert(Self.pick(vocabulary, &random), from: cyrillic)
            text = typed.prefix(1).uppercased() + typed.dropFirst() + String(random.next() % 1000)
                + (random.next() % 2 == 0 ? String(Self.pick(Self.passwordSymbols, &random)) : "")
            tag = "word"
        } else {
            text = Self.latinPassword(vocabulary: vocabulary, random: &random)
        }
        var items = [ClassItem(text: text, weight: 1, tags: ["password", "password:\(tag)", "password:latin"])]
        if let set = sets.first, let latin = library[set.latin], let cyrillic = library[set.cyrillic] {
            let typed = cyrillic.convert(text, from: latin)
            if typed != text {
                items.append(ClassItem(text: typed, weight: 1, tags: ["password", "password:\(tag)", "password:cyrillic"]))
            }
        }
        return items
    }

    static func latinPassword(vocabulary: [String], random: inout SplitMix64) -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        switch random.next() % 3 {
        case 0:
            var text = ""
            for index in 0..<(8 + Int(random.next() % 8)) {
                let letter = pick(letters, &random)
                switch random.next() % 4 {
                case 0: text.append(letter.uppercased())
                case 1: text.append(String(random.next() % 10))
                case 2: text.append(index > 0 ? pick(passwordSymbols, &random) : letter)
                default: text.append(letter)
                }
            }
            return text
        case 1:
            var word = Array(pick(vocabulary, &random))
            let position = 1 + Int(random.next() % UInt64(max(1, word.count - 1)))
            word[min(position, word.count - 1)] = Character(word[min(position, word.count - 1)].uppercased())
            return String(word) + String(random.next() % 100) + String(pick(passwordSymbols, &random))
        default:
            let first = pick(vocabulary, &random)
            let second = pick(vocabulary, &random)
            return first + second.prefix(1).uppercased() + String(second.dropFirst()) + String(pick(passwordSymbols, &random))
        }
    }

    // MARK: - captcha

    /// `Synthetic.captcha`: four to eight letters of one alphabet, a third in capitals.
    func captcha(language: String, random: inout SplitMix64) -> ClassItem {
        let letters = Array(Self.alphabets[language] ?? "abcdefghijklmnopqrstuvwxyz")
        var text = ""
        for _ in 0..<(4 + Int(random.next() % 5)) {
            let letter = Self.pick(letters, &random)
            text.append(random.next() % 3 == 0 ? Character(letter.uppercased()) : letter)
        }
        return ClassItem(text: text, weight: 1, tags: ["captcha", "captcha:\(script(of: language) == .cyrillic ? "cyrillic" : "latin")"])
    }

    // MARK: - numbers

    static let latinUnits = ["d", "h", "m", "s", "ms", "kb", "mb", "gb", "tb", "px", "em", "kg", "km", "mm", "cm", "fps", "gb"]
    static let cyrillicUnits = ["кг", "км", "мм", "см", "мл", "шт", "мин", "ч", "с", "мс", "гб", "мб", "руб", "г", "л", "дн"]
    static let gluedNames = ["mp3", "mp4", "h2o", "co2", "b2b", "b2c", "x86", "x64", "m1", "m2", "s3", "ec2", "ipv4", "ipv6",
                             "utf8", "sha256", "md5", "wav", "a4", "f1"]

    /// Numbers, dates, times and units: the words with digits and marks that no layout switch should touch.
    func numbers(random: inout SplitMix64) -> ClassItem {
        func number(_ limit: UInt64) -> UInt64 { random.next() % limit }
        func two(_ value: UInt64) -> String { String(format: "%02d", value) }
        let text: String
        let tag: String
        var aim = ClassItem.Aim.latin
        switch number(13) {
        case 0: (text, tag) = ("\(two(number(24))):\(two(number(60)))", "time")
        case 1: (text, tag) = ("\(two(1 + number(28))).\(two(1 + number(12))).\(2000 + number(30))", "date")
        case 2: (text, tag) = ("\(2000 + number(30))-\(two(1 + number(12)))-\(two(1 + number(28)))", "date")
        case 3: (text, tag) = ("\(1 + number(999))\(Self.pick(Self.latinUnits, &random))", "unit")
        case 4: (text, tag) = (Self.pick(Self.gluedNames, &random), "glued")
        case 5: (text, tag) = ("\(1 + number(999)) \(Self.pick(Self.cyrillicUnits, &random))", "unit:cyrillic")
        case 6: (text, tag) = ("№\(1 + number(99))", "sign")
        case 7: (text, tag) = ("\(number(100))%", "percent")
        case 8: (text, tag) = ("\(number(10)).\(number(100))", "decimal")
        case 9: (text, tag) = ("\(number(10)),\(number(100))", "decimal")
        case 10: (text, tag) = ("v\(number(10)).\(number(20)).\(number(20))", "version")
        case 11: (text, tag) = ("\(640 + number(3000))x\(480 + number(2000))", "size")
        default: (text, tag) = ("+7 (\(900 + number(99))) \(100 + number(900))-\(two(number(100)))-\(two(number(100)))", "phone")
        }
        // Half of the digits-only items are typed on the Cyrillic layout: the digits are the same keys, the marks are not.
        if text.unicodeScalars.allSatisfy({ !$0.properties.isAlphabetic }) && number(2) == 0 { aim = .cyrillic }
        return ClassItem(text: text, weight: 1, tags: ["numbers", "numbers:\(tag)"], aim: aim)
    }
}
