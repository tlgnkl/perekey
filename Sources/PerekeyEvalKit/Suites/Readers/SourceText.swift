// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The text of a source, made ready for the builder: Stack Exchange HTML to
/// paragraphs, paragraphs to sentences (docs/eval.md, «Читатели»).
public enum SourceText {
    /// Wrap the words of an inline `<code>`: the builder tags their tokens
    /// `code` and takes the marks off. Private-use characters, which no
    /// source text has.
    public static let codeOpen: Character = "\u{E000}"
    public static let codeClose: Character = "\u{E001}"

    // MARK: - HTML

    /// The paragraphs of a post body, as the XML attribute `Body` holds it:
    /// `<pre>…</pre>` blocks are cut out whole, `<code>…</code>` in a line
    /// stays between `codeOpen` and `codeClose`, block tags end a paragraph,
    /// other tags fall away without a space, entities are read. Empty
    /// paragraphs are not returned.
    ///
    /// Works on unicode scalars: a gigabyte of posts goes through here, and
    /// grapheme breaking costs ten times as much.
    public static func paragraphs(fromBody body: String) -> [String] {
        var html = unescape(Array(body.unicodeScalars))
        // Blocks of code are not prose in either language.
        var search = 0
        while let open = find(preOpen, in: html, from: search), let close = find(preClose, in: html, from: open) {
            html.replaceSubrange(open..<(close + preClose.count), with: [newline])
            search = open + 1
        }
        var text: [Unicode.Scalar] = []
        text.reserveCapacity(html.count)
        var index = 0
        while index < html.count {
            let scalar = html[index]
            guard scalar == "<", let close = html[index...].firstIndex(of: ">") else {
                text.append(scalar)
                index += 1
                continue
            }
            var name = ""
            var position = index + 1
            let closing = position < close && html[position] == "/"
            if closing { position += 1 }
            while position < close, html[position].properties.isAlphabetic || html[position].properties.numericType != nil {
                name.unicodeScalars.append(html[position])
                position += 1
            }
            name = name.lowercased()
            if name == "code" {
                text.append(closing ? codeCloseScalar : codeOpenScalar)
            } else if blockTags.contains(name) {
                text.append(newline)
            }
            index = close + 1
        }
        let plain = unescape(text)
        var paragraphs: [String] = []
        var current = String.UnicodeScalarView()
        var pendingSpace = false
        func flush() {
            if !current.isEmpty { paragraphs.append(String(current)) }
            current = String.UnicodeScalarView()
            pendingSpace = false
        }
        for scalar in plain {
            if scalar == newline {
                flush()
            } else if scalar.properties.isWhitespace {
                pendingSpace = !current.isEmpty
            } else {
                if pendingSpace { current.append(" ") }
                pendingSpace = false
                current.append(scalar)
            }
        }
        flush()
        return paragraphs
    }

    private static let codeOpenScalar: Unicode.Scalar = "\u{E000}"
    private static let codeCloseScalar: Unicode.Scalar = "\u{E001}"
    private static let newline: Unicode.Scalar = "\n"
    private static let preOpen = Array("<pre".unicodeScalars)
    private static let preClose = Array("</pre>".unicodeScalars)

    private static let blockTags: Set<String> = [
        "p", "br", "li", "ul", "ol", "blockquote", "h1", "h2", "h3", "h4", "h5", "h6", "div", "hr", "tr", "table",
    ]

    private static let namedEntities: [String: String] = [
        "lt": "<", "gt": ">", "amp": "&", "quot": "\"", "apos": "'", "nbsp": " ", "laquo": "«", "raquo": "»",
        "mdash": "—", "ndash": "–", "hellip": "…",
    ]

    /// The first place of `pattern` in `text` at or after `from`.
    private static func find(_ pattern: [Unicode.Scalar], in text: [Unicode.Scalar], from: Int) -> Int? {
        guard let first = pattern.first, text.count >= pattern.count, from <= text.count - pattern.count else { return nil }
        var index = from
        while index <= text.count - pattern.count {
            if text[index] == first, text[index..<(index + pattern.count)].elementsEqual(pattern) { return index }
            index += 1
        }
        return nil
    }

