// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The held-out corpus of the en ↔ uk pair (docs/classifier.md, «Метрика»):
/// the same categories as the ru ↔ en corpus where there is data for them.
///
/// - prose: Tatoeba `ukr` and `eng` sentences of 8 words and more, as written;
/// - chat: sentences of up to 6 words, lower case, no punctuation;
/// - mixed: posts of ukrainian.stackexchange.com, Ukrainian and English text
///   side by side, so the previous word is often in the other language.
///
/// A word's language is its script: Cyrillic is "uk", Latin is "en".
/// Apostrophes become `'`, the key the Ukrainian layouts have for it.
extension Corpus {
    public static let ukrainianCategories = ["prose", "chat", "mixed"]

    static let ukrainianShares: [String: Double] = ["prose": 0.40, "chat": 0.35, "mixed": 0.25]

    public static func buildUkrainian(cache: String, words: Int, seed: UInt64) throws -> [CorpusItem] {
        var random = SplitMix64(seed: seed)
        var items: [CorpusItem] = []
        let quota = { (category: String) in Int(Double(words) * ukrainianShares[category]!) }

        let ukrainian = try tatoeba("\(cache)/tatoeba/ukr_sentences.tsv.bz2", random: &random)
        let english = try tatoeba("\(cache)/tatoeba/eng_sentences.tsv.bz2", random: &random)
        var uk = ukrainian.makeIterator()
        var en = english.makeIterator()

        var count = 0
        while count < quota("prose"), let sentence = random.bool() ? uk.next() : en.next() {
            let tokens = sentence.split(separator: " ").map { trimQuotes(apostrophes($0)) }.filter { !$0.isEmpty }
            guard tokens.count >= 8 else { continue }
            count += addUkrainian(tokens, category: "prose", to: &items)
        }

        count = 0
        while count < quota("chat"), let sentence = random.bool() ? uk.next() : en.next() {
            let tokens = apostrophes(Substring(sentence.lowercased())).split(separator: " ").map { token in
                String(token.filter { $0.isLetter || $0 == "-" || $0 == "'" })
            }.filter { !$0.isEmpty }
            guard tokens.count >= 1, tokens.count <= 6 else { continue }
            count += addUkrainian(tokens, category: "chat", to: &items)
        }

        count = 0
        let posts = try stackExchangePosts("\(cache)/stackexchange/ukrainian.stackexchange.com.7z")
        for post in posts.shuffled(using: &random) where count < quota("mixed") {
            let tokens = post.split(whereSeparator: \.isWhitespace).map { trimQuotes(apostrophes($0)) }
                .filter { !$0.isEmpty }
            count += addUkrainian(tokens, category: "mixed", to: &items)
        }
        return items
    }

    /// "uk" for a Cyrillic word, "en" for a Latin one, nil for anything else.
    static func ukrainianLanguage(of token: String) -> String? {
        var cyrillic = false, latin = false
        for scalar in token.unicodeScalars {
            switch scalar.value {
            case 0x400...0x4FF: cyrillic = true
            case 0x41...0x5A, 0x61...0x7A: latin = true
            case 0x30...0x39: return nil
            default:
                guard scalar.properties.isAlphabetic == false else { return nil }
            }
        }
        if cyrillic != latin { return cyrillic ? "uk" : "en" }
        return nil
    }

    private static func addUkrainian(_ tokens: [String], category: String, to items: inout [CorpusItem]) -> Int {
        var previous: String?
        var added = 0
        for token in tokens {
            guard let language = ukrainianLanguage(of: token) else {
                previous = nil
                continue
            }
            items.append(CorpusItem(category: category, language: language, previous: previous, text: token))
            previous = language
            added += 1
        }
        return added
    }

    /// `’` and `ʼ` as `'`.
    static func apostrophes(_ text: Substring) -> String {
        String(text.map { $0 == "\u{2019}" || $0 == "\u{2BC}" ? "'" : $0 })
    }

    /// Without the quotes and dashes around it that the layouts do not type.
    static func trimQuotes(_ token: String) -> String {
        let quotes: Set<Character> = ["«", "»", "“", "”", "„", "…", "—", "–"]
        var text = Substring(token)
        while let first = text.first, quotes.contains(first) { text.removeFirst() }
        while let last = text.last, quotes.contains(last) { text.removeLast() }
        return String(text)
    }

    /// The text of every post of a Stack Exchange dump: `Body` without markup
    /// and without code, which is not prose in either language.
    static func stackExchangePosts(_ path: String) throws -> [String] {
        let data = try Archive.run("/usr/bin/tar", ["-xOf", path, "Posts.xml"])
        var posts: [String] = []
        // The dump ends lines with "\r\n", one `Character`: split on any newline.
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            guard let start = line.range(of: " Body=\"") else { continue }
            let rest = line[start.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { continue }
            var body = unescapeXML(String(rest[..<end]))
            for tag in ["pre", "code"] {
                while let open = body.range(of: "<\(tag)"),
                      let close = body.range(of: "</\(tag)>", range: open.upperBound..<body.endIndex)
                {
                    body.replaceSubrange(open.lowerBound..<close.upperBound, with: " ")
                }
            }
            var text = ""
            var inTag = false
            for character in body {
                switch character {
                case "<": inTag = true
                case ">":
                    inTag = false
                    text.append(" ")
                default:
                    if !inTag { text.append(character) }
                }
            }
            posts.append(unescapeXML(text))
        }
        return posts
    }

    /// XML character references and the five entities.
    static func unescapeXML(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character == "&", let semicolon = text[index...].firstIndex(of: ";"),
                  text.distance(from: index, to: semicolon) <= 10
            else {
                result.append(character)
                index = text.index(after: index)
                continue
            }
            let name = text[text.index(after: index)..<semicolon]
            switch name {
            case "lt": result.append("<")
            case "gt": result.append(">")
            case "amp": result.append("&")
            case "quot": result.append("\"")
            case "apos": result.append("'")
            default:
                let value: UInt32? = name.hasPrefix("#x") ? UInt32(name.dropFirst(2), radix: 16)
                    : name.hasPrefix("#") ? UInt32(name.dropFirst()) : nil
                if let value, let scalar = Unicode.Scalar(value) {
                    result.unicodeScalars.append(scalar)
                } else {
                    result += "&\(name);"
                }
            }
            index = text.index(after: semicolon)
        }
        return result
    }
}