    /// XML character references and the entities of `namedEntities`; what is
    /// not one stays as it is.
    public static func unescapeXML(_ text: String) -> String {
        guard text.utf8.contains(UInt8(ascii: "&")) else { return text }
        var result = String.UnicodeScalarView()
        result.append(contentsOf: unescape(Array(text.unicodeScalars)))
        return String(result)
    }

    static func unescape(_ text: [Unicode.Scalar]) -> [Unicode.Scalar] {
        guard text.contains("&") else { return text }
        var result: [Unicode.Scalar] = []
        result.reserveCapacity(text.count)
        var index = 0
        while index < text.count {
            let scalar = text[index]
            guard scalar == "&", let semicolon = text[index..<min(index + 11, text.count)].firstIndex(of: ";") else {
                result.append(scalar)
                index += 1
                continue
            }
            var name = String.UnicodeScalarView()
            name.append(contentsOf: text[(index + 1)..<semicolon])
            let entity = String(name)
            if let named = namedEntities[entity] {
                result.append(contentsOf: named.unicodeScalars)
            } else if let value = entity.hasPrefix("#x") ? UInt32(entity.dropFirst(2), radix: 16)
                : entity.hasPrefix("#") ? UInt32(entity.dropFirst()) : nil, let decoded = Unicode.Scalar(value)
            {
                result.append(decoded)
            } else {
                result.append(contentsOf: text[index...semicolon])
            }
            index = semicolon + 1
        }
        return result
    }

    // MARK: - Sentences

    /// Sentences of a paragraph: it is cut after `.`, `!` or `?` (and the
    /// closing quotes and brackets after it) that a space and a capital letter
    /// or a digit follow. A single letter before the dot («т. д.», «А. С.
    /// Пушкин») is an abbreviation, not an end.
    public static func sentences(of paragraph: String) -> [String] {
        let characters = Array(paragraph.unicodeScalars)
        var sentences: [String] = []
        var start = 0
        var index = 0
        let stops: Set<Unicode.Scalar> = [".", "!", "?"]
        let closers: Set<Unicode.Scalar> = [")", "\"", "'", "»", "”", "]", codeCloseScalar]
        let opens: Set<Unicode.Scalar> = ["(", "\"", "«", "“", "[", codeOpenScalar]
        func text(_ range: Range<Int>) -> String {
            var view = String.UnicodeScalarView()
            view.append(contentsOf: characters[range])
            return String(view).trimmingCharacters(in: .whitespaces)
        }
        while index < characters.count {
            guard stops.contains(characters[index]) else {
                index += 1
                continue
            }
            var end = index + 1
            while end < characters.count, stops.contains(characters[end]) || closers.contains(characters[end]) { end += 1 }
            guard end < characters.count, characters[end] == " " else {
                index = end
                continue
            }
            var next = end
            while next < characters.count, characters[next] == " " { next += 1 }
            while next < characters.count, opens.contains(characters[next]) { next += 1 }
            guard next < characters.count,
                  characters[next].properties.isUppercase || characters[next].properties.numericType != nil
            else {
                index = end
                continue
            }
            if characters[index] == ".", isAbbreviation(before: index, in: characters) {
                index = end
                continue
            }
            let sentence = text(start..<end)
            if !sentence.isEmpty { sentences.append(sentence) }
            start = next
            index = next
        }
        if start < characters.count {
            let sentence = text(start..<characters.count)
            if !sentence.isEmpty { sentences.append(sentence) }
        }
        return sentences
    }

    /// The word before the dot is one letter: «т.», «д.», «А.».
    private static func isAbbreviation(before dot: Int, in characters: [Unicode.Scalar]) -> Bool {
        var begin = dot
        while begin > 0, characters[begin - 1].properties.isAlphabetic { begin -= 1 }
        return dot - begin == 1
    }
}

/// The scripts the bench types.
public enum LetterScript: Hashable, Sendable {
    case cyrillic, latin
    /// A letter of another script: no layout of the bench types it.
    case other

    /// The script of a letter; nil for what is not a letter.
    public static func of(_ character: Character) -> LetterScript? {
        guard character.isLetter, let scalar = character.unicodeScalars.first else { return nil }
        switch scalar.value {
        case 0x0400...0x052F: return .cyrillic
        case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F, 0x1E00...0x1EFF: return .latin
        default: return .other
        }
    }
}
